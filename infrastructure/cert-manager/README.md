# cert-manager

Issues Let's Encrypt TLS certs via **DNS-01 against Cloudflare** for the wildcard `*.${DOMAIN}` cert consumed by `infrastructure/gateway/`.

## Action-time setup (post-Flux-bootstrap)

### 1. Domain wiring

Hostnames in the base manifests use the Flux variable `${DOMAIN}`, substituted
per cluster via `postBuild.substituteFrom` from the `cluster-vars` ConfigMap in
`clusters/<name>/cluster-vars.yaml` — no sed, no placeholder. The ACME contact
email is hardcoded in `clusterissuer-{prod,staging}.yaml`.

### 2. Generate a Cloudflare scoped API token

Cloudflare dashboard → My Profile → API Tokens → **Create Token** → **Custom token**:

- **Token name:** `cert-manager-dns01-<cluster>`
- **Permissions:**
  - `Zone` → `DNS` → `Edit`
  - `Zone` → `Zone` → `Read`
- **Zone Resources:** Include → Specific zone → your domain
- TTL: leave as "All zones cached" or set a date if you want auto-rotation

Copy the token immediately (Cloudflare won't show it again).

### 3. SOPS-encrypt the token Secret

```bash
TOKEN=<paste-the-token>
cat > infrastructure/cert-manager/cloudflare-token.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: $TOKEN
EOF
sops --encrypt --in-place infrastructure/cert-manager/cloudflare-token.yaml
mv infrastructure/cert-manager/cloudflare-token.yaml \
   infrastructure/cert-manager/cloudflare-token.sops.yaml

git add infrastructure/cert-manager/cloudflare-token.sops.yaml
git commit -m "feat(cert-manager): seed Cloudflare DNS-01 token"
git push
```

### 4. Create the DNS records in Cloudflare

In Cloudflare → DNS → Records, add:

- Type `A`, Name `*.lab`, IPv4 `192.168.1.200`, Proxy status **DNS only (grey cloud)**
- Type `A`, Name `lab`, IPv4 `192.168.1.200`, Proxy status **DNS only**

Why proxy off:
- The IP is a LAN address (192.168.x), so Cloudflare proxying would just black-hole it.
- DNS-01 challenge doesn't care about proxying — only TXT record provisioning, which Cloudflare's API handles regardless.

The records resolve publicly to a LAN IP. That's intentional (split-horizon-by-omission: only LAN clients can reach the IP). Acceptable trade-off vs. running internal DNS.

### 5. Verify

After ~2 min:

```bash
kubectl -n cert-manager get clusterissuer
# letsencrypt-prod:   Ready=True
# letsencrypt-staging: Ready=True

kubectl -n gateway get certificate lab-wildcard
# READY=True   after Cloudflare DNS-01 challenge succeeds (~30-90s)

kubectl -n gateway describe certificate lab-wildcard | tail -20
# Events: "The certificate has been successfully issued"
```

If the Certificate is stuck:

```bash
kubectl -n gateway describe challenge        # look at DNS-01 challenge state
kubectl -n cert-manager logs deploy/cert-manager
```

Common failures: scoped token missing `Zone:Read`, DNS records not propagated yet (give it 60s), or the token Secret in the wrong namespace.

## Switching to staging during testing

To validate a new Certificate without hitting Let's Encrypt prod rate limits, temporarily change `infrastructure/gateway/certificate.yaml`:

```yaml
issuerRef:
  name: letsencrypt-staging   # was letsencrypt-prod
```

Commit, push, wait for reconcile. The staging cert will be browser-untrusted but the issuance path is otherwise identical. Switch back when done.
