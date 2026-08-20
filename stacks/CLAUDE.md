Parent: ../.claude/CLAUDE.md

# stacks/: per-node compose files

One `docker-compose.yml` per node, deployed by `deploy.yml` to
`/opt/stacks/<node>/`. Each runs that node's `cloudflared` connector (rails 2,
3) plus any node-specific workload not deployed through Dokploy directly.

Superseded passages are archived in full in
`docs/superpowers/failure-log-archive.md` (2026-08-20); pointers below say
which.

## Tunnel mode and routes

`cloudflared` runs in **token mode** (`tunnel run` + `TUNNEL_TOKEN` env).
Public-hostname routing is owned by the Cloudflare Zero Trust dashboard
(Networks → Tunnels → *tunnel* → Public Hostnames), not by any file here. Add
or change routes there.

- `dokploy.maybeit.work` → `http://localhost:3000` on vps00, token
  `CLOUDFLARE_TUNNEL_TOKEN`. **Behind a Cloudflare Access application**
  (`dokploy`, 24h session) since 2026-08-16, policies mirroring the `*-metrics`
  apps exactly: `status-worker service auth` (service token, so the status
  Worker can still poll it) then `owner email allow`. Unauthenticated must
  `302` to `old-firefly-996b.cloudflareaccess.com`; a `200` means the policy
  detached and the control plane is open again.
- `booking.maybeit.work` → `http://localhost:80` on vps01 (Dokploy's own
  Traefik, forwarding to whichever container the Domain in Dokploy's UI points
  at), token `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`: its own dedicated tunnel.
- vps02's Netdata → `http://localhost:19999`, token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`: its own dedicated tunnel, and
  vps02's first workload *from this repo*.

**One token per node (rail 2):** Cloudflare load-balances a hostname across
*every* connector on its tunnel — a route is not pinned to a node — so one
token shared between nodes with different origins sends some requests to a node
with nothing on that origin port.

**`network_mode: host` (rail 3):** bridge mode gives `cloudflared` its own
netns, so `http://localhost:PORT` in a route resolves to the container, not the
VPS: origin unreachable, 502.

vps02 is not the empty node it reads as: Dokploy installed `dokploy-traefik`
there too, publishing 80/443, same as vps00 and vps01. Nothing in `stacks/`
declares it. `docker ps` on a node is the truth, not this directory.

## Netdata

