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

**Autodeploy has now been broken twice, by two different layers in front of
the same URL.** First Access (`302`, fixed 2026-08-18 with the bypass app),
then the zone WAF rule `Block non-local traffic` (`403`, 2026-08-19 to
2026-08-20). That rule blocks every source outside PH for every host but the
apex — and **GitHub's webhook servers are not in PH** — so their POST to
`/api/deploy/<secret>` died at the WAF, which evaluates *before* Access. The
bypass app was intact the whole time and simply never reached. PR #44 merged
with `autoDeploy = t` and nothing deployed; the gap is visible as a
two-day hole in the `deployment` table.

Fixed 2026-08-20 with a custom rule **ordered above** the block:
`http.host eq "dokploy.maybeit.work" and starts_with(http.request.uri.path,
"/api/deploy")`, action Skip → all remaining custom rules. Order is the whole
trick; below the block rule it does nothing. Verified from vps01, which is
not in PH: `/` still `403`s (the dashboard stays geo-blocked) while
`/api/deploy/test` returns `404`, i.e. it reaches Dokploy.

That leaves `/api/deploy/*` guarded by the webhook URL's secret alone, from
anywhere — which is what this file already said the bypass app implies. The
tighter alternative, scoping to GitHub's published IP ranges, was rejected on
purpose: those ranges rotate, nothing here tracks them, and the failure mode
would be another silent `403`.

**A rate limit is the companion to that trade-off** (2026-08-20): the zone's
one free rule, 5 requests per 10s per IP+colo on this path, action Block,
10s mitigation. Legitimate traffic is one POST per push, so the ceiling costs
nothing and bounds brute-forcing the secret. It is the only rate-limit rule
the plan allows — spending it here rather than on the apex is deliberate:
everything else is geo-blocked to PH, and the apex is served entirely by the
Worker at Cloudflare's edge, so a flood there costs Worker requests, not node
resources. This path reaches the control plane on vps00.

**Do not test a rate limit with a concurrent burst.** 12 and then 20
simultaneous requests all returned `404` — Cloudflare's counter is eventually
consistent, so a simultaneous burst arrives before anything increments, and
that reads exactly like a rule that does not work. Sustained traffic is what
exercises it: 30 requests at ~2.5/s tripped at the 11th and held `429` for
the rest, recovering to `404` after the 10s window (verified 2026-08-20 from
vps01). The false negative is the trap, not the rule.

**Both failures presented as silence** — GitHub sees a non-2xx and nothing
here raises anything. So verify against Dokploy's own tables, never by
curling from a PH client, where everything looks fine either way:

```sh
# on vps00 -- last deployment of any app, and whether autoDeploy is even on
docker exec $(docker ps -qf name=dokploy-postgres) \
  psql -U dokploy -d dokploy -c 'SELECT title, status, "createdAt" FROM deployment ORDER BY "createdAt" DESC LIMIT 3;'
docker exec $(docker ps -qf name=dokploy-postgres) \
  psql -U dokploy -d dokploy -c 'SELECT name, "sourceType", "autoDeploy", branch FROM compose;'
```

A merge with no matching deployment row is the symptom; the fallback while
you diagnose is a manual redeploy from Dokploy's UI.

Note **Dokploy is not path-filtered**: it runs a deployment for *every* app on
any push to `main`, not only when `dokploy/` changed — a README-only merge
produces a row for both apps. Harmless, because `docker compose up -d` with an
unchanged compose is a no-op: after PR #46, `ezbookkeeping` was still `Up 13
hours` and `booking-ptpwn8-mysql-1` `Up 2 days`. Do not read a deployment row
as evidence a container was recreated, or its absence as proof nothing shipped.

When autodeploy silently stops, check the WAF rule first and Access second:
both fail as silence, and neither raises anything.

**Run these from a PH client — Ex's laptop, not a node and not CI.** The zone
carries a WAF rule `(ip.src.country ne "PH" and http.host ne "maybeit.work")`,
which fires *before* Access, so from vps01 all three lines return `403` and
match none of the documented outcomes (verified 2026-08-20). A uniform 403 is
the geo rule, not evidence about Access.

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
  tablespaces and binlogs. Measured figures live in `stacks/vps01/CLAUDE.md`; do not
  restate them here, they were wrong in four places once already.
  Small but real customer data; its off-site backup lives in
  `stacks/vps01/backup-booking.sh` (see `stacks/vps01/CLAUDE.md` for schedule,
  drills and the `MYSQL_PWD` handling).

### Closed 2026-08-20: the CalDAV SSRF check is back on

The `sed` below was removed. What settled it was measuring the thing nobody
had checked: **CalDAV is in active use** — one provider row has
`caldav_sync = 1` with a URL set, and all 8 rows in `ea_appointments` carry
an `id_caldav_calendar` — so this was never dead config to rip out. But the
sync target is **public HTTPS**, classified straight from
`ea_user_settings` without printing the URL (it has a password beside it).
The guard blocks *internal* targets; a public host passes it untouched. So
the guard was almost certainly never what broke anything — it reads like
setup-time troubleshooting that was never revisited.

Re-check after any redeploy that sync still runs. If it breaks, the guard
*was* load-bearing for a reason still unknown, and that reason goes here
rather than back into a `sed`. The history below is kept because the
argument for removing it is the useful part.

### Original entry: booking disabled EasyAppointments' CalDAV SSRF check

`booking/docker-compose.yml`'s `entrypoint` ran, on every boot, a `sed`
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
vps01 can route to, none of which is reachable from the internet. Not known
at the time: whether CalDAV sync was used at all, or whether the app was
failing without it — both answered by measuring, above. The rule that
survives: **do not delete a guard blind, and do not file it as accepted
risk either.** Measure what it actually protects and what actually depends
on it; here that was two SQL queries nobody had run.

## Failure log

Incident histories behind these rules: `failure-log` skill (`dokploy/`).

- **When adding a container that accepts uploads, check where it writes
  them** (`du -sh /<appdir>/*` in the running container) rather than
  assuming the database volume covers user data. ezBookkeeping writes to
  `/ezbookkeeping/storage`, unmounted at first, so any receipt photo would
  have lived in the container layer and vanished on redeploy.
- **Cloudflare caches ezBookkeeping's `/server_settings.js`** (origin
  sends `max-age=14400`), so after flipping an env-driven feature flag the
  login page can show the old state for up to 4 hours. Don't conclude the
  env change failed: check `env | grep EBK_` in the container, `curl` the
  origin file, then purge by hostname in Caching → Configuration → Custom
  Purge.
