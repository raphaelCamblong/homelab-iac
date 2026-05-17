# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose

GitOps-managed homelab. The eventual production target is a 3-node Talos cluster on Raspberry Pi CM5 + Compute Blade + NVMe. A throwaway 2-node k3s cluster on Pi 5 (`192.168.1.41` server, `192.168.1.13` agent) is currently in front of it as a **validation overlay** for the prod manifests under `clusters/homelab/`.

When working in this repo, the prod manifests under `clusters/homelab/infrastructure/` are the source of truth. The k3s-test overlay exists to surface real bugs in those manifests before the Talos rollout — fixes should land in `clusters/homelab/infrastructure/` first, then any overlay-specific deltas in `clusters/k3s-test/`.

See `talos-cluster-PLATFORM.md` (spec) and `talos-cluster-PLAN.md` (runbook) for the prod cluster design and rollout plan. `clusters/k3s-test/README.md` is the current test cluster runbook + a running ledger of bugs found in prod manifests during validation.

## Repo layout

```
cluster-bootstrap/
  talos/                  # Talos schematic + machine config patches
  terraform/              # Bootstrap module: Talos secrets → controlplane → Flux
                          # State is gitignored. flux.tf pre-installs Cilium so
                          # Flux controllers can schedule (CNI chicken-and-egg).
clusters/homelab/         # PROD target (Talos+Flux). Authoritative manifests.
  flux-system/            # Written by `flux bootstrap`, do not hand-edit
  kustomization.yaml      # Explicit aggregator of every top-level Flux Kustomization
  <component>.yaml        # One Flux Kustomization CR per component, with dependsOn
  infrastructure/<comp>/  # Platform plumbing: CNI, gateway, certs, storage,
                          # observability, admin tools, GitOps plumbing
  apps/<workload>/        # User-facing workloads that consume infrastructure
                          # (e.g. media-stack). New apps go here, not infra.
clusters/k3s-test/        # 2-node Pi 5 k3s validation overlay (NOT Flux-bootstrapped)
  README.md               # Apply order, deltas vs prod, current cluster state
  NN-<component>/         # One kustomize overlay per component, applied with
                          # `kubectl apply -k` in NN-prefixed order. Each
                          # overlay either copies files (when deltas exist) or
                          # references the prod dir as a base (when identical).
docs/media-stack/SPEC.md  # Storage layout, hardlink contract, NAS vs k3s split
nas/                      # TrueNAS Custom App compose configs (Jellyfin, gluetun+qbit)
                          # Not Flux-managed — NAS isn't k8s. Kept here for repro.
```

## Bootstrap vs GitOps boundary

- **Terraform** (one-shot, side-effecting): Talos identity + per-node config apply + etcd bootstrap; kubeconfig/talosconfig retrieval; Flux install + GitHub deploy key + in-cluster `sops-age` Secret; **pre-Flux Cilium install** (because Flux pods need CNI). `cluster-bootstrap/terraform/flux.tf` uses `lifecycle.ignore_changes = all` on the `helm_release.cilium` so Flux's helm-controller adopts the release on first reconcile.
- **Flux** (continuous): every HelmRelease, ConfigMap, Secret, CronJob, raw manifest. Dependency order is encoded via `dependsOn` in the top-level `clusters/homelab/<component>.yaml` files. After the bootstrap, **no `helm install` or hand `kubectl apply`** is supposed to happen — if it's not in git, it doesn't exist.

The two are linked via `cluster-bootstrap/talos/secrets.sops.yaml`, which holds the Talos cluster identity (etcd certs, CA, bootstrap token) SOPS-encrypted in git. Terraform reads it via `data.sops_file`. Losing TF state is non-fatal: re-clone, decrypt with age key, `terraform apply` reconverges. The age private key is the only out-of-band backup.

## Component dependency graph (prod, `clusters/homelab/`)

```
gateway-api-crds → cilium → ┬→ cert-manager → gateway → headlamp / observability / cloudflared / media-stack
                            ├→ longhorn → backup, observability, media-stack
                            ├→ csi-driver-nfs → backup, media-stack
                            ├→ compute-blade
                            └→ prometheus-operator-crds → vm-stack → victoria-logs → grafana, alloy
```

Anything that needs `monitoring.coreos.com` CRDs must `dependsOn: prometheus-operator-crds` — the `vm-stack` chart's `victoria-metrics-operator.prometheus-operator-crds.enabled` subchart toggle was found to silently no-op in vm-stack chart 0.78.0, so the CRDs are installed standalone.

## `infrastructure/` vs `apps/` split

- **`infrastructure/`** — platform plumbing the cluster needs to function or to host workloads: CNI (cilium), gateway-api-crds, gateway, cert-manager, longhorn, csi-driver-nfs, observability stack (vm-stack/loki/alloy/grafana/prometheus-operator-crds), compute-blade, headlamp (admin), cloudflared (ingress tunnel), flux-receiver, backup.
- **`apps/`** — user-facing workloads that consume the infrastructure: media-stack (Prowlarr, Radarr, Bazarr, Jellyseerr, Recyclarr) currently; future Vaultwarden, n8n, etc. would land here.

When adding a new component, ask: does the cluster need this to host other things, or is it the thing being hosted? The former is infrastructure, the latter is apps.

## Working in `clusters/homelab/infrastructure/` (and `apps/`)

