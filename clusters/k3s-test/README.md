# clusters/k3s-test/

Throwaway overlay for the 2-node Raspberry Pi 5 k3s cluster (`192.168.1.41` server, `192.168.1.13` agent). Validates the Cilium Gateway API + cert-manager + observability stack from `clusters/homelab/infrastructure/` **before** the eventual Talos+CM5 rollout.

## NOT Flux-bootstrapped

We install Flux controllers only (`flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller --network-policy=false`) so `HelmRelease` / `HelmRepository` reconcile, but no `GitRepository` or `Kustomization` CRs. Apply each overlay manually with `kubectl apply -k`.

## Apply order

```bash
export KUBECONFIG=~/.kube/configs/k3s-test

flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller --network-policy=false

kubectl apply -k clusters/k3s-test/10-gateway-api-crds
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s

kubectl apply -k clusters/k3s-test/20-cilium
kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl wait --for=condition=Ready node --all --timeout=5m

# cert-manager needs the Cloudflare token Secret BEFORE applying.
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
read -s -p "Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read scoped to raphlamenace.xyz): " CF_TOKEN
kubectl -n cert-manager create secret generic cloudflare-api-token --from-literal=api-token=$CF_TOKEN
kubectl apply -k clusters/k3s-test/30-cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m

kubectl apply -k clusters/k3s-test/40-gateway

# Add Cloudflare DNS records NOW:
#   A   lab.raphlamenace.xyz      192.168.1.200   (DNS-only / grey-cloud)
#   A   *.lab.raphlamenace.xyz    192.168.1.200   (DNS-only / grey-cloud)
# Wait until cert reaches READY=True:
kubectl -n gateway wait --for=condition=Ready certificate/lab-wildcard --timeout=10m

kubectl apply -k clusters/k3s-test/50-longhorn
kubectl apply -k clusters/k3s-test/51-csi-driver-nfs
kubectl apply -k clusters/k3s-test/52-compute-blade
kubectl apply -k clusters/k3s-test/53-headlamp

kubectl apply -k clusters/k3s-test/60-observability-common
kubectl apply -k clusters/k3s-test/61-vm-stack
kubectl apply -k clusters/k3s-test/62-victoria-logs
kubectl apply -k clusters/k3s-test/63-alloy

# Grafana needs admin Secret before applying.
GRAFANA_PASS=$(openssl rand -base64 24)
echo "Grafana admin password (save this): $GRAFANA_PASS"
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password=$GRAFANA_PASS
kubectl apply -k clusters/k3s-test/64-grafana
```

## Deviations from `clusters/homelab/infrastructure/` baselines

| Overlay | Change | Why |
| --- | --- | --- |
| `20-cilium/values.yaml` | `k8sServiceHost: 192.168.1.41` | k3s server IP, not Talos VIP `192.168.1.140` |
| `20-cilium/values.yaml` | `operator.replicas: 1` | 2-node cluster — no benefit to 2 operators |
| `20-cilium/l2-pool.yaml` | `interfaces: [eth0]` | Pi 5 Ubuntu raspi NIC is `eth0`, not `end0` |
| `30-cert-manager/` | Drops `cloudflare-token.sops.yaml` | Plain Secret created at runtime |
| `50-longhorn/values.yaml` | `defaultReplicaCount: 2`, `defaultClassReplicaCount: 2` | Quorum unachievable with 3 replicas on 2 nodes |
| `61-vm-stack/values.yaml` | `vmsingle` storage 20Gi → 5Gi | Pi NVMe / 2-node Longhorn ceiling |
| `64-grafana/` | Drops `admin-secret.sops.yaml` | Plain Secret created at runtime |
| All HTTPRoutes + Certificate + ClusterIssuer | sed-substituted `<YOUR_DOMAIN>` → `raphlamenace.xyz` | k3s test cluster's domain |

All other manifests are referenced directly from `clusters/homelab/infrastructure/` — no duplication.

## Excluded from this round

- `clusters/homelab/backup.yaml` — Talos `talosctl etcd snapshot` CronJob; doesn't apply to k3s SQLite.
- `clusters/homelab/flux-receiver.yaml` — depends on GitOps bootstrap; not used here.

## Findings against the prod manifests (already fixed in `clusters/homelab/`)

These are real bugs in the production-target manifests caught by the k3s validation run. Every fix has been applied directly to `clusters/homelab/infrastructure/` so the eventual Talos rollout won't hit them.

