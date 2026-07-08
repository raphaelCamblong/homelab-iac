# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose

GitOps-managed homelab. The 2-node k3s cluster on Raspberry Pi 5 (`192.168.1.41` server, `192.168.1.13` agent) **is the production cluster** — Flux-bootstrapped from this repo (`flux bootstrap github --path=clusters/homelab`), syncing branch `main` every 1m via a deploy key. If it's not in git, it doesn't exist; drift heals on the next reconcile.

A 3-node Talos cluster on Raspberry Pi CM5 + Compute Blade + NVMe is future work (see `talos-cluster-PLATFORM.md` / `talos-cluster-PLAN.md`). Because the platform-agnostic manifests live at the repo root (`infrastructure/`, `apps/`) rather than under `clusters/homelab/`, the Talos rollout is **not** a first-ever bootstrap — it's "add a new `clusters/<name>/` thin layer that consumes the same root bases, then `flux bootstrap` that cluster." `cluster-bootstrap/` (Terraform + Talos configs) stays dormant until then.

There used to be a throwaway `clusters/k3s-test/` manual-overlay validation cluster in front of prod. That era is over — the manual overlay was deleted once this k3s cluster was cut over to real Flux bootstrap; bugs it caught are logged in git history only.

## Repo layout

```
cluster-bootstrap/
  talos/                  # Talos schematic + machine config patches
  terraform/              # Bootstrap module: Talos secrets → controlplane → Flux
                          # State is gitignored. flux.tf pre-installs Cilium so
                          # Flux controllers can schedule (CNI chicken-and-egg).
                          # Talos-only; dormant until the CM5 rollout.
infrastructure/<comp>/     # Platform-agnostic bases: CNI, gateway, certs, storage,
                          # observability, admin tools. NO cluster-specific values
                          # here (no hardcoded IPs, replica counts, domains) —
                          # those are layered on by clusters/<name>/ via patches
                          # and postBuild substitution.
apps/<workload>/           # Platform-agnostic bases for user-facing workloads
                          # that consume the infrastructure (e.g. media-stack).
                          # Same rule: no cluster-specific values in the base.
clusters/homelab/         # THIN per-cluster layer for the k3s prod cluster.
  flux-system/            # Written by `flux bootstrap`, do not hand-edit
  kustomization.yaml      # Explicit aggregator of every top-level Flux Kustomization
  cluster-vars.yaml       # ConfigMap flux-system/cluster-vars — DOMAIN=lab.raphlamenace.xyz
  <component>.yaml        # One Flux Kustomization CR per component, with dependsOn,
                          # pointing at ./infrastructure/<comp> or ./apps/<workload>.
                          # k3s-specific deltas live here as spec.patches; hostname
                          # substitution wired via postBuild.substituteFrom cluster-vars.
docs/media-stack/SPEC.md  # Storage layout, hardlink contract, NAS vs cluster split
nas/                      # TrueNAS Custom App compose configs (Jellyfin, gluetun+qbit)
                          # Not Flux-managed — NAS isn't k8s. Kept here for repro.
```

When the Talos cluster lands, it becomes `clusters/talos-homelab/` (or similar) — a second thin layer next to `clusters/homelab/`, consuming the same `infrastructure/` and `apps/` bases with its own patches/vars.

## Bootstrap vs GitOps boundary

- **Terraform** (one-shot, side-effecting, Talos-only for now): Talos identity + per-node config apply + etcd bootstrap; kubeconfig/talosconfig retrieval; Flux install + GitHub deploy key + in-cluster `sops-age` Secret; **pre-Flux Cilium install** (because Flux pods need CNI). `cluster-bootstrap/terraform/flux.tf` uses `lifecycle.ignore_changes = all` on the `helm_release.cilium` so Flux's helm-controller adopts the release on first reconcile. This module has not run yet for the live k3s cluster — that cluster was bootstrapped directly with `flux bootstrap github`, so there is no Terraform state for it.
- **Flux** (continuous, live now): every HelmRelease, ConfigMap, Secret, CronJob, raw manifest for the k3s cluster. Dependency order is encoded via `dependsOn` in the top-level `clusters/homelab/<component>.yaml` files. **No `helm install` or hand `kubectl apply`** is supposed to happen — if it's not in git, it doesn't exist, and this is now actually enforced: `prune: true` + drift self-heals on the 1h `Kustomization` interval (or `flux reconcile`).
- The only out-of-band objects for the live cluster are the `sops-age` Secret in `flux-system` (created once at bootstrap time from the local age key) and the age private key itself, kept out of git.

The two bootstrap paths (this k3s cluster today, Talos later) are linked by `.sops.yaml`'s shared age recipient and by `cluster-bootstrap/talos/secrets.sops.yaml`, which will hold the Talos cluster identity (etcd certs, CA, bootstrap token) SOPS-encrypted in git once Talos rollout happens. Losing TF state is non-fatal: re-clone, decrypt with age key, `terraform apply` reconverges. The age private key is the only out-of-band backup that matters for either cluster.

## Component dependency graph (`clusters/homelab/`, live k3s cluster)

