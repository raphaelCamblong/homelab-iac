# recyclarr/

CronJob that syncs TRaSH-Guides quality profiles + custom formats into Radarr.

## Secret consolidation

The Radarr API key Recyclarr reads lives in the shared `media-stack-api-keys`
Secret under the `radarr` key — same Secret the Prowlarr/Radarr Deployment env
vars use. See [`./SETUP.md`](./SETUP.md) for the bootstrap flow (SOPS in prod,
`kubectl create secret` on k3s-test). One Secret, no scatter.
