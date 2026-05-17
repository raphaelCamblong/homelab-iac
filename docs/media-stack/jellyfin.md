# jellyfin

Media server. Streams from `/data/movies/` (NFS-shared with Radarr), uses
Intel iGPU at `/dev/dri/renderD128` for hardware-accelerated transcodes.

Deploy commands in [`../../nas/README.md`](../../nas/README.md). Compose pins
UID/GID `3000:3000` + adds the `video` (44) and `render` (104) groups for
`/dev/dri` access.

## Setup (UI → `https://jellyfin.lab.raphlamenace.xyz/`)

### 1. First-launch wizard

- Display language: pick your UI lang
- **Admin user**: create (this is also what you sign in with from Jellyseerr)
- **Add media library**:
  - Content type: `Movies`
  - Folder: `/data/movies`
  - Metadata language: `English` (or `French` if you prefer French metadata; both work)
  - Country: `France`
- **Setup remote access**: leave at defaults (LAN-only; cluster Gateway handles the rest)
- Finish.

### 2. Hardware acceleration

Get there: avatar (top-right) → **Administration Dashboard** → **Playback**
(left sidebar) → **Transcoding** tab. Direct URL:
`https://jellyfin.lab.<YOUR_DOMAIN>/web/#/dashboard/playback/transcoding`.

> If you don't see "Administration Dashboard" in the avatar menu, your user
> isn't admin — fix via Dashboard → Users → your user → tick "Allow this user
> to manage the server". (The wizard usually grants admin to the first user.)

- **Hardware acceleration**: `Intel QuickSync (QSV)`
- **QSV Device**: leave blank (auto-detects `/dev/dri/renderD128`)
- **Enable hardware decoding for**: tick **only the codecs your iGPU supports.**
  Check generation in [Intel QSV Wikipedia](https://en.wikipedia.org/wiki/Intel_Quick_Sync_Video#Hardware_decoding_and_encoding) first.
  Concrete example for this homelab's NAS (i3-3220, HD 2500, QSV gen 2): tick
  H264 + MPEG-2 only; leave HEVC, VP9, AV1 unticked — gen 2 can't decode them.
- **Enable hardware encoding**: ✓ (only useful if your iGPU can encode the
  target codec. Gen 2 → H264 only.)
- **Allow encoding in HEVC format**: leave OFF unless your iGPU is gen 6+
  (Skylake / 2015 onward).
- **Enable Tone mapping**: leave OFF unless your iGPU is gen 9+ (Kaby Lake /
  2017 onward) — older iGPUs lack the 10-bit pipeline; ticking just makes
  HDR→SDR transcodes fail.
- Save.

> **Software fallback.** Anything ffmpeg can't accelerate runs on the CPU.
> A modest CPU (e.g. i3-3220, 2 cores / 4 threads) handles 1080p H264 software
> transcodes fine; 4K HEVC software-transcoding will struggle and may stutter.
> Direct play (client supports the codec natively) always works, no transcode
> involved.

### 3. Verify hardware access

The container user (UID 3000) needs to be in the render group to open
`/dev/dri/renderD128`. On TrueNAS SCALE, render's GID is **107**.

```bash
# Container's effective groups — must include the render GID (107 on TrueNAS).
ssh truenas_admin@192.168.1.25 'sudo docker exec jellyfin id'
# Expected: groups=3000,44,107  (44=video, 107=render). Missing 107 → fix
# compose group_add then redeploy.
```

Then force a transcode in the UI: play a 1080p movie → gear icon → set
Quality to `720p / 2 Mbps`. Check Jellyfin logs for HW init:

```bash
ssh truenas_admin@192.168.1.25 \
  'sudo docker logs jellyfin 2>&1 | grep -iE "qsv|vaapi|hwaccel|d3d11va" | tail -10'
```

`Initialized QSV decoder` or similar = HW decode active. CPU stays low during
playback (a software 1080p H264 → 720p transcode on the NAS's CPU would peak
~80%; with HW it sits under 15%).

### 4. Optional polish

- **Dashboard → Plugins → Catalog** → install `Trakt` (sync watch state) if you use it.
- **Dashboard → Users → <admin> → Password** → set if you skipped during wizard.
- **Dashboard → Server → Branding** → custom login disclaimer if you'll share with family.
