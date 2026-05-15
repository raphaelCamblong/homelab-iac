# Talos Cluster — Platform Specification

Modern, GitOps-driven Kubernetes platform on 3× Raspberry Pi CM5 + Compute Blade + NVMe. Replaces the old k3s + ansible + external-Postgres setup.

This document is the **platform spec only** (OS, k8s, CNI, storage, GitOps, observability). App workloads live under `apps/` and are deployed by Flux — out of scope here.

Implementation details → `./talos-cluster-PLAN.md`.

---

## Goals & non-goals

**Goals**
- HA Kubernetes cluster, 3-node etcd quorum.
- Immutable, declarative OS — no ansible, no SSH, no drift.
- One source of truth (git + Flux) for everything inside the cluster.
- SOPS-encrypted secrets in git, no plaintext tokens.
- Lean observability: metrics, logs, network flows.

**Non-goals (deferred or excluded)**
- Remote / external nodes (KubeSpan + Tailscale paths exist, not enabled).
- Policy engine (Kyverno), dep automation (Renovate), service mesh sidecars, ClusterMesh.
- Workload-specific decisions — apps decided per-app.

---

## Hardware

| Item | Spec |
| --- | --- |
| Nodes | 3× Raspberry Pi CM5 on Compute Blade |
| RAM / CPU | 8 GB / 4 cores per node |
| Storage | M.2 NVMe SSD per node (no SD card) |
| Boot | NVMe via EEPROM boot order |
| Network | Gigabit, interface `enX0` |
| Fan/LED | `compute-blade-agent` DaemonSet (Talos has no userspace daemon) |

---

## Distro: Talos Linux

