# grafana

Chart-installed Grafana, exposed at `http://192.168.1.201` (Cilium L2 LB).

## Admin password (generated at action time)

The Helm values reference `existingSecret: grafana-admin`. Generate the secret post-`age-keygen`:

```bash
NS=observability
ADMIN_PASS=$(openssl rand -base64 32)
cat > admin-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: $NS
type: Opaque
stringData:
  admin-user: admin
  admin-password: $ADMIN_PASS
EOF
sops --encrypt --in-place admin-secret.yaml
mv admin-secret.yaml admin-secret.sops.yaml
echo "Admin password (back this up): $ADMIN_PASS"

git add admin-secret.sops.yaml && git commit -m "feat(grafana): seed admin secret" && git push
```

The `clusters/homelab/grafana.yaml` Flux Kustomization has `decryption: { provider: sops, secretRef: { name: sops-age } }` so it can decrypt this Secret at apply time.

Without this seed, Grafana would launch with the chart's default `admin/admin`, exposed on the LAN until manually rotated.
