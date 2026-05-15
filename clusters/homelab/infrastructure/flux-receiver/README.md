# flux-receiver

Push-based reconciliation: GitHub → smee.io → in-cluster smee-client → notification-controller's webhook-receiver → triggers `GitRepository/flux-system`.

Polling intervals are bumped to `1h` everywhere. Without this receiver, that's the worst case lag. With it: ~5s from `git push` to first reconcile.

## Action-time setup

After Flux is bootstrapped and `kubectl -n flux-system get deploy notification-controller` is Ready:

### 1. Allocate a smee.io channel

```bash
open https://smee.io/new
# Copy the channel URL it generates, e.g. https://smee.io/AbCdEfGh12345
```

### 2. Generate a webhook HMAC token + write the Receiver secret

```bash
WEBHOOK_TOKEN=$(openssl rand -hex 32)
cat > clusters/homelab/infrastructure/flux-receiver/secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-webhook-token
  namespace: flux-system
type: Opaque
stringData:
  token: $WEBHOOK_TOKEN
EOF
sops --encrypt --in-place clusters/homelab/infrastructure/flux-receiver/secret.yaml
mv clusters/homelab/infrastructure/flux-receiver/secret.yaml \
   clusters/homelab/infrastructure/flux-receiver/secret.sops.yaml

git add clusters/homelab/infrastructure/flux-receiver/secret.sops.yaml
git commit -m "feat(flux-receiver): seed GitHub HMAC token"
git push   # smee will replay all pending webhooks once smee-client is online
```

### 3. Configure GitHub webhook

In the repo's GitHub Settings → Webhooks → Add webhook:

- **Payload URL:** the smee.io channel URL from step 1
- **Content type:** `application/json`
- **Secret:** `$WEBHOOK_TOKEN` from step 2
- **Events:** Just the `push` event (and `ping` by default)

### 4. Read the Receiver's webhook path and write smee-config

Wait until `kubectl -n flux-system get receiver github-receiver` shows `Ready=True`, then:

```bash
RECEIVER_PATH=$(kubectl -n flux-system get receiver github-receiver \
                  -o jsonpath='{.status.webhookPath}')
echo "Receiver path: $RECEIVER_PATH"

SMEE_URL=https://smee.io/<paste-channel-id>

cat > clusters/homelab/infrastructure/flux-receiver/smee-config.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: smee-config
  namespace: flux-system
type: Opaque
stringData:
  url: $SMEE_URL
  path: $RECEIVER_PATH
EOF
sops --encrypt --in-place clusters/homelab/infrastructure/flux-receiver/smee-config.yaml
mv clusters/homelab/infrastructure/flux-receiver/smee-config.yaml \
   clusters/homelab/infrastructure/flux-receiver/smee-config.sops.yaml

git add clusters/homelab/infrastructure/flux-receiver/smee-config.sops.yaml
git commit -m "feat(flux-receiver): wire smee channel to receiver path"
git push
```

### 5. Verify

```bash
# In GitHub: Settings → Webhooks → click the webhook → "Recent Deliveries" → "Redeliver"
kubectl -n flux-system logs deploy/smee-client --tail=20
# Expect: "POST http://webhook-receiver... 200"
flux events --watch -A | grep -i 'github-receiver'
# Expect: "Reconciliation requested by github-receiver"
```

After this, any `git push` to `main` reconciles the cluster within seconds — no waiting on the 1h polling fallback.