- Immutable arm64 image from [factory.talos.dev](https://factory.talos.dev), target **Raspberry Pi 5**.
- No SSH, no shell, no apt. Everything via `talosctl` (gRPC + mTLS).
- A/B partition upgrades with automatic rollback.
- **Built-in control-plane VIP** — replaces kube-vip for the API server.

**Factory image extensions:** `iscsi-tools` + `util-linux-tools` (Longhorn requirements). Adding extensions later = regenerate image + rolling node upgrade.

---

## HA topology

- All 3 CM5s are **control plane + worker** (CP nodes untainted; small-cluster standard).
- etcd embedded, 3-node quorum, bootstrapped 3-node from day one.
- One node down → cluster operational (5-min pod reschedule).
- Two nodes down → running pods keep running, API read-only.

**Upgrades:** one node at a time, `kubectl drain` first, then `talosctl upgrade`. K8s minor version pinned in Talos machine config.

---

## Networking

| Concern | Choice |
| --- | --- |
| CNI | **Cilium** (eBPF), kube-proxy replacement |
| API VIP | Talos built-in VIP — no kube-vip |
| Service LB | Cilium L2 announcements — no MetalLB |
| Ingress | Cilium Gateway API — no Traefik / Nginx |
| Network observability | Hubble |
| Pod encryption | Cilium WireGuard (transparent, no sidecars) |

### IP plan (defaults — adjust if LAN differs)

| Setting | Value |
| --- | --- |
| LAN | `192.168.1.0/24` |
| Node IPs | `192.168.1.51` / `.52` / `.53` |
| API VIP | `192.168.1.140` |
| LB pool | `192.168.1.200`–`192.168.1.220` |
| Pod / Service CIDR | `10.244.0.0/16` / `10.96.0.0/12` |
| API hostname | `k8s.lan` (LAN) + Tailscale MagicDNS (admin) |

Node IPs, VIP, LB pool **must be outside DHCP range**.

---

## Storage

| StorageClass | Backend | Access | Use for |
| --- | --- | --- | --- |
| `longhorn` (default) | Replicated NVMe block, 3 replicas | RWO | DB PVCs, app configs, anything wanting snapshots |
| `nfs-truenas` | TrueNAS NFS export | RWX | Shared/large/multi-pod volumes |

- Longhorn requires `iscsi-tools` extension (already in image).
- NFS client built into Talos kernel; CSI driver via Helm.

---

## Bootstrap vs GitOps boundary

**Terraform** (one-shot, side-effecting):
- Talos secrets + per-node config apply + etcd bootstrap.
- Kubeconfig + talosconfig retrieval.
- Flux installation + GitHub deploy key + in-cluster `sops-age` Secret.

**Flux** (continuous reconciliation from git):
- Every HelmRelease, ConfigMap, CronJob, Secret, CRD-based resource.
- Reconciliation order via `dependsOn` graph.

> **After Phase 5: no `helm install` or `kubectl apply` ever again. If it's not in git, it doesn't exist.**

**Cluster identity (Talos CA, etcd certs, bootstrap token) lives in git, SOPS-encrypted** at `cluster-bootstrap/talos/secrets.sops.yaml`. Terraform reads it via `data.sops_file`. Losing TF state is no longer fatal: re-clone the repo, decrypt with the age key, `terraform apply` rebuilds against the same cluster identity. The age private key is the only thing that must be backed up out-of-band.

### Repo layout

```
cluster-bootstrap/
  talos/patches/         # Talos config patches (committed)
  terraform/             # Bootstrap module (state gitignored)
clusters/homelab/
  flux-system/           # Auto-managed by Flux
  <component>.yaml       # Top-level Flux Kustomizations w/ dependsOn
  infrastructure/        # HelmReleases + values + manifests
apps/                    # Workload kustomizations (out of platform spec)
```

### Dependency graph

```
gateway-api-crds → cilium → ┬→ longhorn → observability
                            ├→ csi-driver-nfs → backup
                            ├→ compute-blade
                            └→ headlamp
```

---

## Secrets

- **SOPS + age** for everything secret in git: app secrets (decrypted by Flux at apply time) and the Talos cluster identity bundle (decrypted by Terraform at bootstrap time).
- age private key: 1Password / Bitwarden / paper backup. Loss = unrecoverable secrets + unrebuildable cluster.
- `.sops.yaml` defines encryption rules; in-cluster Secret `sops-age` (created by Terraform) holds the key for Flux.
- **External Secrets Operator (ESO)** deferred until there's a real external secrets backend (e.g., Vaultwarden).

---

## Observability & admin UI

| Layer | Component | Notes |
| --- | --- | --- |
| Metrics stack | `victoria-metrics-k8s-stack` chart | Bundles vmsingle (storage), vmagent (scraper), vmalert, kube-state-metrics, node-exporter — drop-in lean kube-prometheus-stack |
| Logs storage | Loki single-binary | Filesystem backend on Longhorn |
| Log shipper | Grafana Alloy (DaemonSet) | Tails pod logs, pushes to Loki — replaces Promtail |
| Dashboards | Grafana | Pre-loaded: Cilium, Longhorn, node-exporter |
| Network flows | Hubble | Cilium-native |
| Admin UI | Headlamp | Flux plugin installed manually post-deploy via in-UI plugin manager |

Default retention: 30 days metrics, 7 days logs.

---

## Backup

- **etcd snapshots** via `talosctl etcd snapshot` CronJob (hourly retain 24h; daily retain 30d).
- Stored on NFS PVC backed by TrueNAS.
- CronJob uses a SOPS-encrypted talosconfig scoped to `os:etcd:backup` role only.
- **Velero deferred** until stateful PVs need more than Longhorn snapshots + etcd snapshots can give.
- **DR triad:** git + etcd snapshot + Longhorn backups — no single failure loses state.

---

## Component summary

| Layer | Component | Replaces |
| --- | --- | --- |
| OS | Talos Linux (arm64 factory image) | Debian + ansible + k3s installer |
| Kubernetes | Vanilla upstream (in Talos) | k3s |
| API VIP | Talos built-in VIP | kube-vip |
| CNI / kube-proxy | Cilium (eBPF) | Flannel + kube-proxy |
| Service LB | Cilium L2 announcements | MetalLB |
| Ingress | Cilium Gateway API | Traefik / Nginx |
| Block storage | Longhorn | — |
| File storage | csi-driver-nfs | — |
| GitOps | FluxCD (OCI sources) | hand-applied manifests |
| Secrets in git | SOPS + age | plaintext tokens |
| Metrics stack | victoria-metrics-k8s-stack (vmsingle + vmagent + KSM + node-exporter) | kube-prometheus-stack |
| Logs | Loki + Grafana Alloy (DaemonSet log shipper) | Promtail |
| Dashboards | Grafana | — |
| Network observability | Hubble | — |
| Admin UI | Headlamp (Flux plugin installed in-UI) | — |
| Backup | `talosctl etcd snapshot` → NFS | — |
| Bootstrap | Terraform (`siderolabs/talos` + `fluxcd/flux`) | hand-run CLIs |
| *Optional later* | Spegel (P2P OCI image mirror) | per-node internet pulls |

---

## Intentionally left out

- Policy engine (Kyverno), dependency automation (Renovate), Velero — deferred until real need.
- Remote / external nodes — KubeSpan + Tailscale extension paths documented but not enabled.
- Service mesh sidecars (Istio / Linkerd) — Cilium WireGuard covers mTLS use case.
- Self-hosted image registry — upstream is fine until rate-limited.
- In-cluster CI/CD (Forgejo Actions / Tekton) — GitHub Actions suffices.

---

## Rollout (high level)

The full `clusters/homelab/` tree + Terraform bootstrap module + Talos patches are already authored in this repo — see `git log -- cluster-bootstrap clusters`. The runbook below is what's left to do once you have physical access:

1. Workstation prep — install tools, generate age key, finalize `.sops.yaml`.
2. Build Talos factory image + flash NVMes for all 3 CM5s.
3. SOPS-encrypt the Talos secrets bundle into `cluster-bootstrap/talos/secrets.sops.yaml`; vendor the Gateway API CRDs.
4. **Terraform apply #1**: Talos config + etcd bootstrap → cluster up, nodes `NotReady`.
5. Generate the role-limited backup talosconfig and commit it (SOPS-encrypted).
6. **Terraform apply #2**: Flux + `sops-age` Secret + GitHub deploy key → Flux pulls the in-git tree and reconciles in dependency order; nodes go `Ready` once Cilium is up.
7. Smoke tests, write `CLUSTER.md`.
8. Deploy apps under `apps/`.

Step-by-step commands → `./talos-cluster-PLAN.md`.