All 3 nodes, `network_mode: host`, bound to `127.0.0.1:19999` (`[web] bind to`
in `netdata.conf`); public access only via that node's `cloudflared` route.
Config splits two ways: `netdata.conf` (committed, no secrets; identical on
vps00/vps02, vps01 adds `[plugins] backup_age = yes`) and
`health_alarm_notify.conf` (generated at deploy time, never committed —
`docker compose config` doesn't need it to exist, `docker compose up` does).

**No docker.sock.** A `:ro` bind on a socket restricts nothing: anything that
can reach the Docker API can `docker run -v /:/host`, i.e. host root. Mounting
it turned any Netdata RCE into instant root on all three nodes at once. Cost is
cosmetic: the cgroup collector used the socket only to resolve container
*names*, so per-container charts are labelled by cgroup ID; their CPU/memory/IO
data comes from `/sys/fs/cgroup`, mounted separately, and none of the node-level
metrics the status page consumes (`system.cpu`, `system.ram`, `disk_space./`,
`system.load`, `mem.swap`) ever touched the socket. `/:/host/root:ro,rslave`
**stays**: the disk collectors need it, it is read-only, it grants no write. Not
the same thing; don't remove it "in the same spirit".

**Netdata Cloud claim.** All three agents connect (free Community plan: 5 nodes
max, 1 custom dashboard per Room). Declarative: `NETDATA_CLAIM_TOKEN` and
`NETDATA_CLAIM_ROOMS` go from GitHub secrets into each node's `.env`, compose
passes them to the agent, the agent claims itself on start. The **same token
goes on every node** — unlike a tunnel token (rail 2) it identifies the Space,
not the node; do not mint one per node. Identity lives in the `netdatalib`
volume (`/var/lib/netdata/cloud.d`), so an agent stays claimed across restarts
and redeploys even if the secret is unset later; removing a node is a Cloud-side
action, not a repo change. Claiming is outbound HTTPS to `app.netdata.cloud`
only: no inbound port, rail 1 untouched. Cloud is additive — per-node dashboards
and local alarms are unaffected — but do not move the backup staleness alert
onto it (`vps01/CLAUDE.md` failure log).

## Alert delivery

`health_alarm_notify.conf` carries the Telegram bot token, so it is generated
at deploy time and never committed, and it is **not** bind-mounted: `deploy.yml`
pipes it into the node's `<node>_netdataconfig` volume through a throwaway
`alpine` container that also does `chown 201:201` and `chmod 600`. That
indirection exists because in-container Netdata is uid 201 while the deploy user
is uid 1000; a bind-mounted `600 deploy:deploy` file is unreadable to uid 201,
and Netdata fails silently — logs "Failed to load config file", forgets Telegram
entirely, falls back to emailing root on a box with no sendmail.

Verify as the netdata user, never root (root reads the file regardless, so a
root test passes on a broken setup):

```sh
docker exec -u netdata netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test sysadmin
```

That proves script, config and token — **not** that Netdata will ever run them:
it passes on a setup where real alerts are silently dropped (failure log). Only
a real transition reaching Telegram is evidence. That evidence exists for
`ezbookkeeping_backup_age`: the 2026-08-19 drill drove four consecutive executed
transitions (CRITICAL, CLEAR, CRITICAL, CLEAR), recorded in `vps01/CLAUDE.md`.

## Alert thresholds

`health.d/ram.conf` and `health.d/disks.conf` (identical across all 3
nodes, mounted over Netdata's stock files of the same name (same
directory, same override-by-filename as `netdata.conf`, not a merge), so
each is a full copy with only the threshold lines changed) tighten
`ram_in_use` and `disk_space_usage` warn/crit from Netdata's stock
90%/98% to 80%/90%, per the design spec: a 2GB node fills fast. Inode
usage and the other stock disk/ram alarms are untouched. No deploy.yml
change needed: `rsync -az --delete stacks/vps0N/` already ships
subdirectories, and the existing `docker compose restart netdata` step
picks up the new mounts.

**These alarms do deliver.** The `to: sysadmin` path is proven by positive
control: a throwaway alarm with that same recipient on vps02 fired
`UNINITIALIZED -> WARNING`, carried the `EXEC_RUN` flag and exited 0.
`ram_in_use`, `disk_space_usage` and `disk_inode_usage` have never executed
a notification, so they sit in the "no prior `EXEC_RUN`" branch and will
fire on their first real transition. The backup alarm's silence was specific
to its own dedup state (see failure log), not a property of the recipient.

## Why one token per node (rail 2)

Cloudflare load-balances a hostname's requests across *every* connector
registered to its tunnel: a route isn't pinned to a specific node.
Sharing one token across nodes with different origins means Cloudflare
sends some requests to a node with nothing listening on that origin port.

## ezBookkeeping backups (vps01)

Nightly at **03:00 Asia/Manila** to Cloudflare R2 bucket `homelab-backups`.
Cron fires the script **hourly** in the node's own zone; the script exits
immediately unless it is 03:00 in Manila, because Debian's cron ignores
`CRON_TZ` (see failure log). `FORCE_BACKUP=1` bypasses that gate for a
manual run. Six moving parts, all in `stacks/vps01/`:

| File | Role |
|---|---|
| `backup-ezbookkeeping.sh` | stop container, tar both volumes, start container, upload, stamp |
| `backup_age.plugin` | Netdata external plugin charting hours since last success |
| `health.d/backup.conf` | alarm: warn >36h, crit >72h (chart only, see failure log) |
| `check-backup-age.sh` | hourly staleness check that alerts Telegram directly; takes optional `[APP_LABEL] [BACKUP_DIR]`, defaults to ezBookkeeping |
| `.r2.env` (never committed) | written by `deploy.yml` from `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` |
| `.telegram.env` (never committed) | written by `deploy.yml` from `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` |

The container is **stopped** for the tar so SQLite checkpoints its WAL and
closes cleanly: a few seconds of downtime buys a provably consistent
database file. The script starts it again from an `EXIT` trap, so a failed
tar or upload never leaves the app down.

