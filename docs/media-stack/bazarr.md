# bazarr/

Subtitle automation. Reads Radarr's library, fetches `.srt` files, drops them
next to the movie.

## Setup (UI → `https://bazarr.lab.<YOUR_DOMAIN>/`)

### 1. Languages — Settings → Languages

- **Language Filter**: add `English` and `French`.
- **Languages Profiles → New Profile**:
  - Name: `English + French`
  - Languages: `English`, `French` (drag the preferred one to the top — Bazarr
    prioritises by order)
  - Cutoff: `None` (so Bazarr keeps searching until BOTH are fetched; setting
    a cutoff stops the search once that one is found)
  - Hearing Impaired / Forced: leave unchecked unless you specifically need them
- Save.

### 2. Providers — Settings → Providers

Add at least two for French coverage (Podnapisi alone is light on FR):

- **OpenSubtitles.com** — free account at opensubtitles.com (NOT `.org` — different
  site, paid). Best overall coverage including French.
- **Podnapisi** — no account. Good EN; OK FR.
- **Wizdom** *(optional)* — small but solid for French.

VIP/paid providers (Addic7ed-VIP, Subscene) skip — not worth it for FR.

### 3. Radarr — Settings → Radarr

- Use Radarr: ✓
- Hostname / IP: `radarr.media.svc.cluster.local`
- Port: `7878`
- Base URL: *(empty)*
- SSL: ✗
- API Key:
  ```bash
  kubectl -n media get secret media-stack-api-keys -o jsonpath='{.data.radarr}' | base64 -d
  ```
- Default Language Profile: `English + French`
- Test → green → Save.

## Verify

- Movies tab populates within ~30s after Save.
- A movie row shows the language flag(s) once a subtitle is found.
