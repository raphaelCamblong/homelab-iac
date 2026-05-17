# gluetun + qBittorrent

VPN-tunneled torrent client. qBit shares Gluetun's netns; if the tunnel drops,
qBit loses network (kill switch).

Deploy + kill-switch test in [`../../nas/README.md`](../../nas/README.md).

## Setup (UI → `https://qbit.lab.raphlamenace.xyz/`)

### 1. First-launch password

```bash
ssh truenas_admin@192.168.1.25 \
  'sudo docker logs qbittorrent 2>&1 | grep -A1 "temporary password" | tail -2'
```

Log in with `admin` + that password. Then **set a real password** —
Tools → Options → Web UI → Authentication. You'll paste it into Radarr's
qBit download client later.

### 2. Save paths — Tools → Options → Downloads

- **Default Save Path**: `/data/downloads/complete/`
- **Keep incomplete torrents in**: `/data/downloads/incomplete/` ✓
- Apply.

> The split into `incomplete/` + `complete/` subdirs is the SPEC layout —
> `docs/media-stack/SPEC.md`. Don't drop torrents into the root
> `/data/downloads/` directly; Radarr's auto-import only scans the configured
> qBit Save Path (which is `complete/`).

### 3. Connection — Tools → Options → Connection

- Port: `6881`
- UPnP / NAT-PMP: ✗ (Mullvad doesn't support it)

### 4. Categories — no manual setup needed

The `radarr` and `radarr-imported` categories are **auto-created by Radarr** on
first push / first import respectively. Don't pre-create them in qBit (no
save-path override needed — they default to the global Default Save Path
above, which is what we want).

If you ever inspect qBit and see torrents stuck in `radarr` after import
(should move to `radarr-imported`), Radarr's qBit-client config is missing
the Post-Import Category — see [`./radarr.md`](./radarr.md) step 2.
