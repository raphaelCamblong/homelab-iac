# Talos Cluster — Action Runbook

> **Status note (post k3s cutover):** the 2-node Pi 5 k3s cluster is now the
> live, Flux-bootstrapped production cluster (`flux bootstrap github
> --path=clusters/homelab`, syncing from `main`). This runbook is no longer a
> first-ever bootstrap — the Talos rollout becomes "add a new
> `clusters/<name>/` thin layer that consumes the same root `infrastructure/`
> + `apps/` bases, then `flux bootstrap` that cluster." Step 1's age-key
> generation is already done (the key exists at
> `~/.config/sops/age/homelab.agekey` and `.sops.yaml`'s recipient is real,
> not a placeholder) — skip the key-generation part of Step 1, but the
> `.sops.yaml` path rules may still need a Talos-specific entry reviewed.
> Paths below have been updated for the current repo layout
> (`infrastructure/`, `apps/` at repo root rather than under
> `clusters/homelab/`), but the rest of this runbook has not been re-audited
> against the live cluster's actual current state (e.g. `flux-receiver` in
> Step 9b no longer exists — it was removed, not just relocated).

This runbook covers only the **commands you run when you have physical access** to the 3 CM5 nodes and a tools-installed workstation. Every YAML / HCL file referenced has already been authored under `cluster-bootstrap/`, `infrastructure/`, `apps/`, and `clusters/homelab/` — see `git log -- cluster-bootstrap infrastructure apps clusters` for the layout.

Spec lives in [`talos-cluster-PLATFORM.md`](./talos-cluster-PLATFORM.md).

---

## Prerequisites checklist

- [ ] Workstation has: `talosctl`, `kubectl`, `helm`, `flux`, `sops`, `age`, `terraform` (or `tofu`). Quick install on macOS:

  ```bash
  brew install siderolabs/talos/talosctl
  brew install kubectl helm fluxcd/tap/flux sops age kubectx hashicorp/tap/terraform
  ```

