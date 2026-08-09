# wireguard (wg-easy)

Self-hosted WireGuard VPN with a web UI, replacing the wg-easy that used to run
by hand on the edge Pi (192.168.1.30).

- **VPN socket**: LoadBalancer UDP 51820 on `${WG_LB_IP}` (Cilium LB-IPAM, L2
  announced on eth0). The router forwards public UDP 51820 → that IP.
- **Web UI**: `wg.${DOMAIN}` through the cluster Gateway — LAN-only, same as
  every other `lab.*` host. Not exposed publicly.
- **State**: peers + keys in the `wireguard-config` Longhorn PVC, annotated
  `prune: disabled` so a Kustomization removal can't wipe every client config.

## What the old edge deployment got wrong (fixed here)

| Old | Problem | Now |
| --- | --- | --- |
| `WG_DEFAULT_ADDRESS=192.168.1.x` | clients numbered inside the LAN they dial in to reach → address collisions | `10.8.0.0/24` |
| no auth on the UI (v14, no password set) | anyone on the LAN could add peers | admin password from a SOPS secret |
| `WG_HOST` = hardcoded public IP | breaks on every ISP IP rotation | `${WG_HOST}` cluster-var, one place to change |
| container on a single Pi, managed by hand | invisible to git, no drift correction | Flux-reconciled like everything else |

## Action-time setup

1. **Router**: forward public **UDP 51820 → `${WG_LB_IP}`** (see
   `clusters/homelab/cluster-vars.yaml` for the current value).
2. **Admin password** (generated at deploy time, never in plaintext in git):
   ```bash
   sops -d infrastructure/wireguard/admin-secret.sops.yaml | yq '.stringData.password'
   ```
   Log in at `https://wg.${DOMAIN}` with user `admin`.
3. **Add clients** in the UI → scan the QR code. Peers are per-device; the two
   old peers on the edge Pi are not migrated (new server keys → new configs).

`INIT_*` env vars in `deployment.yaml` apply on **first start only**. To change
them later, edit in the UI — or delete the PVC to re-bootstrap from scratch.

## Public endpoint: IP vs DNS

`WG_HOST` is currently the raw public IP. If the ISP rotates it, every existing
client config breaks. The durable fix is a DNS-only (grey-cloud) A record such
as `vpn.raphlamenace.xyz` → public IP, set as `WG_HOST` instead: WireGuard is
UDP and cannot be proxied by Cloudflare, so the record must stay unproxied.
