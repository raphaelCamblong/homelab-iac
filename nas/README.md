# NAS compose apps (TrueNAS SCALE Custom Apps)

The media stack's heavy-IO components — **Jellyfin** (streaming + HW
transcoding) and **qBittorrent** (fsync writes + hardlinks) — run on the
NAS directly, never in k3s/Talos. The split is permanent per
`docs/media-stack/SPEC.md`.

Both apps live under `/mnt/mega-tank/apps/<app>/config` and bind-mount
`/mnt/mega-tank/media` at `/data` so the SPEC hardlink contract holds
(identical `/data/movies` + `/data/downloads/...` paths visible inside the
NAS containers AND inside Radarr/Bazarr pods on k3s).

## Prereqs (one-time, already done)

```bash
# Datasets
sudo zfs create -o compression=lz4 mega-tank/apps/jellyfin
sudo zfs create -o compression=lz4 mega-tank/apps/qbittorrent
sudo zfs create -o compression=lz4 mega-tank/apps/gluetun
sudo chown -R 3000:3000 /mnt/mega-tank/apps/{jellyfin,qbittorrent,gluetun}

# Media subtree (SPEC layout)
sudo install -d -o root -g family -m 0775 \
  /mnt/mega-tank/media/{movies,downloads/incomplete,downloads/complete}

# NFS share for k3s consumption
sudo midclt call sharing.nfs.create '{
  "path": "/mnt/mega-tank/media",
  "comment": "media-stack /data (movies+downloads) — SPEC hardlink contract",
  "networks": ["192.168.1.0/24"],
  "maproot_user": "root",
  "maproot_group": "wheel",
  "security": ["SYS"]
}'
sudo midclt call service.restart nfs
```

## Deploy gluetun + qBittorrent (run from workstation)

Requires Mullvad WireGuard credentials. Fetch from Mullvad account → WireGuard
configuration → Generate key → download `.conf` → copy the `PrivateKey` and
`Address` lines.

```bash
read -s -p "Mullvad WG private key: " WG_KEY; echo
read    -p "Mullvad WG addresses (e.g. 10.x.x.x/32): " WG_ADDR
read    -p "Mullvad cities (comma-separated, blank for defaults): " WG_CITIES
WG_CITIES=${WG_CITIES:-Amsterdam,Frankfurt,Zurich}

COMPOSE=$(MULLVAD_WG_PRIVATE_KEY="$WG_KEY" \
          MULLVAD_WG_ADDRESSES="$WG_ADDR" \
          MULLVAD_CITIES="$WG_CITIES" \
          envsubst < nas/gluetun-qbittorrent/compose.yaml)

ssh truenas_admin@192.168.1.25 "sudo midclt call app.create $(jq -nc \
  --arg name media-torrent --arg compose "$COMPOSE" \
  '{app_name:$name, custom_compose_config_string:$compose}' | jq -Rs .)"
```

**Verify kill switch BEFORE letting qBit touch a tracker:**

```bash
# Should return a Mullvad exit IP, NOT your home WAN IP.
ssh truenas_admin@192.168.1.25 'sudo docker exec qbittorrent curl -s --max-time 10 ifconfig.me'

# Stop Gluetun → qBit's connection MUST die.
ssh truenas_admin@192.168.1.25 'sudo docker stop gluetun'
ssh truenas_admin@192.168.1.25 'sudo docker exec qbittorrent curl -s --max-time 5 ifconfig.me; echo "(empty above = kill switch OK)"'
ssh truenas_admin@192.168.1.25 'sudo docker start gluetun'
```

qBit Web UI: `https://qbit.lab.raphlamenace.xyz/` (cluster Gateway, Hubble can
observe) or `http://192.168.1.25:8090/` (direct, LAN-only fallback).
First-launch password + save-path setup: see
[`../docs/media-stack/qbittorrent.md`](../docs/media-stack/qbittorrent.md).

## Deploy Jellyfin

```bash
COMPOSE=$(cat nas/jellyfin/compose.yaml)
ssh truenas_admin@192.168.1.25 "sudo midclt call app.create $(jq -nc \
  --arg name media-jellyfin --arg compose "$COMPOSE" \
  '{app_name:$name, custom_compose_config_string:$compose}' | jq -Rs .)"

# Health check
curl -sI http://192.168.1.25:8096/health
```

First-launch wizard + HW transcoding config: see
[`../docs/media-stack/jellyfin.md`](../docs/media-stack/jellyfin.md).

## Update / re-deploy

`app.create` is **not idempotent**. To change config:

```bash
COMPOSE=$(cat nas/jellyfin/compose.yaml)   # or the rendered gluetun one
ssh truenas_admin@192.168.1.25 "sudo midclt call app.update '$(jq -nc \
  --arg name media-jellyfin --arg compose "$COMPOSE" \
  '{name:$name, values:{custom_compose_config_string:$compose}}')'"
```

## Troubleshoot

- **qBit can't reach trackers but UI loads** → Gluetun's tunnel is down. Check `sudo docker logs gluetun --tail=50`. Restart with `sudo docker restart gluetun`. **Important**: after restarting Gluetun, you also have to `sudo docker restart qbittorrent` — qBit shares Gluetun's network namespace; if Gluetun's netns goes away while qBit is running, qBit ends up in a stale netns with no DNS and no IP. This is also why the kill-switch test sequence is `docker stop gluetun → verify qBit has no network → docker start gluetun → docker restart qbittorrent`.
- **Jellyfin transcode fails (no QSV)** → `sudo docker exec jellyfin ls /dev/dri` should list `card0` + `renderD128`. If empty, the `devices:` mapping didn't take — re-deploy.
- **`/data` looks empty inside qBit but populated on host** → bind mount didn't follow the share. Check the dataset hierarchy: `mega-tank/media` must NOT be split into sub-datasets (hardlinks break at dataset boundaries).
- **NFS mount fails on k3s** → `showmount -e 192.168.1.25` must list `/mnt/mega-tank/media` exported to `192.168.1.0/24`. If empty, re-run the `sharing.nfs.create` block in Prereqs.