- [ ] Router DHCP reservations for `192.168.1.51`, `.52`, `.53` (one per CM5 MAC).
- [ ] `192.168.1.140` (API VIP) and `192.168.1.200`-`.250` (LB pool) **outside** the DHCP range.
- [ ] DNS: `k8s.lan` resolves to `192.168.1.140` (router or Pi-hole).
- [ ] TrueNAS at `192.168.1.25` exporting `/mnt/mega-tank/apps/k8s` with rw for the cluster IPs.
- [ ] GitHub Personal Access Token with `repo` + `admin:public_key` scopes.
- [ ] Main branch protection on this repo is **off** (or you're ready to bootstrap on a separate branch — see Step 8 notes).
- [ ] Physical: 3× CM5 on Compute Blade + NVMe each, a USB-NVMe adapter / M.2 enclosure, network cabled.

---

## Step 1 — Workstation key + .sops.yaml finalize

`.sops.yaml` ships with `AGE_PUBLIC_KEY_TODO_REPLACE_ME` placeholders. Fix those before encrypting anything.

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

AGE_PUB=$(grep "public key:" ~/.config/sops/age/keys.txt | awk '{print $4}')
echo "Public key: $AGE_PUB"

# Replace the three placeholders in .sops.yaml
sed -i.bak "s|AGE_PUBLIC_KEY_TODO_REPLACE_ME|$AGE_PUB|g" .sops.yaml
rm .sops.yaml.bak

git add .sops.yaml
git commit -m "chore: set age public key in sops creation_rules"
```

**Back up the age private key now** to a password manager AND a paper copy. Losing it = unrecoverable secrets + unrebuildable cluster.

---

## Step 2 — Mint the Talos factory image

```bash
# Submit schematic, capture ID
SCHEMATIC_ID=$(curl -s -X POST --data-binary @cluster-bootstrap/talos/schematic.yaml \
  https://factory.talos.dev/schematics | jq -r .id)
echo "Schematic ID: $SCHEMATIC_ID"

TALOS_VERSION=v1.13.2   # latest stable as of 2026-05-15 — bump only if needed
IMAGE_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-arm64.raw.xz"

# Verify the URL responds
curl -sI "$IMAGE_URL" | head -1   # expect HTTP/2 200

# Annotate schematic with the ID (so future re-rolls are traceable)
sed -i.bak "1i\\
# Schematic ID: $SCHEMATIC_ID\\
# Image URL: $IMAGE_URL\\
" cluster-bootstrap/talos/schematic.yaml
rm cluster-bootstrap/talos/schematic.yaml.bak

git add cluster-bootstrap/talos/schematic.yaml
git commit -m "chore: record talos factory schematic ID"

# Download + decompress for flashing (.raw is gitignored)
curl -L -o cluster-bootstrap/talos/metal-arm64.raw.xz "$IMAGE_URL"
xz -d -k cluster-bootstrap/talos/metal-arm64.raw.xz
```

---

## Step 2b — Set CM5 EEPROM to NVMe-first boot order (one-time per node)

Fresh CM5 EEPROMs ship with `BOOT_ORDER=0xf41` (microSD first, then USB).
With no microSD inserted, the board will hang at boot — the dd'd Talos
NVMe will never be tried. You need `BOOT_ORDER=0xf416` (NVMe → microSD →
USB → restart) BEFORE flashing in Step 3.

Easiest path: temporarily boot each CM5 from a Raspberry Pi OS Lite microSD
(grab the latest `arm64` image with `rpi-imager`) and run:

```bash
sudo apt update && sudo apt install -y rpi-eeprom
sudo rpi-eeprom-config --edit
# In the editor, set:
#   BOOT_ORDER=0xf416
# Save (Ctrl+O, Enter, Ctrl+X) — reboot to apply.
sudo reboot
```

Confirm: `sudo rpi-eeprom-config | grep BOOT_ORDER` shows `0xf416`. The
setting is persisted in EEPROM and survives power-cycles.

Alternative path: `rpi-imager` GUI → "Misc utility images" → "Bootloader"
→ "NVMe Boot". Write to microSD, insert into CM5, power on — it flashes
the EEPROM and powers off automatically. Remove the microSD, done.

Repeat for cm5-2 and cm5-3. After all three EEPROMs are reconfigured, move
on to Step 3 (the NVMe will boot Talos with no microSD inserted).

---

## Step 3 — Flash and boot each node

For each CM5 (target IPs `.51`, `.52`, `.53`):

1. Power down, remove NVMe, plug into USB-NVMe adapter.
2. `diskutil list` to find the right `/dev/diskN` (DO NOT mix this up with the Mac disk).
3. `diskutil unmountDisk /dev/diskN`
4. `sudo dd if=cluster-bootstrap/talos/metal-arm64.raw of=/dev/rdiskN bs=4m status=progress && sync`
5. `sudo diskutil eject /dev/diskN`
6. Reseat NVMe, power on the CM5. (EEPROM is already set to NVMe-first per Step 2b.)
7. After ~30s: `talosctl --nodes <ip> disks --insecure` — must list `/dev/nvme0n1`. Repeat with a DHCP fix if the node didn't get the static lease.

Sanity-check all 3 + verify the predictable interface name is `end0`:

```bash
for ip in 192.168.1.51 192.168.1.52 192.168.1.53; do
  echo "=== $ip ==="
  talosctl --nodes "$ip" disks --insecure | head -3
  talosctl --nodes "$ip" get links --insecure | awk '/end0|eth/ {print}'
done
```

If the interface is NOT `end0` on any node (kernel/udev drift), update
`cluster-bootstrap/talos/patches/controlplane.yaml` and
`infrastructure/cilium/l2-pool.yaml` to match, then
commit BEFORE running Terraform apply cycle 1.

---

## Step 4 — Generate the Talos cluster identity (SOPS-encrypted)

```bash
talosctl gen secrets -o /tmp/talos-secrets.yaml

sops --encrypt --input-type yaml --output-type yaml /tmp/talos-secrets.yaml \
  > cluster-bootstrap/talos/secrets.sops.yaml
rm /tmp/talos-secrets.yaml

grep -q "ENC\[AES256_GCM" cluster-bootstrap/talos/secrets.sops.yaml && echo encrypted

git add cluster-bootstrap/talos/secrets.sops.yaml
git commit -m "feat: SOPS-encrypted Talos cluster secrets bundle"
```

---

## Step 5 — Vendor the Gateway API CRDs

Flux can't source raw GitHub release URLs, so the CRDs are vendored at action time:

```bash
bash infrastructure/gateway-api-crds/.fetch.sh
ls -la infrastructure/gateway-api-crds/standard-install.yaml

git add infrastructure/gateway-api-crds/standard-install.yaml
git commit -m "feat: vendor gateway-api standard CRDs"
```

**Note on channel.** `.fetch.sh` pulls the **experimental** bundle (filename retained for backwards compatibility). Cilium 1.19+ requires `TLSRoute v1alpha2`, which the standard channel no longer serves in v1.5.x. The bundle includes a `ValidatingAdmissionPolicy` named `safe-upgrades.gateway.networking.k8s.io` that refuses subsequent applies that would flip the channel annotation. If you ever bump versions or change channels, delete the policy first:

```bash
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io
bash infrastructure/gateway-api-crds/.fetch.sh
kubectl apply --server-side=true --force-conflicts \
  -f infrastructure/gateway-api-crds/standard-install.yaml
```

The policy is re-created automatically by the new bundle.

---

## Step 6 — Terraform apply cycle 1: controlplane + etcd bootstrap

```bash
cd cluster-bootstrap/terraform
terraform init
terraform plan -out=cp.tfplan
# Expect ~6 resources: sops_file data + talos_machine_configuration data
# + 3× talos_machine_configuration_apply + talos_machine_bootstrap
# + 2 local_sensitive_file (kubeconfig + talosconfig)
terraform apply cp.tfplan

export KUBECONFIG=$(terraform output -raw kubeconfig_path)
export TALOSCONFIG=$(terraform output -raw talosconfig_path)

talosctl etcd members   # expect 3 members
kubectl get nodes       # expect 3 nodes NotReady (no CNI yet — correct)
cd ../..
```

---

## Step 7 — Generate the backup talosconfig (role-limited)

The etcd-snapshot CronJob runs with a talosconfig scoped to `os:etcd:backup` only (not full admin):

```bash
talosctl config new --roles os:etcd:backup --crt-ttl 8760h /tmp/backup-talosconfig

B64=$(base64 -i /tmp/backup-talosconfig)
cat > infrastructure/backup/talos-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: backup-talosconfig
  namespace: cluster-backup
type: Opaque
data:
  talosconfig: $B64
EOF

sops --encrypt --in-place infrastructure/backup/talos-secret.yaml
mv infrastructure/backup/talos-secret.yaml \
   infrastructure/backup/talos-secret.sops.yaml
rm /tmp/backup-talosconfig

grep -q "ENC\[AES256_GCM" infrastructure/backup/talos-secret.sops.yaml && echo encrypted

git add infrastructure/backup/talos-secret.sops.yaml
git commit -m "feat(backup): SOPS-encrypted talosconfig for etcd snapshots"
git push origin main
```

---

## Step 8 — Terraform apply cycle 2: Flux bootstrap

⚠ **Branch protection check first.** `flux_bootstrap_git` pushes a commit to `var.github_branch` (default `main`). If protection requires PR review or signed commits, the deploy-key push **will fail**. Options:
- (a) Disable protection for the bootstrap, re-enable after. Simplest for a personal repo.
- (b) `export TF_VAR_github_branch=flux-bootstrap` and merge into main afterward.
- (c) Add the `flux-homelab` deploy key to the bypass list (paid GitHub only).

```bash
export TF_VAR_github_owner=<your-github-username>
export TF_VAR_github_token=<your-pat>

cd cluster-bootstrap/terraform
terraform plan -out=flux.tfplan
# Expect 8 resources: kubernetes_namespace_v1 + kubernetes_secret_v1 (sops-age)
# + tls_private_key + github_repository_deploy_key + flux_bootstrap_git
# + null_resource.gateway_api_crds + helm_release.cilium
# (+ the helm provider initialization).
#
# Why the extra two: Flux's controller pods can't schedule without CNI, and
# Cilium normally comes up via Flux — chicken-and-egg. We pre-install Cilium
# (and Gateway API CRDs it depends on) here so flux_bootstrap_git can wait on
# Ready pods and proceed. helm_release.cilium uses lifecycle.ignore_changes
# so Flux's helm-controller adopts the release on first reconcile without
# TF fighting it on subsequent applies.
#
# Expect helm_release.cilium to take ~8 min on first apply (image pull on
# arm64 + operator stabilization). The whole cycle is ~10-12 min.
terraform apply flux.tfplan
cd ../..

# Pull Flux's auto-commit (it writes flux-system/{gotk-components,gotk-sync,kustomization}.yaml)
git pull --rebase origin main
```

If `flux_bootstrap_git` errors with `422 key with that title already exists`, the deploy key was created in a prior run but TF doesn't track it. Recover:

```bash
KEY_ID=$(gh api "repos/$TF_VAR_github_owner/homelab-iac/keys" \
  --jq '.[] | select(.title=="flux-homelab") | .id')
cd cluster-bootstrap/terraform
terraform import github_repository_deploy_key.flux "homelab-iac:$KEY_ID"
terraform apply
```

---

## Step 9 — Watch reconciliation roll through the dependency graph

```bash
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -w
# Second terminal: flux events --watch -A
```

Expected order (approximate timings — measured 2026-05-16 on a Pi 5 NVMe arm64 validation cluster; CM5 NVMe likely similar):

| # | Kustomization        | Ready after | Notes |
| - | -------------------- | ----------- | --- |
| 1 | `flux-system`        | ~30s        | Flux managing itself |
| 2 | `gateway-api-crds`   | ~30s        | Pre-applied by TF in Step 8; Flux Kustomization just re-applies idempotently |
| 3 | `cilium`             | ~30s        | Helm release already installed by TF in Step 8 (~8 min there); Flux's helm-controller **adopts** the release. `flux get hr -n kube-system cilium` will show `Helm upgrade succeeded for release cilium.v2` — `v2` is correct (v1 = TF install, v2 = first Flux-driven generation). |
| 4 | `cert-manager`       | ~4 min      | ClusterIssuers Ready once Cloudflare token lands (step 9d) |
| 4 | `longhorn`           | ~7 min      | depends on cilium |
| 4 | `csi-driver-nfs`     | ~3 min      | parallel with longhorn |
| 4 | `compute-blade`      | ~1 min      | parallel after cilium (DaemonSet, no Helm) |
| 4 | `headlamp`           | ~2 min      | parallel after cilium |
| 4 | `flux-receiver`      | ~30s        | parallel after cilium; smee-client CrashLooping until step 9b below |
| 5 | `gateway`            | ~30s        | depends on cert-manager + gateway-api-crds; Certificate Ready after DNS-01 (~60-120s after records exist) |
| 5 | `observability-base` | ~30s        | depends on longhorn |
| 6 | `vm-stack`           | ~8 min      | depends on observability-base. See flake note below. |
| 6 | `victoria-logs`      | ~2 min      | depends on observability-base |
| 7 | `alloy`              | ~1 min      | depends on victoria-logs |
| 7 | `grafana`            | ~5 min      | depends on vm-stack + victoria-logs (waits for grafana-admin Secret — see step 9c) |
| 8 | `backup`             | ~2 min      | depends on csi-driver-nfs (waits for talos-secret — see step 7) |

Total: **~35-50 minutes** (the older "10-15 min" estimate did not survive contact with reality). Several Kustomizations stay `Ready=False` until the action-time secrets land (steps 7, 9b, 9c, 9d) — that's expected.

**vm-stack first-install flake.** Even with `spec.install.timeout: 10m`, vm-stack may show `InstallFailed` on the very first attempt — the chart bundles a victoriametrics-operator that briefly crashloops while its dependent CRDs (`AlertmanagerConfig`, `ScrapeConfig` from `prometheus-operator-crds`) register their field indexers. If `flux get hr -n observability vm-stack` shows `InstallFailed`, force a reconcile and it will succeed on the second attempt (CRDs and HelmRepository artifact are now warm):

```bash
flux -n observability reconcile helmrelease vm-stack --with-source
```

If `grafana` was waiting on `vm-stack` it will resume on its own once vm-stack flips to Ready.

When everything settles:

```bash
flux get kustomizations -A     # every row READY=True
flux get helmreleases -A       # every row READY=True
kubectl get nodes              # all 3 Ready
```

---

## Step 9b — Wire push-based reconciliation (smee.io + GitHub webhook)

Polling is set to 1h — slow on purpose. Push-based reconciles cover the gap. See [`infrastructure/flux-receiver/README.md`](infrastructure/flux-receiver/README.md) for the full sequence; abbreviated:

1. `open https://smee.io/new` — copy the channel URL.
2. Generate a webhook HMAC token: `WEBHOOK_TOKEN=$(openssl rand -hex 32)`
3. Author + SOPS-encrypt `infrastructure/flux-receiver/secret.sops.yaml` (contains `token: $WEBHOOK_TOKEN`). Commit + push.
4. After `Receiver/github-receiver` reaches `Ready=True`, read its webhook path: `kubectl -n flux-system get receiver github-receiver -o jsonpath='{.status.webhookPath}'`.
5. Author + SOPS-encrypt `infrastructure/flux-receiver/smee-config.sops.yaml` (contains `url: <smee-channel>` + `path: <webhook-path>`). Commit + push.
6. GitHub repo → Settings → Webhooks → Add webhook:
   - Payload URL: smee channel URL
   - Content type: `application/json`
   - Secret: `$WEBHOOK_TOKEN`
   - Events: just `push` (and `ping`)
7. Verify: trigger "Redeliver" on the webhook in the GitHub UI; `kubectl -n flux-system logs deploy/smee-client` shows the POST forwarded; `flux events --watch -A` shows `Reconciliation requested by github-receiver`.

After this, every `git push` to `main` triggers an immediate reconcile.

---

## Step 9c — Seed Grafana admin password (SOPS)

Grafana values reference `existingSecret: grafana-admin`. Generate it now:

```bash
NS=observability
ADMIN_PASS=$(openssl rand -base64 32)
cd infrastructure/observability/grafana
cat > admin-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata: { name: grafana-admin, namespace: $NS }
type: Opaque
stringData:
  admin-user: admin
  admin-password: $ADMIN_PASS
EOF
sops --encrypt --in-place admin-secret.yaml
mv admin-secret.yaml admin-secret.sops.yaml
echo "Grafana admin password (back this up): $ADMIN_PASS"
cd -

git add infrastructure/observability/grafana/admin-secret.sops.yaml
git commit -m "feat(grafana): seed admin secret" && git push
```

Grafana's HelmRelease will reconcile within seconds (push triggered via the webhook from step 9b).

---

## Step 9d — Wire TLS-terminating Gateway (Cloudflare + Let's Encrypt)

Replace the `<YOUR_DOMAIN>` placeholders, seed the Cloudflare API token, and create the public DNS records. See [`infrastructure/cert-manager/README.md`](infrastructure/cert-manager/README.md) for full detail; condensed sequence:

```bash
# 1. Replace the placeholder with the real Cloudflare-hosted domain
read -p 'Your Cloudflare domain (e.g. example.com): ' DOMAIN
read -p 'Contact email for Let's Encrypt: ' EMAIL
sed -i '' "s|<YOUR_DOMAIN>|$DOMAIN|g" $(grep -rl '<YOUR_DOMAIN>' clusters/)
sed -i '' "s|ops@$DOMAIN|$EMAIL|g" infrastructure/cert-manager/clusterissuer-*.yaml

# 2. Generate a scoped Cloudflare API token in the Cloudflare dashboard:
#    My Profile → API Tokens → Create Token → Custom token
#    Permissions: Zone:DNS:Edit + Zone:Zone:Read
#    Zone Resources: Include → Specific zone → <your domain>
TOKEN=<paste-the-token>

# 3. SOPS-encrypt the token Secret
cat > infrastructure/cert-manager/cloudflare-token.yaml <<EOF
apiVersion: v1
kind: Secret
metadata: { name: cloudflare-api-token, namespace: cert-manager }
type: Opaque
stringData:
  api-token: $TOKEN
EOF
sops --encrypt --in-place infrastructure/cert-manager/cloudflare-token.yaml
mv infrastructure/cert-manager/cloudflare-token.{yaml,sops.yaml}

git add -A clusters/homelab/
git commit -m "feat(infra): set domain + seed Cloudflare API token"
git push

# 4. Create the DNS records in Cloudflare (DNS → Records):
#    A   *.lab   192.168.1.200   Proxy: DNS only (grey cloud)
#    A   lab     192.168.1.200   Proxy: DNS only
```

After ~2 min:

```bash
kubectl -n cert-manager get clusterissuer       # both Ready=True
kubectl -n gateway get certificate lab-wildcard # Ready=True (DNS-01 takes ~30-90s)
kubectl -n gateway get gateway cilium           # PROGRAMMED=True, ADDRESS=192.168.1.200
```

If the Certificate is stuck, see `infrastructure/cert-manager/README.md` for the troubleshooting commands. Switch to `letsencrypt-staging` first if you're iterating to avoid prod rate limits.

---

## Step 10 — End-to-end smoke

```bash
kubectl get storageclass   # longhorn (default) + nfs-truenas

kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: smoke-longhorn, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: smoke-nfs, namespace: default }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-truenas
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc -n default -w   # both Bound within 30s, then ^C
kubectl delete pvc smoke-longhorn smoke-nfs -n default

# LoadBalancer smoke (Cilium L2 announcement)
kubectl create deployment smoke --image=nginx:alpine
kubectl expose deployment smoke --port=80 --type=LoadBalancer
SMOKE_IP=$(kubectl get svc smoke -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w "%{http_code}\n" "http://$SMOKE_IP"   # 200
kubectl delete deployment smoke svc/smoke

# Gateway API exposure (cert-manager + Let's Encrypt + Cilium Gateway)
kubectl get gatewayclass                       # cilium present
kubectl -n gateway get gateway cilium          # PROGRAMMED=True, ADDRESS=192.168.1.200
kubectl -n gateway get certificate lab-wildcard # READY=True
curl -sI "https://grafana.lab.$DOMAIN"          # HTTP/2 200, valid LE cert
curl -sI "http://grafana.lab.$DOMAIN"           # HTTP/2 301 (redirect to https)

# Dashboards via Gateway (replaces port-forwards and LB IPs)
open "https://grafana.lab.$DOMAIN"   # admin / password from step 9c
open "https://headlamp.lab.$DOMAIN"
kubectl -n headlamp create token headlamp --duration=24h   # paste into UI
# In UI: Settings → Plugin Catalog → search "flux" → Install
kubectl -n headlamp rollout restart deploy/headlamp
open "https://hubble.lab.$DOMAIN"
open "https://longhorn.lab.$DOMAIN"

# Trigger one etcd snapshot manually
kubectl -n cluster-backup create job --from=cronjob/etcd-snapshot etcd-snapshot-manual
kubectl -n cluster-backup wait --for=condition=complete job/etcd-snapshot-manual --timeout=2m
kubectl -n cluster-backup logs job/etcd-snapshot-manual   # expect "etcd-...db" written
```

---

## Step 11 — CLUSTER.md cheat sheet

Write `CLUSTER.md` at the repo root once the values are verified:

```markdown
# Cluster Access — homelab

| What | Where |
| --- | --- |
| Kubernetes API VIP | https://192.168.1.140:6443 |
| Grafana | https://grafana.lab.<YOUR_DOMAIN> (admin password from step 9c) |
| Headlamp | https://headlamp.lab.<YOUR_DOMAIN> (token: `kubectl -n headlamp create token headlamp`) |
| Hubble UI | https://hubble.lab.<YOUR_DOMAIN> |
| Longhorn UI | https://longhorn.lab.<YOUR_DOMAIN> |
| Gateway LB IP | 192.168.1.200 (`*.lab.<YOUR_DOMAIN>` resolves here) |
| talosctl | `export TALOSCONFIG=$(cd cluster-bootstrap/terraform && terraform output -raw talosconfig_path)` |
| kubectl | `export KUBECONFIG=$(cd cluster-bootstrap/terraform && terraform output -raw kubeconfig_path)` |
| etcd snapshot recovery | `talosctl etcd recover --from /path/to/snapshot.db && talosctl bootstrap` |
| Flux reconcile now | `flux reconcile kustomization flux-system --with-source` |
| Force re-pull of a HelmRelease | `flux suspend hr <name> -n <ns> && flux resume hr <name> -n <ns>` |
| Force certificate renewal | `cmctl renew -n gateway lab-wildcard` |
```

```bash
git add CLUSTER.md && git commit -m "docs: cluster access cheat sheet" && git push
```

---

## Component versions (pinned 2026-05-15)

These are the resolved versions baked into the manifests in this repo. Bump in follow-up PRs after the initial cluster is healthy.

| Component | Version | Source |
| --- | --- | --- |
| Talos | v1.13.2 | factory.talos.dev / siderolabs/talos releases |
| Kubernetes | 1.36.0 | bundled with Talos v1.13.2 |
| Cilium chart | 1.19.4 | helm.cilium.io |
| Longhorn chart | 1.11.2 | charts.longhorn.io |
| csi-driver-nfs chart | v4.13.2 | kubernetes-csi/csi-driver-nfs |
| Gateway API | v1.5.1 | kubernetes-sigs/gateway-api releases |
| VM-k8s-stack chart | 0.78.0 | victoriametrics helm-charts |
| VictoriaLogs chart | 0.12.1 | victoriametrics helm-charts (`victoria-logs-single`) |
| Alloy chart | 1.8.1 | grafana helm-charts |
| Grafana chart | 10.5.15 | grafana helm-charts |
| Headlamp chart | 0.42.0 | headlamp-k8s helm |
| compute-blade-agent | v0.11.2 | ghcr.io/compute-blade-community (hand-rolled DaemonSet — no chart published) |
| smee-client | latest | ghcr.io/probot/smee-client |
| cert-manager | v1.20.2 | jetstack helm-charts |
| Gateway API CRDs | v1.5.1 | already vendored (Step 5) |
| terraform-provider-talos | ~> 0.11 (0.11.0) | siderolabs |
| terraform-provider-flux | ~> 1.8 (1.8.7) | fluxcd |
| terraform-provider-kubernetes | ~> 3.1 (3.1.0) | hashicorp — note major bump from 2.x |
| terraform-provider-github | ~> 6.12 (6.12.1) | integrations |
| terraform-provider-tls | ~> 4.3 (4.3.0) | hashicorp |
| terraform-provider-local | ~> 2.9 (2.9.0) | hashicorp |
| terraform-provider-sops | ~> 1.4 (1.4.1) | carlpett |

---

## Notes for the operator

1. **Boundary discipline matters.** Terraform owns the one-shot lifecycle (config apply, etcd bootstrap, Flux install, GitHub deploy key, in-cluster `sops-age` Secret). Flux owns everything continuously reconciled from git. **Do not `helm install` anything after Step 8** — if it isn't in git, it doesn't exist.
2. **Cluster identity (Talos CA / etcd certs) lives in git**, SOPS-encrypted at `cluster-bootstrap/talos/secrets.sops.yaml`. Terraform reads it via `data.sops_file`. Lose the workstation, lose TF state — no problem; re-clone, decrypt with age key, `terraform apply` rebuilds against the same nodes. **The age private key is the single most critical secret.**
3. **Reconciliation order is enforced by `dependsOn`** at the top-level Flux Kustomization level. Graph:
   ```
   gateway-api-crds → cilium → ┬→ longhorn → observability-base → ┬→ vm-stack ───────→ grafana
                               │                                    ├→ victoria-logs ──→ alloy ↗
                               ├→ csi-driver-nfs → backup
                               ├→ compute-blade
                               ├→ headlamp
                               └→ flux-receiver
   ```
   Observability is split into 5 Kustomizations so one component's failure doesn't block the others.
4. **All in-git secrets are SOPS-encrypted.** Filenames end in `.sops.yaml`. Decryption happens in-cluster via the `sops-age` Secret in `flux-system` (created by Terraform from your local age key file).
5. **`talosctl` privileges are sensitive.** The backup CronJob's talosconfig has `os:etcd:backup` role only, not full admin.
6. **`KUBECONFIG=~/.kube/configs/homelab`** is the cluster's admin config. Regenerable from `terraform apply` since the underlying secrets are in git — no separate backup needed.
7. **To rebuild from scratch:** flash 3 fresh CM5s, `terraform apply` in `cluster-bootstrap/terraform/` (same secrets bundle → same cluster CA → nodes trust the new control plane), restore etcd snapshot if needed, Flux re-reconciles everything from git.

---

## Optional follow-ups (intentionally deferred)

Add when the need is real, not now.

- **Flux image-automation** (`image-reflector-controller` + `image-automation-controller`) — re-enable in `cluster-bootstrap/terraform/flux.tf` `flux_bootstrap_git.components_extra` when an image-pinning workflow is needed.
- **Spegel** — P2P OCI image mirror. Single HelmRelease; reduces internet pulls.
- **External Secrets Operator** — once Vaultwarden (or similar) is deployed and apps want secrets sourced from there.
- **Kyverno** — when there's a real policy need.
- **Renovate** — when there are 10+ HelmReleases and manual chart-bump PRs become a chore.
- **Velero** — when stateful PVs need more than Longhorn snapshots + etcd snapshots can give.
- **Tetragon** — runtime security observability.
- **K8sGPT** — LLM-assisted cluster diagnosis.

---

## Disaster recovery rehearsal (recommended once)

Run this once after the cluster is healthy to validate the DR triad (git + etcd snapshot + Longhorn backups):

1. Re-flash one node, leaving the others up — verify 2/3 etcd quorum survives, node rejoins cleanly via `terraform apply` re-running its config.
2. Restore an etcd snapshot into a single-node test cluster, verify resource counts match.
3. Document the actual time-to-recover.
