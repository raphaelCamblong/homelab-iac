# tailscale

A single Tailscale node in the cluster, running as a **subnet router** so
everything on the tailnet can reach the home LAN (`192.168.1.0/24`) — and,
if you extend `TS_ROUTES`, the cluster's ClusterIP services — without exposing
anything publicly. Userspace networking, so no `NET_ADMIN` / `/dev/net/tun`.

Node state lives in the `tailscale-state` Secret (see `rbac.yaml`), so pod
restarts keep the same tailnet identity instead of re-authenticating.

This is deliberately **not** the Tailscale Kubernetes Operator — that's CRD
machinery for dynamically exposing many Services. This is one node; a plain
Deployment (mirroring `cloudflared/`) is enough.

## Action-time setup

1. **Create an auth key.** Tailscale admin console →
   Settings → Keys → *Generate auth key*. Make it **Reusable** and
   **Pre-approved** (tag it if your ACLs require tags). A short-lived key is
   fine because state is persisted in the `tailscale-state` Secret — but the
   key must still be valid the first time the pod boots.

2. **SOPS-encrypt the auth key Secret and commit it** (same pattern as
   `cloudflared`):

   ```bash
   TS_AUTHKEY=<paste-from-tailscale-admin>
   cat > clusters/homelab/infrastructure/tailscale/auth.yaml <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: tailscale-auth
     namespace: tailscale
   type: Opaque
   stringData:
     authkey: $TS_AUTHKEY
   EOF
   sops --encrypt --in-place clusters/homelab/infrastructure/tailscale/auth.yaml
   mv clusters/homelab/infrastructure/tailscale/auth.{yaml,sops.yaml}
   # add it to kustomization.yaml resources:
   git add clusters/homelab/infrastructure/tailscale/
   git commit -m "feat(tailscale): seed auth key"
   git push
   ```

3. **Approve the advertised route.** After the pod is up, Tailscale admin
   console → Machines → `homelab` → *Edit route settings* → enable
   `192.168.1.0/24`. Until approved, the node is on the tailnet but routes
   nothing.

## Adding the cluster Service CIDR

To hit ClusterIP services (e.g. `grafana.observability.svc`) over the tailnet,
append the Service CIDR to `TS_ROUTES` in `deployment.yaml`:

- k3s: `10.43.0.0/16`
- Talos (prod default): `10.96.0.0/12`

then re-approve the new route in the admin console.
