# Media stack — first-launch setup

Manual one-time UI walkthrough per app. Total time: ~15 min. Re-run on each
fresh-PVC rebuild (i.e. Talos cutover). Servarr env-vars pin Prowlarr+Radarr
API keys so values stay constant across rebuilds.

> **Why no automation tool?** Buildarr was evaluated (May 2026) — all four
> plugins last released March-April 2024, and 2 of 3 needed plugins crashed
> against current Radarr/Jellyseerr API responses (`colonReplacementFormat:
> "smart"` enum, removed `trustProxy` field). Ansible/Terraform/Configarr
> ecosystems for Servarr apps are similarly stale. ~150 lines of custom code
> would have higher lifetime maintenance cost than the ~15-min manual pass on
> the rare rebuild. Revisit if a maintained tool appears or rebuild cadence
> changes.

## 0. API-key Secret (one-time)

### Prod (Talos + SOPS)

```bash
PROWLARR_KEY=$(openssl rand -hex 16)
RADARR_KEY=$(openssl rand -hex 16)
JELLYSEERR_KEY=$(openssl rand -hex 16)   # for reference only — overwritten after Jellyseerr wizard

cat > clusters/homelab/apps/media-stack/secrets/api-keys.yaml <<EOF
apiVersion: v1
kind: Secret
metadata: { name: media-stack-api-keys, namespace: media }
type: Opaque
stringData:
  prowlarr: $PROWLARR_KEY
  radarr: $RADARR_KEY
  jellyseerr: $JELLYSEERR_KEY
EOF
sops --encrypt --in-place clusters/homelab/apps/media-stack/secrets/api-keys.yaml
mv clusters/homelab/apps/media-stack/secrets/api-keys{,.sops}.yaml
git add clusters/homelab/apps/media-stack/secrets/api-keys.sops.yaml
git commit -m "feat(media-stack): seed API-key Secret"
```

### k3s-test (no SOPS)

```bash
export KUBECONFIG=~/.kube/configs/k3s-test
kubectl -n media create secret generic media-stack-api-keys \
  --from-literal=prowlarr=$(openssl rand -hex 16) \
  --from-literal=radarr=$(openssl rand -hex 16) \
  --from-literal=jellyseerr=placeholder
kubectl -n media rollout restart deploy/prowlarr deploy/radarr
```

Verify the env-var override picked up:

```bash
kubectl -n media exec deploy/radarr -- \
  curl -sH "X-Api-Key: $(kubectl -n media get secret media-stack-api-keys -o jsonpath='{.data.radarr}' | base64 -d)" \
  http://localhost:7878/api/v3/system/status | head -c 80
```

A JSON blob = OK; HTTP 401 = env-var not applied (check pod restart).

## 1-6. Per-app setup (in this order)

1. **qBittorrent (NAS)** — [`./qbittorrent.md`](./qbittorrent.md)
   (rotate WebUI pw + set `/data/downloads/` save paths). **Do this before
   adding torrents** — the default `/downloads/` writes inside the container
   filesystem, invisible to Radarr.
2. **Jellyfin (NAS)** — [`./jellyfin.md`](./jellyfin.md)
   (admin user + Movies library at `/data/movies` + Intel QSV transcoding).
3. **Prowlarr** — [`./prowlarr.md`](./prowlarr.md) (indexers + Apps → Radarr)
4. **Radarr** — [`./radarr.md`](./radarr.md) (root folder + download client)
5. **Jellyseerr** — [`./jellyseerr.md`](./jellyseerr.md) (Jellyfin wizard + Radarr service)
6. **Bazarr** — [`./bazarr.md`](./bazarr.md) (providers + languages + Radarr)

## 7. Trigger Recyclarr (quality profiles + custom formats)

Don't wait for the daily 04:30 CronJob:

```bash
kubectl -n media create job --from=cronjob/recyclarr recyclarr-init-$(date +%s)
kubectl -n media logs -f -l job-name=recyclarr-init-...
```

Verify in Radarr → Settings → Profiles: `HD Bluray + WEB` exists.

## 8. End-to-end smoke

Jellyseerr → request a small public-domain title → Radarr picks it up → qBit
downloads → import → hardlink at `/data/movies/...`. Inode check on NAS:

```bash
ssh truenas_admin@192.168.1.25 \
  'ls -li /mnt/mega-tank/media/movies/<title>/* /mnt/mega-tank/media/downloads/complete/<title>/*'
```

Same inode number on both rows = hardlink contract holds.

## Post-Jellyseerr-wizard: update the Secret

The wizard generates a Jellyseerr API key in `/app/config/settings.json`.
Capture it and patch the Secret so other tooling (e.g. Bazarr → Jellyseerr if
ever wired) has a stable reference:

```bash
JELLYSEERR_KEY=$(kubectl -n media exec deploy/jellyseerr -- \
  sh -c 'cat /app/config/settings.json' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["main"]["apiKey"])')
kubectl -n media patch secret media-stack-api-keys \
  --type=json -p="[{\"op\":\"replace\",\"path\":\"/data/jellyseerr\",\"value\":\"$(echo -n $JELLYSEERR_KEY | base64)\"}]"
```
