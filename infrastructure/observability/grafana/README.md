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

## Adding a dashboard (pure IaC)

Dashboards are bundled as JSON files in `./dashboards/` and turned into ConfigMaps labeled `grafana_dashboard: "1"` via `configMapGenerator` in `kustomization.yaml`. A sidecar (`grafana-sc-dashboard`) watches those ConfigMaps and reconciles them into `/tmp/dashboards/` inside the Grafana container — including **removing** files when a ConfigMap is deleted. No PVC orphans, no UI changes survive a pod restart, no runtime grafana.com fetch.

Why not the chart's `dashboards.<provider>.<name>.gnetId` block? It only populates ConfigMaps under the init-container path, not the sidecar path. Combined with sidecar mode it silently produces empty ConfigMaps. The bundled-JSON approach sidesteps that.

To add one:

```bash
# 1. Fetch the JSON from grafana.com (replace <id> and <rev>).
curl -fsSL "https://grafana.com/api/dashboards/<id>/revisions/<rev>/download" \
  -o infrastructure/observability/grafana/dashboards/<name>.json

# 2. Append an entry to kustomization.yaml's configMapGenerator (mirror the
#    existing pattern; the `options.labels` block is what makes the sidecar
#    discover it). Keep the generated ConfigMap's
#    kustomize.toolkit.fluxcd.io/substitute: disabled annotation — dashboard
#    JSON bodies contain their own Grafana ${...} template syntax, which
#    Flux's envsubst would otherwise try (and fail) to resolve.

# 3. Commit. Flux reconciles. The sidecar writes the file within ~30s.
```

vm-stack already ships ~16 bundled dashboards (kubernetes-views-*, victoriametrics-*, node-exporter-full, alertmanager-overview, etcd, ...) as labeled ConfigMaps — these come along for free since `sidecar.dashboards.searchNamespace: ALL` discovers them. Don't re-add anything vm-stack already provides.
