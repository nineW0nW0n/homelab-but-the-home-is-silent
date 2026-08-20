Parent: ../.claude/CLAUDE.md

# dokploy/: compose apps Dokploy pulls from this repo

One directory per workload. Dokploy is configured (Compose application,
Provider: GitHub, this repo, Compose Path `dokploy/<workload>/docker-compose.yml`)
to clone and deploy these itself; `.github/workflows/deploy.yml` never touches
this tree, it rsyncs `stacks/` only. Two deploy paths, one repo.

Split rule: node-level services (cloudflared, Netdata) live in
`stacks/<node>/docker-compose.yml`; user-facing apps that want Dokploy's UI
(logs, redeploy button, env editor, backups) live here.

## Local rails

- **No `ports:`.** Publishing a port on a node bypasses UFW (root rail 1).
  Attach to the external `dokploy-network` and let Dokploy's Traefik reach the
  container port through Traefik labels.
- **Traefik `entrypoints: web` only.** TLS terminates at Cloudflare and
  `cloudflared` hits `http://localhost:80`; a `websecure` router on a node
  with no certificate just fails.
- **Secrets live in Dokploy's environment tab**, referenced as `${VAR:?...}`
  in the compose file, with a redacted `.env.example` committed and never a
  `.env` (root rail 11).
- **`mem_limit`/`mem_reservation` on every service** (root rail 4) — 2GB
  nodes, and Dokploy's control plane already takes a bite.
- **Pin image tags exactly.** No `latest`, no `1.6`.
- Both deviations live in `booking/`: bare `${DB_PASSWORD}` /
  `${MYSQL_ROOT_PASSWORD}` with no `.env.example`, so a missing value yields
  an empty password rather than a loud failure; and `mysql:8.0`, a moving
  minor tag. The apps themselves are pinned (`easyappointments:1.6.0`,
  `ezbookkeeping:1.6.1`).

## Autodeploy and Cloudflare Access

Dokploy redeploys on push via a per-app webhook GitHub calls at
`https://dokploy.maybeit.work/api/deploy/<secret>`. That host sits behind
Cloudflare Access, which bounced the POST with a `302` to the Access login and
`auth_status: NONE`: GitHub never reached Dokploy, nothing surfaced it, and
autodeploy simply never fired. Fixed 2026-08-18 with a **second Access
application** scoped to `dokploy.maybeit.work/api/deploy`, holding one
Bypass/Everyone policy named `webhook-bypass`; a bypass policy inside the
existing `dokploy` application would have unprotected the whole dashboard, so
the narrow second app is load-bearing, not stylistic. It exists only in
Cloudflare, nothing here creates it, and it leaves `/api/deploy/*` guarded by
the webhook URL's secret alone — **treat those URLs (Dokploy app →
Deployments tab) as secrets.**

When autodeploy silently stops, check Access first: its failure mode is a
redirect, not an error.

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://dokploy.maybeit.work/            # 302, Access
curl -s -o /dev/null -w '%{http_code}\n' https://dokploy.maybeit.work/api/trpc/x  # 302, Access
curl -s -o /dev/null -w '%{http_code}\n' https://dokploy.maybeit.work/api/deploy/test  # 404, reaches Dokploy
```

A `302` on the third line means the bypass app is gone or reordered; a `200`
on the first means the dashboard itself is unprotected.

## Workloads

- `ezbookkeeping/` → vps01, `budget.maybeit.work`, SQLite, 256m cap. Two named
  volumes: `data` (SQLite file) and `storage` (transaction pictures, written
  to `/ezbookkeeping/storage` — without that volume every receipt photo dies
  on the next redeploy). Registration is off by default; flip
  `EBK_USER_ENABLE_REGISTER=true` in Dokploy's env tab only long enough to
  create the first account. Routed through vps01's existing tunnel
  (`CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING` → `http://localhost:80`), so the
  only Cloudflare-side step is adding the Public Hostname.

- `booking/` → vps01, `booking.maybeit.work`, EasyAppointments + MySQL.
  Migrated here 2026-08-18 by switching the **existing** Dokploy app's
  provider from Raw to GitHub, not by creating a new app. That matters: the
  compose project name (`booking-ptpwn8`) derives from the Dokploy app, and so
  does the MySQL volume `booking-ptpwn8_mysql-data`. Renaming or recreating
  the app brings MySQL up on an empty database, silently, while the old volume
  sits orphaned on disk. `MYSQL_ROOT_PASSWORD` and `DB_PASSWORD` stay in
  Dokploy's environment tab. The volume is 203M on disk but the dataset is a
  fraction of that -- the rest is MySQL 8.0's own ibdata1, redo/undo
  tablespaces and binlogs. Measured figures live in `stacks/CLAUDE.md`; do not
  restate them here, they were wrong in four places once already.
  Small but real customer data; its off-site backup lives in
  `stacks/vps01/backup-booking.sh` (see `stacks/CLAUDE.md` for schedule,
  drills and the `MYSQL_PWD` handling).

### Known gap: booking disables EasyAppointments' CalDAV SSRF check

`booking/docker-compose.yml`'s `entrypoint` runs, on every boot, a `sed`
rewriting `application/libraries/Caldav_sync.php` from
`enable_ssrf_check = true` to `false`: the app's own guard against CalDAV sync
URLs pointing at internal addresses, turned off. Nothing in this repo explains
why. It arrived with the migration commit ("feat(dokploy): bring the booking
app into the repo"), which copied the then-live Raw compose verbatim, and that
file had only ever been hand-edited in Dokploy's web editor — so the reason
predates the repo and was never written down.

Known: with the check off, anyone who can set a CalDAV URL in the booking
admin UI can make the container issue requests to addresses it should not
reach — sibling containers on `dokploy-network` and anything private that
vps01 can route to, none of which is reachable from the internet. Not known:
whether CalDAV sync is used at all, or whether the app was failing without
it. Do not delete the `sed` blind and do not file it as accepted risk — ask
Ex, then remove it or record the reason here.

## Failure log

- ezBookkeeping writes transaction pictures to `/ezbookkeeping/storage`, a
  path the first version of its compose file never mounted, so any receipt
  photo would have lived in the container layer and vanished on redeploy. When
  adding a container that accepts uploads, check where it writes them
  (`du -sh /<appdir>/*` in the running container) rather than assuming the
  database volume covers user data.
- Cloudflare caches ezBookkeeping's `/server_settings.js` (origin sends
  `cache-control: max-age=14400`), so after flipping an env-driven feature
  flag the login page can keep showing the old state for up to 4 hours. Do not
  conclude the env change failed: check the container (`env | grep EBK_`) and
  `curl` the origin file, then purge by hostname in Caching → Configuration →
  Custom Purge. Verified 2026-08-18 turning `EBK_USER_ENABLE_REGISTER` off:
  the container read `false` and `_['r']=0` while the browser still offered
  "Create an account".
