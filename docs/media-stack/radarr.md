# radarr/

Movie automation. Receives indexers from Prowlarr, sends downloads to qBit on
the NAS, imports into `/data/movies/` via hardlink from `/data/downloads/complete/`.

API key is pinned by the env-var override in the Radarr Deployment
(`clusters/homelab/apps/media-stack/radarr/deployment.yaml`) — first launch
skips the auth wizard.

## Setup (UI → `https://radarr.lab.<YOUR_DOMAIN>/`)

### 1. Root folder — Settings → Media Management → Root Folders → Add

- Path: `/data/movies` → Save.

### 2. Download client — Settings → Download Clients → Add → qBittorrent

- Name: `qBittorrent`
- Host: `qbit-nas.media.svc.cluster.local`
- Port: `8090`
- Username: `admin`
- Password: the one set in qBit's UI (see [`./qbittorrent.md`](./qbittorrent.md))
- Category: `radarr`
- **Post-Import Category** (advanced): `radarr-imported`
- **Remove Completed Downloads**: **OFF (unchecked)**
- Test → green → Save.

> **Why those two settings together?** Default Radarr behavior on completed
> download is `Move` (rename), which silently breaks the SPEC hardlink
> contract — qBit's `/data/downloads/complete/...` reference is orphaned the
> moment Radarr renames the file into `/data/movies/...`. Setting a
> Post-Import Category + Remove Completed Downloads OFF flips Radarr into
> `Copy` mode, which honors `copyUsingHardlinks` and produces a real
> `link(2)` instead of a rename. qBit keeps the torrent under the new
> category (still seeding from `complete/`); Radarr/Jellyfin see the file
> under `movies/`. Same inode, both happy.

### 3. Naming — Settings → Media Management → Movie Naming

- Rename Movies: ✓
- Standard Movie Format:
  ```
  {Movie CleanTitle} ({Release Year}) [{Quality Full}][{Mediainfo VideoCodec}][{Mediainfo AudioCodec} {Mediainfo AudioChannels}]-{Release Group}
  ```
- Movie Folder Format:
  ```
  {Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]
  ```
- Save.

> **Don't paste the TRaSH-Guides template verbatim** without checking syntax.
> Radarr's conditional rendering is `{<token>}` — literal brackets inside
> conditionals like `{[Mediainfo VideoBitDepth]bit}` are NOT parsed (the
> bracketed name isn't a valid token), and you end up with literal
> `{[MediaInfo VideoBitDepth]bit}` strings in filenames. The template above
> uses literal `[...]` OUTSIDE the conditionals, so brackets always render
> and only the token content is substituted. Renders as e.g.
> `Gummo (1997) [Bluray-1080p][x265][FLAC 2.0]-SARTRE.mkv`.

### 4. Importing — Settings → Media Management

- Use Hardlinks instead of Copy: ✓   *(SPEC hardlink contract — necessary but not sufficient; see step 2 note)*
- Import Extra Files: optional
- Save.

### 5. Quality profiles — handled by Recyclarr

Skip the UI here. After running Recyclarr (see [`./SETUP.md`](./SETUP.md) step 7),
profile `HD Bluray + WEB` shows up under Settings → Profiles.

## Verify

- Settings → Indexers: at least one `Prowlarr - <name>` row.
- Settings → Download Clients: qBittorrent green; Post-Import Category set to
  `radarr-imported`; Remove Completed Downloads OFF.
- Settings → Media Management: root folder `/data/movies` listed (and **no
  other root folder** — single misconfigured root has been observed to make
  every movie land in qBit's download dir).
- Settings → Media Management → Movie Naming: preview shows a clean filename
  with no `{...}` literals.
- Add a small test movie → it picks a release → qBit downloads → import.
  Then **verify the hardlink directly on the NAS** (do not skip — `Move`
  vs `link` failures are silent):
  ```bash
  ssh truenas_admin@192.168.1.25 \
    'sudo ls -li "/mnt/mega-tank/media/movies/<Title> (<Year>)"*/*.mkv \
                 /mnt/mega-tank/media/downloads/complete/<release>*/*.mkv'
  ```
  Same first column (inode) AND link count ≥ 2 on both rows = SPEC contract
  holds. Link count 1 on each = Radarr renamed instead of hardlinked → step 2
  config not applied or the live qBit client config drifted; re-check.