- Component dir convention: `helmrepository.yaml` + `helmrelease.yaml` + `values.yaml` (chart values, often surfaced through a `configMapGenerator`) + raw manifests (`namespace.yaml`, HTTPRoutes, etc.) + `kustomization.yaml` listing them.
- HTTPRoute hostnames use the literal placeholder `<YOUR_DOMAIN>` in prod manifests. The k3s-test overlay sed-substitutes it to `raphlamenace.xyz`. Keep this convention for new HTTPRoutes — don't hardcode the domain in `clusters/homelab/`.
- Secrets in prod live as `*.sops.yaml` (SOPS-encrypted via the in-cluster `sops-age` Secret). The k3s-test overlay replaces them with plain Secrets created at apply time. See `clusters/homelab/infrastructure/cert-manager/cloudflare-token.sops.yaml` as the canonical pattern.
- When adding a new top-level Flux Kustomization (e.g. `clusters/homelab/foo.yaml`), **append it to `clusters/homelab/kustomization.yaml`'s `resources:` list**. The explicit aggregator exists because Flux's kustomize-controller auto-discovers files and a silent drop on rename is the failure mode it prevents.

## Working in `clusters/k3s-test/`

- The overlay is **not** Flux-bootstrapped. Only Flux controllers (source / kustomize / helm / notification) run — no `GitRepository` or `Kustomization` CRs. Each `NN-<component>/` is applied with `kubectl apply -k` manually in NN order. The Flux helm-controller is what reconciles HelmReleases inside each overlay.
- Apply order and deltas vs prod are in `clusters/k3s-test/README.md`. **Update that table whenever the overlay diverges from prod** (e.g. compute-blade nodeSelector pin, longhorn 2-replica setting, etc.).
- **Kustomize `LoadRestrictionsRootOnly`** blocks `../..` file refs. Overlays therefore copy files from prod rather than referencing them. Yes, this duplicates content; the alternative is `--load-restrictor=LoadRestrictionsNone` which leaks file access. Live with the copies.
- `HelmRepository` resources must stay in `flux-system`. A top-level `namespace: foo` in a kustomization clobbers ALL resources including HelmRepositories, breaking `HelmRelease.sourceRef`. The 20-cilium / 30-cert-manager overlays therefore have **no top-level `namespace:`** — each resource carries its own.
- Bugs found in prod manifests during k3s-test validation: fix in `clusters/homelab/infrastructure/` first, then mirror to the overlay. Log the fix in the "Findings against the prod manifests" table in `clusters/k3s-test/README.md`.

## Common commands

```bash
# k3s-test kubeconfig (the test cluster's KUBECONFIG)
export KUBECONFIG=~/.kube/configs/k3s-test

# Apply / re-apply a single overlay (manual reconcile in test cluster)
kubectl apply -k clusters/k3s-test/61-vm-stack

# Big CRD bundles (Gateway API httproutes) need server-side apply
kubectl apply --server-side=true --force-conflicts \
  -f clusters/homelab/infrastructure/gateway-api-crds/standard-install.yaml

# Validate a kustomization builds before applying (prod manifests)
kustomize build clusters/homelab/infrastructure/media-stack >/dev/null && echo OK
kustomize build clusters/homelab >/dev/null && echo aggregate OK

# Validate an overlay builds
kubectl kustomize clusters/k3s-test/70-media-stack >/dev/null && echo overlay OK

# Inspect Flux state inside the test cluster (controllers run there too)
flux get helmreleases -A
kubectl -n <ns> describe helmrelease <name>

# Re-fetch Gateway API CRDs (experimental channel; filename retained)
bash clusters/homelab/infrastructure/gateway-api-crds/.fetch.sh
```

For the Talos rollout, every command is in `talos-cluster-PLAN.md` Steps 1–9 — follow that file end-to-end rather than improvising.

## Gotchas worth keeping in mind

- **Gateway API channel**: Cilium 1.19 needs `TLSRoute v1alpha2`, which the standard channel no longer serves in v1.5.x. `.fetch.sh` pulls the **experimental** bundle (filename kept as `standard-install.yaml` for git-history continuity). The bundle ships a `safe-upgrades` ValidatingAdmissionPolicy that blocks channel re-flip; delete it before re-applying a different channel.
- **`local-path` and `longhorn` both annotate themselves as default StorageClass** on k3s. Cosmetic; resolve only if it bites a specific install.
- **`observability` namespace PSA = `privileged`** (not `baseline`): `prometheus-node-exporter` needs `hostNetwork`/`hostPID`/`hostPath`/`hostPort`. Baseline blocks all four → 0 pods scheduled.
- **`vmsingle` accepts flat PVCSpec, `vmalertmanager` requires `volumeClaimTemplate.spec`** wrapper — same chart, different CRDs. Don't copy-paste the storage block between the two.
- **Media stack `/data` PV**: a single static NFS PV (`192.168.1.25:/mnt/mega-tank/media`) bound RWX, NOT the dynamic `nfs-truenas` StorageClass (which points at `apps/k8s` and creates per-PVC subfolders). The hardlink contract in `docs/media-stack/SPEC.md` requires one filesystem AND one NFS export covering both `movies/` and `downloads/` — don't split it.
- **Heavy-IO media apps (Jellyfin, qBittorrent+Gluetun) stay on the NAS as Docker compose**, even in the final Talos version. Confirmed with the user. Light/API apps (Prowlarr, Radarr, Bazarr, Jellyseerr, Recyclarr) run on the cluster and route through `/data` via the NFS PV. NAS-hosted services are wired through the cluster Gateway via selector-less `Service` + manual `EndpointSlice` so traffic shows up in Hubble.

## Secrets

`.sops.yaml` defines encryption rules. **The repo currently has `AGE_PUBLIC_KEY_TODO_REPLACE_ME` placeholders** — these get filled in during `talos-cluster-PLAN.md` Step 1 before any prod secret is encrypted. The placeholder is grep-friendly on purpose. Until then, all encrypted secrets in `clusters/homelab/` are stand-ins to be re-encrypted at bootstrap time.