| File | Fix | Symptom |
| --- | --- | --- |
| `gateway-api-crds/.fetch.sh` | Switch source from `standard-install.yaml` → `experimental-install.yaml` (same filename retained) | Cilium 1.19 operator crashloops with `no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1alpha2"`. Standard channel serves only `v1` for TLSRoute in v1.5.x; experimental still serves `v1alpha2`. |
| `observability/loki/values.yaml` | Add `read/write/backend.replicas: 0` | Chart 14.2.0 `validate.yaml` rejects install when both monolithic and scalable replicas > 0 — chart defaults `read/write/backend` to 3 each, so `singleBinary` mode trips validation. |
| `observability/_common/namespace.yaml` | `pod-security.kubernetes.io/enforce: baseline` → `privileged` | `prometheus-node-exporter` DaemonSet requires `hostNetwork`, `hostPID`, hostPath `/proc /sys /root`, `hostPort 9100`. Baseline blocks all of these → 0 pods scheduled. |
| `observability/vm-stack/values.yaml` | Wrap `alertmanager.spec.storage` in a `volumeClaimTemplate.spec` block | `vmalertmanager` CRD expects `StorageSpec` (`volumeClaimTemplate` wrapper); `vmsingle` accepts flat PVCSpec — the two CRDs differ. Without the wrapper the StatefulSet generation fails with `spec.volumeClaimTemplates[0].spec.resources[storage]: Required value`. |
| `observability/vm-stack/values.yaml` | Add `victoria-metrics-operator.prometheus-operator-crds.enabled: true` | vm-operator registers field indexers for `AlertmanagerConfig.monitoring.coreos.com/v1alpha1` + `ScrapeConfig.monitoring.coreos.com/v1alpha1` at startup. Without those CRDs the manager crashloops on cache sync timeout. |
| `headlamp/helmrepository.yaml` | URL `headlamp-k8s.github.io/headlamp/` → `kubernetes-sigs.github.io/headlamp/` | Old URL 404s — project moved orgs. |

## Other gotchas (overlay-local, not prod-applicable)

- **`HelmRepository` must stay in `flux-system`.** A top-level `namespace: foo` in the kustomization clobbers ALL resources' namespace, including `HelmRepository` whose `HelmRelease.sourceRef.namespace` is fixed at `flux-system`. Fix: drop top-level `namespace:` from any kustomization that bundles a HelmRepository. Affected: `20-cilium`, `30-cert-manager` (already corrected in this overlay).
- **Cilium HelmRelease adoption.** Because Flux's `helm-controller` can't schedule until CNI is up, the bootstrap path is: install Cilium via `helm install` directly → wait for nodes Ready → Flux pods schedule → Flux adopts the existing release (release name + namespace match). The HelmRelease shows `Helm upgrade succeeded for release cilium.v2` after adoption (the v2 = first Flux-driven upgrade).
- **Gateway API CRDs need `--server-side` apply.** `httproutes.gateway.networking.k8s.io` is large enough that the `last-applied-configuration` annotation breaks the 262144-byte limit on a regular `kubectl apply`. Use `kubectl apply --server-side=true --force-conflicts`.
- **The `safe-upgrades` ValidatingAdmissionPolicy** that ships with standard Gateway API CRDs blocks reinstall over experimental. If you flip channels, delete the policy + binding first, apply the new CRDs, then let the policy be re-created.
- **Two storage classes show `(default)`.** k3s's `local-path` AND Longhorn both annotate themselves default. Cosmetic — k8s picks one; resolve by removing the default annotation from one of them if it matters.

## Known non-blocking issues

- **`compute-blade-agent` on `192.168.1.13` (k3s-agent-0) in `CrashLoopBackOff`.** Fails with `failed to request GPIO20 (edge button): device or resource busy`. Something else on that host (old binary install? a probe daemon?) holds GPIO20. The pod on `.41` runs fine. Non-critical (fan/LED control). To debug: `ssh raphael@192.168.1.13 'sudo lsof /dev/gpiochip0 2>/dev/null; sudo cat /sys/kernel/debug/gpio'`.

## Final cluster state (verified end-to-end)

| What | Where | Status |
| --- | --- | --- |
| Kubernetes API | https://192.168.1.41:6443 | k3s v1.35.4+k3s1 |
| Gateway LB | 192.168.1.200 | PROGRAMMED |
| Wildcard cert | `lab.raphlamenace.xyz` + `*.lab.raphlamenace.xyz` | Let's Encrypt prod (R12), valid 90d |
| Grafana | https://grafana.lab.raphlamenace.xyz | admin pw in `/tmp/grafana-admin-password.txt` |
| Headlamp | https://headlamp.lab.raphlamenace.xyz | `kubectl -n headlamp create token headlamp --duration=24h` for login |
| Longhorn UI | https://longhorn.lab.raphlamenace.xyz | replicas=2 (2-node cluster) |
| Hubble UI | https://hubble.lab.raphlamenace.xyz | Cilium network observability |
| StorageClass | `longhorn` (default), `local-path`, `nfs-truenas` | nfs-truenas points at 192.168.1.25:/mnt/mega-tank/apps/k8s — installs OK, PVCs only bind if that export exists |

## Media stack

First-launch setup lives in [`docs/media-stack/SETUP.md`](../../docs/media-stack/SETUP.md).

## Teardown

```bash
ssh raphael@192.168.1.41 'sudo /usr/local/bin/k3s-uninstall.sh'
ssh raphael@192.168.1.13 'sudo /usr/local/bin/k3s-agent-uninstall.sh'
```