```
gateway-api-crds → cilium → ┬→ cert-manager → gateway → headlamp / observability / cloudflared / media-stack
                            ├→ longhorn → observability, media-stack
                            ├→ csi-driver-nfs → media-stack
                            ├→ compute-blade
                            └→ prometheus-operator-crds → vm-stack → victoria-logs → grafana, alloy
```

Anything that needs `monitoring.coreos.com` CRDs must `dependsOn: prometheus-operator-crds` — the `vm-stack` chart's `victoria-metrics-operator.prometheus-operator-crds.enabled` subchart toggle was found to silently no-op in vm-stack chart 0.78.0, so the CRDs are installed standalone.

Notes on the graph vs the aggregator (`clusters/homelab/kustomization.yaml`):
- `backup.yaml` exists in the repo (etcd-snapshot CronJob) but is **not** in the aggregator — it's Talos-only (`talosctl` etcd snapshots don't apply to k3s) and stays inactive until the Talos rollout re-adds it.
- `tailscale.yaml` is commented out in the aggregator — needs an authkey Secret seeded first; re-enable once `tailscale-auth.sops.yaml` exists.
- `flux-receiver` was removed entirely (not just disabled): the smee-client image wasn't pullable on arm64, the `lab.*` hosts are LAN-only so GitHub couldn't reach a Receiver anyway, and the 1m `GitRepository` poll interval is fast enough without push-based reconcile. See git history if sub-minute sync ever becomes worth revisiting.

## `infrastructure/` vs `apps/` split

- **`infrastructure/`** — platform plumbing the cluster needs to function or to host workloads: CNI (cilium), gateway-api-crds, gateway, cert-manager, longhorn, csi-driver-nfs, observability stack (vm-stack/victoria-logs/alloy/grafana/prometheus-operator-crds), compute-blade, headlamp (admin), cloudflared (ingress tunnel), tailscale (subnet router), backup (Talos-only, dormant).
- **`apps/`** — user-facing workloads that consume the infrastructure: media-stack (Prowlarr, Radarr, Bazarr, Jellyseerr, Recyclarr) currently; future Vaultwarden, n8n, etc. would land here.

When adding a new component, ask: does the cluster need this to host other things, or is it the thing being hosted? The former is infrastructure, the latter is apps.

## Working in `infrastructure/` and `apps/` (platform-agnostic bases)

- Component dir convention: `helmrepository.yaml` + `helmrelease.yaml` + `values.yaml` (chart values, often surfaced through a `configMapGenerator`) + raw manifests (`namespace.yaml`, HTTPRoutes, etc.) + `kustomization.yaml` listing them.
- HTTPRoute (and any other) hostnames use the Flux variable `foo.${DOMAIN}` — never hardcode a domain in the base. The component's top-level Flux Kustomization CR must carry `postBuild.substituteFrom` pointing at the `cluster-vars` ConfigMap for `${DOMAIN}` to resolve; currently wired on cilium, gateway, longhorn, headlamp, grafana, media-stack. Add it to any new CR that references `${DOMAIN}` (or any other cluster-var).
- Cluster-specific deltas (replica counts, node pins, storage sizes, IPs) are **never** forked into the base. They go in the per-cluster CR's `spec.patches` in `clusters/homelab/<component>.yaml` (strategic-merge patches against the rendered manifests) — e.g. cilium's `k8sServiceHost`/`operator.replicas`/L2 policy interface, longhorn's 2-replica setting, vm-stack's `vmsingle` 5Gi storage, compute-blade's nodeSelector pin. For a `HelmRelease`, `spec.values` set via a patch **merges over** any `valuesFrom` in the base — patches don't need to duplicate the whole values block, just the overridden keys.
- Secrets live as `*.sops.yaml` (SOPS-encrypted). **The repo is public — never commit a plaintext secret.** See `infrastructure/cert-manager/cloudflare-token.sops.yaml` as the canonical pattern.
- When adding a new top-level Flux Kustomization (e.g. `clusters/homelab/foo.yaml`), **append it to `clusters/homelab/kustomization.yaml`'s `resources:` list**. The explicit aggregator exists because Flux's kustomize-controller auto-discovers files and a silent drop on rename is the failure mode it prevents. The inverse matters too: **removing a CR file from the aggregator prune-cascades deletion of that component's entire inventory** (Flux's Kustomization deletion finalizer tears down every resource it owns) — don't drop an entry from the aggregator unless you actually want the component uninstalled.

## Common commands

