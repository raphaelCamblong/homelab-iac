# prowlarr/

Indexer manager. Pushes indexers to Radarr via the Apps sync.

API key is pinned by the env-var override in the Prowlarr Deployment
(`apps/media-stack/prowlarr/deployment.yaml`) — first launch
goes straight to the dashboard, no wizard.

## Setup (UI → `https://prowlarr.lab.<YOUR_DOMAIN>/`)

### 1. Add indexer(s) — Indexers → Add Indexer

Pick indexers **without** the "Cloudflare DDoS Protection" warning in the
modal. FlareSolverr was tried and dropped (Cloudflare's challenge has
outpaced FlareSolverr's headless-Chrome solve since 2025).

Public, no account, CF-free:

- **BTDigg** — DHT crawler, broad coverage
- **YTS** — movies, small file sizes
- **TheRARBG** — RARBG clone, good metadata

Private trackers: need a per-site account + cookie/API key.

Test → green → Save.

### 2. Add Radarr — Settings → Apps → Add → Radarr

- Sync Level: `Add and Remove Only`
- Prowlarr Server: `http://prowlarr.media.svc.cluster.local:9696`
- Radarr Server: `http://radarr.media.svc.cluster.local:7878`
- API Key:
  ```bash
  kubectl -n media get secret media-stack-api-keys -o jsonpath='{.data.radarr}' | base64 -d
  ```
- Test → green → Save.

### 3. Force-push indexers — System → Tasks → Sync App Indexers → Run

## Verify

- Indexers tab: green status on every row.
- Apps tab: Radarr green.
- In Radarr → Indexers: same indexer(s) appear, named `Prowlarr - <name>`.