Volumes are read through a throwaway `alpine` container rather than from
`/var/lib/docker/volumes`, because the deploy user has Docker access but no
sudo (rail 6). Volume names carry the Dokploy project prefix
(`vps01booking-ezbookkeeping-rqdyxo_{data,storage}`); they change if the
Dokploy app is recreated, so `VOLUME_PREFIX` in the script is the first
thing to check when a backup starts failing after Dokploy work.

Retention lives in **R2 lifecycle rules**, not in the script: `daily/`
expires at 7 days, `weekly/` (Sundays) at 28. Deletion is server-side so a
script bug cannot erase history.

**R2 bucket lock rules** cover what lifecycle does not: a *deliberate* delete.
The token in `.r2.env` on vps01 is Object Read & Write, and write includes
delete, so anyone who takes that node could wipe every backup off-site. Added
2026-08-20 with `wrangler r2 bucket lock add`:

| Rule | Prefix | Retention |
|---|---|---|
| `lock-daily-3d` | `daily/` | 3 days |
| `lock-weekly-14d` | `weekly/` | 14 days |

Within those windows an object cannot be deleted or overwritten **by anyone**,
including the node, the token, and the account. The staleness alert fires at
36h, comfortably inside both, so a wipe is detected while the data still
exists.

Retention is deliberately *shorter* than the matching lifecycle window. A lock
at or above the lifecycle period blocks lifecycle's own deletion and the bucket
grows without limit; one day short of it, the lock lapses and lifecycle cleans
up as before. Never set a lock retention >= its prefix's expiry.

R2 has no object versioning, so lock rules are the whole mechanism -- do not go
looking for a versioning setting to enable. And a lock cannot be shortened or
lifted for objects already under it: removing a rule only stops it applying to
new uploads. Worst case for reversing this decision is 14 days of undeletable
`weekly/` objects, which at this bucket's size (66 kB, 8 objects, measured
2026-08-20) costs nothing.

**The staleness alert does not go through Netdata.** `check-backup-age.sh`
runs hourly, reads the same `.last-success` stamp and calls the Telegram API
itself: alert on crossing 36h, re-alert every 12h while stale, one message on
recovery, state in `backup/.stale-alerted`. Netdata's alarm stays for the
chart but is no longer the delivery path (see failure log).

**Alarm drill last passed: 2026-08-19.** `/opt/stacks/vps01/backup/.last-success`
was backdated to 100h, `check-backup-age.sh` run, Netdata given time to
transition, then recovered, then driven stale a second time — to test whether
the notification chain still goes silent after a CRITICAL. Both paths passed all
three stages, first CRITICAL, CLEAR, second CRITICAL. `check-backup-age.sh`, the
real delivery path, sent 4/4 Telegram messages with a clean `.stale-alerted`
lifecycle, no caveats. Netdata executed four consecutive transitions with no
suppression: `10:01:03Z CLEAR -> CRITICAL val=100 flags=PROCESSED,EXEC_RUN,EXEC_IN_PROGRESS,SAVED exec_code=0 delay=0`,
then `10:11:03Z CRITICAL -> CLEAR val=0 delay=300` held exactly 300s and then
executed (the first executed CLEAR on this alarm since 2026-08-18), then
`10:21:03Z CLEAR -> CRITICAL val=100 flags=PROCESSED,EXEC_RUN,SAVED exec_code=0`
undeduped, then a fourth transition, another executed CLEAR. Before the drill the
last transition that executed was `08-18 07:31:50Z UNINITIALIZED -> CRITICAL
flags=…,EXEC_RUN,EXEC_FAILED exec_code=1`; everything after it up to
`08-19 00:13:53Z` carried no `EXEC_RUN`, and all three CLEARs in that window
showed `delay=3600, flags=UPDATED` — the wedged chain.