```bash
# Cluster kubeconfig
export KUBECONFIG=~/.kube/configs/k3s-test

# Inspect Flux state
flux get kustomizations
flux get helmreleases -A
kubectl -n <ns> describe helmrelease <name>

# Force an immediate reconcile (don't wait for the 1h Kustomization interval)
flux reconcile kustomization <component> --with-source

# Diff what a change would do before pushing (needs the CR already on-cluster
# and the `flux` CLI's diff support against the local path)
flux diff kustomization <component> \
  --kustomization-file clusters/homelab/<component>.yaml \
  --path infrastructure/<component>

# Edit an encrypted secret in place (any *.sops.yaml, e.g.:)
sops infrastructure/cert-manager/cloudflare-token.sops.yaml

# Validate a kustomization builds before pushing (kustomize binary is not
# installed in this environment — use kubectl's bundled kustomize)
kubectl kustomize apps/media-stack >/dev/null && echo OK
kubectl kustomize clusters/homelab >/dev/null && echo aggregate OK

# Big CRD bundles (Gateway API httproutes) need server-side apply
kubectl apply --server-side=true --force-conflicts \
  -f infrastructure/gateway-api-crds/standard-install.yaml

# Re-fetch Gateway API CRDs (experimental channel; filename retained)
bash infrastructure/gateway-api-crds/.fetch.sh
```

For the Talos rollout, every command is in `talos-cluster-PLAN.md` Steps 1–9 — follow that file end-to-end rather than improvising (it needs an update pass for the new root-level `infrastructure/`/`apps/` paths and the fact that Step 1's age-key generation is already done).

## Gotchas worth keeping in mind

- **Gateway API channel**: Cilium 1.19 needs `TLSRoute v1alpha2`, which the standard channel no longer serves in v1.5.x. `.fetch.sh` pulls the **experimental** bundle (filename kept as `standard-install.yaml` for git-history continuity). The bundle ships a `safe-upgrades` ValidatingAdmissionPolicy that blocks channel re-flip; delete it before re-applying a different channel.
- **`local-path` and `longhorn` both annotate themselves as default StorageClass** on k3s. Cosmetic; resolve only if it bites a specific install.
- **`observability` namespace PSA = `privileged`** (not `baseline`): `prometheus-node-exporter` needs `hostNetwork`/`hostPID`/`hostPath`/`hostPort`. Baseline blocks all four → 0 pods scheduled.
- **`vmsingle` accepts flat PVCSpec, `vmalertmanager` requires `volumeClaimTemplate.spec`** wrapper — same chart, different CRDs. Don't copy-paste the storage block between the two.
- **Media stack `/data` PV**: a single static NFS PV (`192.168.1.25:/mnt/mega-tank/media`) bound RWX, NOT the dynamic `nfs-truenas` StorageClass (which points at `apps/k8s` on the NAS and creates per-PVC subfolders). The hardlink contract in `docs/media-stack/SPEC.md` requires one filesystem AND one NFS export covering both `movies/` and `downloads/` — don't split it.
- **Heavy-IO media apps (Jellyfin, qBittorrent+Gluetun) stay on the NAS as Docker compose**, even in the final Talos version. Confirmed with the user. Light/API apps (Prowlarr, Radarr, Bazarr, Jellyseerr, Recyclarr) run on the cluster and route through `/data` via the NFS PV. NAS-hosted services are wired through the cluster Gateway via selector-less `Service` + manual `EndpointSlice` so traffic shows up in Hubble.
- **`HelmRepository` resources must stay in `flux-system`.** A top-level `namespace: foo` in a kustomization clobbers ALL resources including HelmRepositories, breaking `HelmRelease.sourceRef`.
- **Grafana dashboard ConfigMaps carry `kustomize.toolkit.fluxcd.io/substitute: disabled`** (see `infrastructure/observability/grafana/kustomization.yaml`) — dashboard JSON bodies contain their own Grafana `${...}` template-variable syntax, which Flux's envsubst would otherwise try (and fail) to resolve. Any new dashboard `configMapGenerator` needs the same annotation.
- **Drift self-heals**, but not instantly: on the Kustomization's `interval` (1h for most components here) or on `flux reconcile kustomization <name> --with-source` if you don't want to wait.
- **Undefined `${...}` vars are left alone by `postBuild.substituteFrom`** (Flux only substitutes what the referenced ConfigMap/Secret defines) — but right now `cluster-vars` only defines `DOMAIN`. Adding a new `${FOO}` reference in a base does nothing until `FOO` is added to `clusters/homelab/cluster-vars.yaml` (and any other cluster's `cluster-vars.yaml` that consumes the same base).

## Secrets

SOPS is live: `.sops.yaml` has a real age recipient (`age1dseuugzmdrtpt7k7vuq5gvns2w678suy3z33up2lzr6xe787vewq3v45q5`), and encrypted secrets are committed (`cert-manager/cloudflare-token`, `observability/grafana/admin-secret`, `cloudflared/secret`, `media-stack/secrets/api-keys`). Edit any of them in place with `sops <file>`. `.sops.yaml`'s `creation_rules` are ordered: the `cluster-bootstrap/.*\.sops\.yaml$` rule (Talos-specific fields) first, then a generic `.*\.sops\.yaml$` rule (`data`/`stringData` keys) for everything else.

The age private key lives at `~/.config/sops/age/homelab.agekey` (out-of-band backup only, never in git) and in-cluster as the `flux-system/sops-age` Secret post-bootstrap. **This key is the single disaster-recovery credential** for this repo — losing it means every encrypted secret is unrecoverable and the cluster (or its Talos successor) can't be rebuilt from git alone.
