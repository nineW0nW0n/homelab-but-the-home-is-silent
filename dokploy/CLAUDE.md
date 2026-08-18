Parent: ../.claude/CLAUDE.md

# dokploy/: compose apps Dokploy pulls from this repo

One directory per workload. Dokploy is configured (Compose application,
Provider: GitHub, this repo, Compose Path
`dokploy/<workload>/docker-compose.yml`) to clone and deploy these
itself. `.github/workflows/deploy.yml` never touches this tree: it
rsyncs `stacks/` only. Two different deploy paths, one repo.

Split rule: node-level services (cloudflared, Netdata) live in
`stacks/<node>/docker-compose.yml`. User-facing apps that want Dokploy's
UI (logs, redeploy button, env editor, backups) live here.

## Local rails

- **No `ports:`.** Publishing a port on a node bypasses UFW (root rail
  1). Attach to the external `dokploy-network` and let Dokploy's Traefik
  reach the container port through Traefik labels.
- **Traefik `entrypoints: web` only.** TLS terminates at Cloudflare;
  `cloudflared` hits `http://localhost:80`. A `websecure` router on a
  node with no certificate just fails.
- **Secrets live in Dokploy's environment tab**, referenced as
  `${VAR:?...}` in the compose file. Commit a `.env.example` with
  redacted placeholders, never a `.env` (root rail 11).
- **`mem_limit`/`mem_reservation` on every service** (root rail 4). 2GB
  nodes, and Dokploy's own control plane already takes a bite.
- **Pin image tags exactly.** No `latest`, no `1.6`.

## Workloads

- `ezbookkeeping/` → vps01, `budget.maybeit.work`, SQLite, 256m cap.
  Two named volumes: `data` (SQLite file) and `storage` (transaction
  pictures). The app writes pictures to `/ezbookkeeping/storage`, so
  without that volume every receipt photo dies on the next redeploy.
  Registration disabled by default; flip `EBK_USER_ENABLE_REGISTER=true`
  in Dokploy's env tab only long enough to create the first account.
  Routed through vps01's existing tunnel
  (`CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`), which already points at
  `http://localhost:80`; the only Cloudflare-side step is adding the
  Public Hostname.

- `booking/` → vps01, `booking.maybeit.work`, EasyAppointments + MySQL.
  Migrated into this repo 2026-08-18 by switching the **existing** Dokploy
  app's provider from Raw to GitHub, not by creating a new app. That
  matters: the compose project name (`booking-ptpwn8`) is derived from the
  Dokploy app, and the MySQL volume `booking-ptpwn8_mysql-data` (~200MB of
  real appointments) is named after it. Renaming or recreating the app
  silently brings MySQL up on an empty database while the old volume sits
  orphaned on disk. `MYSQL_ROOT_PASSWORD` and `DB_PASSWORD` stay in
  Dokploy's environment tab.

## Failure log

- ezBookkeeping writes transaction pictures to `/ezbookkeeping/storage`,
  a path the first version of its compose file never mounted, so any
  receipt photo would have lived in the container layer and vanished on
  redeploy. When adding a container that accepts uploads, check where it
  writes them (`du -sh /<appdir>/*` in the running container) rather than
  assuming the database volume covers user data.
- Cloudflare caches ezBookkeeping's `/server_settings.js` (origin sends
  `cache-control: max-age=14400`), so after flipping an env-driven
  feature flag the login page can keep showing the old state for up to
  4 hours. Do not conclude the env change failed: check the container
  (`env | grep EBK_`) and `curl` the origin file, then purge by hostname
  in Caching -> Configuration -> Custom Purge. Verified 2026-08-18 while
  turning `EBK_USER_ENABLE_REGISTER` off: container read `false` and
  `_['r']=0` while the browser still offered "Create an account".
