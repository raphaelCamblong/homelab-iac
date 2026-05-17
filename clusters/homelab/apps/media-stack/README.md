# media-stack — manifests

Kubernetes manifests for Prowlarr / Radarr / Bazarr / Jellyseerr / Recyclarr.
Heavy-IO components (Jellyfin, qBittorrent+Gluetun) run on the NAS — see
`../../../../nas/`.

**User-facing setup docs live in [`docs/media-stack/`](../../../../docs/media-stack/):**

- [SETUP.md](../../../../docs/media-stack/SETUP.md) — orchestrator (API-key Secret + per-app order + smoke test)
- [SPEC.md](../../../../docs/media-stack/SPEC.md) — storage layout + hardlink contract + NAS-vs-cluster split
- Per-app walkthroughs: `prowlarr.md`, `radarr.md`, `jellyseerr.md`, `bazarr.md`, `recyclarr.md`
- NAS apps (compose configs in `../../../../nas/`): `jellyfin.md`, `qbittorrent.md`