**Not proven: that `down 5m` is what fixed the wedge.** The alarm was already
unwedged when the drill started — the drill's first CRITICAL executed with no
executed CLEAR ahead of it. Between `08-19 00:13:53Z` and the drill, netdata
restarted at `04:46:03Z` and picked up the new `backup.conf`, and the alarm's
`config_hash_id` changed from `046da83b…` to `4686c70f…` with no transition
recorded at that timestamp. What is confirmed: the alarm currently delivers
CRITICAL and CLEAR reliably, and `down 5m` demonstrably lets a CLEAR land in a
window where a re-fire would otherwise have superseded it (under `down 1h` the
10:11 CLEAR would have been due at 11:11, after the 10:17 re-stale). The escape
from the original wedge is at least as attributable to the config-hash change as
to the delay value.

**Restore drill last passed: 2026-08-18.** Archive pulled from R2, extracted
into throwaway volumes, booted as a second container on `127.0.0.1:18080`:
SQLite `integrity_check` ok, row counts identical to production, app served
200. Not proven: a receipt image rendering, because both the production and
the restored `storage` volume are still empty (0 accounts, 0 transactions,
0 pictures at drill time). Re-run the drill once there is real data.

**Restore:** pull the archive, `tar xzf` it, and copy `data/` and `storage/`
back into the two volumes with the same throwaway-container trick. Restoring
the database without `EBK_SECURITY_SECRET_KEY` (Dokploy env tab, also in
Ex's password manager) gets you the books but invalidates every session.

## booking MySQL backups (vps01)

Nightly at **04:00 Asia/Manila**, scheduled on vps01 since 2026-08-20 (cron
verified on the node after the deploy, not inferred from the workflow).
Staggered an hour off ezBookkeeping so two
backups never run at once on a 2GB node, same R2 bucket, same hourly-cron
+ in-script hour gate, same `FORCE_BACKUP=1` escape hatch. Two files in
`stacks/vps01/`: `backup-booking.sh`, and the shared `check-backup-age.sh`
invoked as `check-backup-age.sh booking /opt/stacks/vps01/backup-booking`.

Its own work dir `/opt/stacks/vps01/backup-booking/` with its own
`.last-success` / `.stale-alerted`: the two backups must be able to be stale
independently. `deploy.yml` excludes that dir from the `rsync --delete` for
the same reason it excludes `backup/`.

Unlike ezBookkeeping, **nothing is stopped**: a hot `mysqldump
--single-transaction --routines --triggers` inside
`booking-ptpwn8-mysql-1` gives a consistent InnoDB snapshot with no downtime
on a live booking site. `MYSQL_ROOT_PASSWORD` is expanded *inside* the
container, and passed via `MYSQL_PWD`, not `-p`. Superseded 2026-08-20: the
old `-p"$MYSQL_ROOT_PASSWORD"` form was documented here as never reaching "a
host process argument", which was wrong. A container's PID namespace is a
child of the host's, so `ps -ef` on vps01 lists container argv in full and the
password was readable by any local user for the length of the dump. `MYSQL_PWD`
moves it to the process environment (`/proc/<pid>/environ`, root and same-uid
only) — better, not gone; MySQL's own docs still call `MYSQL_PWD` insecure.
The host script's argv and env stay clean either way, which is the part the
single-quoting buys.

`set -o pipefail` is not POSIX, so `mysqldump | gzip` reports gzip's exit
status and a half-written dump would look like a success. The script proves
the dump instead, in two branches so the log names the cause that fired:
`gzip -cd | tail -5 | grep 'Dump completed'` for the trailer, then a floor of
10 `^CREATE TABLE` lines. On either failure it deletes the archive and exits
non-zero **without** stamping, so the staleness alert fires rather than a bad
dump reaching R2.

The table floor exists because the trailer alone is not enough: an
empty-but-existing database dumps as a complete, valid, trailer-carrying file
with zero tables, and that is exactly what a Dokploy app rename produces (the
volume name derives from it, so `MYSQL_DATABASE` recreates `easyappointments`
empty and MySQL starts happily — see the `dokploy/booking/docker-compose.yml`
header). Uncaught, it uploads green while the R2 lifecycle rules age out the
last real copy. 14 tables measured 2026-08-19; the floor is 10 so schema churn
does not cry wolf. Known ceiling: it catches a *table-less* database, not an
*empty* one — reinstall EasyAppointments before 04:00 and 14 empty tables pass.
Closing that needs a row floor; not worth the code today.

Archive name `booking-mysql-<STAMP>.sql.gz` under `daily/` (`weekly/` on
Sundays); retention is the same server-side R2 lifecycle rules, 7 and 28 days,
under the same lock rules (3 and 14 days) described in the ezBookkeeping
section above -- one bucket, both apps.

**Smoke test passed 2026-08-19**: a `FORCE_BACKUP=1` run went end to end,
dump, trailer check, upload, stamp, and the object is present in R2 as
`daily/booking-mysql-2026-08-19T05-40-19.sql.gz`, 6083 bytes.

**Restore drill last passed: 2026-08-19.** `daily/booking-mysql-2026-08-19T05-40-19.sql.gz`
was pulled *back down from R2* (not the local copy in `backup-booking/`, so the
off-site object is what was tested), 6083 bytes with its `Dump completed`
trailer intact, and restored into a throwaway `mysql:8.0` container on a
throwaway volume, `--network none`, no published ports, `--memory 512m`.
Compared against production with read-only metadata queries only: 14 of 14
tables present in both, per-table row counts identical across all 14 (128 rows
total), and 140 columns / 26 `information_schema.statistics` rows / 25
constraints / 0 routines / 0 triggers / 0 views on both sides. Production was
never written to, and no row contents were read on either side. Torn down
completely: container removed, volume removed, temp archive deleted, verified
absent from `docker ps -a` and `docker volume ls`; `backup-booking/` left
byte-identical. Not proven: that the restored database actually *serves* — the
drill compared schema and counts, it did not point EasyAppointments at the
restored copy and load a booking page, and it did not verify row contents,
deliberately, because that is customer data.

The dataset is tiny and the archive size is not a mistake: `easyappointments`
is 14 tables, ~126 rows, 0.4 MB (`information_schema.tables`, 2026-08-19),
and the full dump is 31,064 bytes uncompressed with all 14 `CREATE TABLE` and
9 `INSERT` statements. The volume's 203M on disk is MySQL 8.0's own ibdata1,
redo/undo tablespaces and binlogs. Small, but real customer booking data, and
until this backup it was the only production dataset with no off-site copy.

**Restore:** pull the archive, then
`gzip -cd booking-mysql-*.sql.gz | docker exec -i booking-ptpwn8-mysql-1 sh -c
'MYSQL_PWD=$MYSQL_ROOT_PASSWORD; export MYSQL_PWD; exec mysql -uroot'` --
`MYSQL_PWD`, not `-p`, for the same host-`ps` reason as the dump side above. The dump is `--databases`, so
it recreates `easyappointments` itself. Drill it into a throwaway container
first, never straight into production.

## Failure log

Incident histories behind these rules: `failure-log` skill (`stacks/`).

- **When a container reads a secret file, check the *in-container* uid and
  test as that user, not root.** `deploy.yml` wrote
  `health_alarm_notify.conf` with `umask 077` — `600 deploy:deploy` (uid
  1000), unreadable by the container's netdata user (uid 201) — so every
  alarm on all three nodes failed to deliver from setup until 2026-08-18
  while the config looked present and correct on the host. Write it into
  the netdataconfig volume as uid 201 (Alert delivery above).
- **Set `SEND_EMAIL="NO"` in the notify templates.** `alarm-notify.sh`
  enables email **by default**, so with no MTA every alert also ran
  sendmail (`account default not found`, error 78) — a steady error stream
  that hid the broken config above. Check a notifier's real default before
  writing that an unlisted method is disabled.
- **Never `sed -i` a bind-mounted single file:** it writes a new inode and
  the container keeps reading the old one. Use `cat new > file` for
  `netdata.conf` and `health.d/*.conf`.
- **Dokploy v0.29.14 has no 2FA and no login/audit log** (verified
  empirically, not from docs). Don't plan a security control around
  either; authentication and the access log live in Cloudflare Access
  (Zero Trust → Logs → Access), which also records attempts that never
  reach the origin.
- **Never reuse another node's tunnel token** (rail 2). vps00 and vps01
  once shared one, so Cloudflare load-balanced `dokploy.maybeit.work`
  across both connectors and ~2/3 of requests 502'd on the node with
  nothing on that origin port.
