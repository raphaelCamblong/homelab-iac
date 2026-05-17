# jellyseerr/

Request UI. Users browse → request → Radarr auto-grabs.

API key is wizard-generated on first launch (NOT env-var-pinnable). After the
wizard, capture the key into the Secret per [`./SETUP.md`](./SETUP.md).

## Setup (UI → `https://jellyseerr.lab.<YOUR_DOMAIN>/`)

### 1. First-launch wizard — sign in with Jellyfin

- Server URL: `http://jellyfin-nas.media.svc.cluster.local:8096`
- Sign In with Jellyfin → use your Jellyfin admin credentials.
- Library selection: tick `Movies`.
- Finish.

### 2. Add Radarr — Settings → Services → Radarr → Add Radarr Server

- Server Name: `Radarr`
- Default Server: ✓
- 4K Server: ✗
- Hostname / IP: `radarr.media.svc.cluster.local`
- Port: `7878`
- SSL: ✗
- API Key:
  ```bash
  kubectl -n media get secret media-stack-api-keys -o jsonpath='{.data.radarr}' | base64 -d
  ```
- Test → green, then fill the now-populated dropdowns:
  - Quality Profile: `HD Bluray + WEB`
  - Root Folder: `/data/movies`
  - Minimum Availability: `Released`
- Enable Scan: ✓
- Save Changes.

### 3. Update the Secret with the wizard-generated API key (one-time)

See [`./SETUP.md`](./SETUP.md) "Post-Jellyseerr-wizard" snippet.

## Verify

- Settings → Services: Radarr row green.
- Request a movie from the search bar → it appears in Radarr's queue within 30s.
