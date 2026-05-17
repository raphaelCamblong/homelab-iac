# cloudflared

Cloudflare Tunnel daemon. Establishes outbound persistent connections to
Cloudflare's edge so inbound traffic from `*.raphlamenace.xyz` reaches the
cluster via the dashboard-configured ingress (no inbound firewall rules).

2 replicas. Cloudflare load-balances inbound across all connected replicas
for the same tunnel ID, so one pod down = zero downtime.

## Action-time setup

The `TUNNEL_TOKEN` is the long-lived secret tying this deployment to a
specific tunnel in your Cloudflare account. Get it from:

  Cloudflare Zero Trust → Networks → Tunnels → `<tunnel-name>` →
  Install connector → "Docker" tab → copy the token from
  `--token <TOKEN>` in the displayed command.

SOPS-encrypt the Secret and commit it:

```bash
TUNNEL_TOKEN=<paste-from-cloudflare-dashboard>
cat > clusters/homelab/infrastructure/cloudflared/secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-tunnel
  namespace: cloudflared
type: Opaque
stringData:
  tunnel-token: $TUNNEL_TOKEN
EOF
sops --encrypt --in-place clusters/homelab/infrastructure/cloudflared/secret.yaml
mv clusters/homelab/infrastructure/cloudflared/secret.{yaml,sops.yaml}
git add clusters/homelab/infrastructure/cloudflared/secret.sops.yaml
git commit -m "feat(cloudflared): seed tunnel token"
git push
```

On the k3s-test cluster (no SOPS), the overlay applies a plain Secret at
`clusters/k3s-test/55-cloudflared/secret.yaml`. Edit that file with the
actual token and apply.

## Cutover from NAS-hosted cloudflared

If you previously ran cloudflared on the NAS (TrueNAS Custom App) and are
moving it here:

1. Deploy this Kustomization with the **same** `TUNNEL_TOKEN` as the NAS
   app. Cloudflare allows multiple connectors per tunnel; the cluster
   replicas register alongside the NAS one without disrupting traffic.
2. Verify the cluster pods show up in
   Cloudflare → Networks → Tunnels → `<tunnel>` → Connectors. There should
   be 2 new connectors named like `cloudflared-<podsuffix>`.
3. Stop the NAS app:
   ```bash
   ssh truenas_admin@192.168.1.25 'sudo midclt call -j app.stop cloudflared'
   ```
   Cloudflare drains the NAS connector; cluster replicas take over.
4. Once traffic is verified flowing via the cluster, delete the NAS app:
   ```bash
   ssh truenas_admin@192.168.1.25 'sudo midclt call -j app.delete cloudflared'
   ```
