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
onto it (failure log).

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
transitions (CRITICAL, CLEAR, CRITICAL, CLEAR), recorded below.

## Alert thresholds

`health.d/ram.conf` and `health.d/disks.conf` are byte-identical across all 3
nodes and mount **over** Netdata's stock files of the same name — same
directory, same override-by-filename as `netdata.conf`, not a merge, so each
must stay a full copy with only the threshold lines changed. They tighten
`ram_in_use` and `disk_space_usage` warn/crit from stock 90%/98% to 80%/90%: a
2GB node fills fast. Inode usage and the other stock disk/ram alarms are
untouched. No `deploy.yml` change was needed — `rsync -az --delete
stacks/vps0N/` already ships subdirectories and the existing `docker compose up
-d` + `restart netdata` steps pick up new mounts.

**These alarms do deliver.** Positive control: a throwaway alarm with the same
`to: sysadmin` recipient on vps02 fired `UNINITIALIZED -> WARNING` carrying
`EXEC_RUN`, exit 0. `ram_in_use`, `disk_space_usage` and `disk_inode_usage` have
never executed a notification, so they sit in the "no prior `EXEC_RUN`" branch
and will fire on their first real transition. The backup alarm's silence was
its own dedup state (failure log), not the recipient.

## ezBookkeeping backups (vps01)

Nightly at **03:00 Asia/Manila** to R2 bucket `homelab-backups`. Cron fires the
script hourly in the node's own zone (`0 * * * *`) and the script exits at once
unless it is 03:00 in Manila, because Debian's cron ignores `CRON_TZ` (failure
log). `FORCE_BACKUP=1` bypasses the gate. Six moving parts in `stacks/vps01/`:

| File | Role |
|---|---|
| `backup-ezbookkeeping.sh` | stop container, tar both volumes, start container, upload, stamp |
| `backup_age.plugin` | Netdata external plugin charting hours since last success |
| `health.d/backup.conf` | alarm: warn >36h, crit >72h (chart only, see failure log) |
| `check-backup-age.sh` | hourly staleness check alerting Telegram directly; optional `[APP_LABEL] [BACKUP_DIR]`, defaults to ezBookkeeping |
| `.r2.env` (never committed) | written by `deploy.yml` from `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` |
| `.telegram.env` (never committed) | written by `deploy.yml` from `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` |

The container is **stopped** for the tar so SQLite checkpoints its WAL and
closes cleanly: a few seconds of downtime buys a provably consistent database
file. An `EXIT` trap restarts it, so a failed tar or upload never leaves the app
down. Volumes are read through a throwaway `alpine` container rather than
`/var/lib/docker/volumes`, because the deploy user has Docker access but no sudo
(rail 6). Volume names carry the Dokploy project prefix
(`vps01booking-ezbookkeeping-rqdyxo_{data,storage}`) and change if the Dokploy
app is recreated, so `VOLUME_PREFIX` in the script is the first thing to check
when backups start failing after Dokploy work.

**The staleness alert does not go through Netdata.** `check-backup-age.sh` runs
hourly (`30 * * * *`), reads the same `.last-success` stamp and calls the
Telegram API itself: alert on crossing 36h, re-alert every 12h while stale, one
message on recovery, state in `backup/.stale-alerted`. Netdata's alarm keeps the
chart but is no longer the delivery path (failure log).

### R2 retention and locks (one bucket, both apps)

Retention lives in **R2 lifecycle rules**, not the scripts: `daily/` expires at
7 days, `weekly/` (Sundays) at 28. Deletion is server-side, so a script bug
cannot erase history.

**Bucket lock rules** cover what lifecycle does not: a *deliberate* delete. The
token in `.r2.env` is Object Read & Write, and write includes delete, so anyone
who takes vps01 could wipe every backup off-site. Added 2026-08-20 with
`wrangler r2 bucket lock add`:

| Rule | Prefix | Retention |
|---|---|---|
| `lock-daily-3d` | `daily/` | 3 days |
| `lock-weekly-14d` | `weekly/` | 14 days |

Inside those windows an object cannot be deleted or overwritten **by anyone** —
node, token, or account. The staleness alert fires at 36h, well inside both, so
a wipe is caught while the data still exists.

Lock retention is deliberately *shorter* than the matching lifecycle window: a
lock at or above the lifecycle period blocks lifecycle's own deletion and the
bucket grows without limit; one day short and lifecycle cleans up as before.
**Never set a lock retention >= its prefix's expiry.**

R2 has no object versioning, so lock rules are the whole mechanism — don't hunt
for a versioning setting. A lock also cannot be shortened or lifted for objects
already under it; removing a rule only stops it applying to new uploads. Worst
case for reversing this is 14 days of undeletable `weekly/` objects, which at
this bucket's size (66 kB, 8 objects, measured 2026-08-20) costs nothing.

### Drills and restore (ezBookkeeping)

**Alarm drill last passed: 2026-08-19.**
`/opt/stacks/vps01/backup/.last-success` backdated to 100h,
`check-backup-age.sh` run, Netdata given time to transition, recovered, then
driven stale a second time — testing whether the chain goes silent after a
CRITICAL. Both paths passed all three stages. `check-backup-age.sh`, the real
delivery path, sent 4/4 Telegram messages with a clean `.stale-alerted`
lifecycle. Netdata executed four consecutive transitions, no suppression:
`10:01:03Z CLEAR -> CRITICAL val=100 flags=PROCESSED,EXEC_RUN,EXEC_IN_PROGRESS,SAVED exec_code=0 delay=0`;
`10:11:03Z CRITICAL -> CLEAR val=0 delay=300` held exactly 300s then executed,
the first executed CLEAR since 2026-08-18;
`10:21:03Z CLEAR -> CRITICAL val=100 flags=PROCESSED,EXEC_RUN,SAVED exec_code=0`
undeduped; then a fourth transition, another executed CLEAR. Before the drill,
the last transition that executed was `08-18 07:31:50Z UNINITIALIZED ->
CRITICAL flags=…,EXEC_RUN,EXEC_FAILED exec_code=1`; everything after it up to
`08-19 00:13:53Z` carried no `EXEC_RUN`, and all three CLEARs in that window
showed `delay=3600, flags=UPDATED` — the wedged chain.

**Not proven: that `down 5m` fixed the wedge.** The alarm was already unwedged
when the drill started (its first CRITICAL executed with no executed CLEAR ahead
of it) — the `04:46:03Z` restart and config-hash change in the failure log below
are at least as plausible a cause. Confirmed: the alarm now delivers CRITICAL
and CLEAR reliably, and `down 5m` demonstrably lets a CLEAR land where a re-fire
would otherwise supersede it (under `down 1h` the 10:11 CLEAR would have been
due 11:11, after the 10:17 re-stale).

**Restore drill last passed: 2026-08-18.** Archive pulled from R2, extracted
into throwaway volumes, booted as a second container on `127.0.0.1:18080`:
SQLite `integrity_check` ok, row counts identical to production, app served 200.
Not proven: a receipt image rendering — production and restored `storage`
volumes are both still empty (0 accounts, 0 transactions, 0 pictures at drill
time). Re-run once there is real data.

**Restore:** pull the archive, `tar xzf`, copy `data/` and `storage/` back into
the two volumes with the same throwaway-container trick. Restoring without
`EBK_SECURITY_SECRET_KEY` (Dokploy env tab, also in Ex's password manager) gets
the books back but invalidates every session.

## booking MySQL backups (vps01)

Nightly at **04:00 Asia/Manila**, scheduled and live (crontab verified on the
node 2026-08-20: `backup-booking.sh` at `10 * * * *` self-gating to 04:00,
`check-backup-age.sh booking /opt/stacks/vps01/backup-booking` at `40 * * * *`).
Staggered an hour off ezBookkeeping so two backups never run at once on a 2GB
node; same bucket, same hourly-cron + in-script hour gate, same `FORCE_BACKUP=1`
escape hatch. Two files in `stacks/vps01/`: `backup-booking.sh` and the shared
`check-backup-age.sh`. (Archived: the pre-merge "not scheduled yet" wording.)

Its own work dir `/opt/stacks/vps01/backup-booking/` with its own
`.last-success` / `.stale-alerted` — the two backups must go stale
independently. `deploy.yml` excludes that dir from `rsync --delete`, same as
`backup/`.

Unlike ezBookkeeping, **nothing is stopped**: a hot `mysqldump
--single-transaction --routines --triggers --databases easyappointments` inside
`booking-ptpwn8-mysql-1` is a consistent InnoDB snapshot with no downtime on a
live booking site.

**Password handling, corrected 2026-08-20.** `MYSQL_ROOT_PASSWORD` is expanded
*inside* the container and passed via `MYSQL_PWD`, never `-p`. The old
`-p"$MYSQL_ROOT_PASSWORD"` form was documented here as never reaching "a host
process argument" — **false**: a container's PID namespace is a child of the
host's, so `ps -ef` on vps01 lists container argv in full and any local user
could read the password for the length of the dump. `MYSQL_PWD` moves it to the
process environment (`/proc/<pid>/environ`, root and same-uid only): better, not
gone — MySQL's own docs call `MYSQL_PWD` insecure. Single-quoting keeps the host
script's own argv and env clean either way. (Original wording archived.)

`set -o pipefail` is not POSIX, so `mysqldump | gzip` reports gzip's exit status
and a half-written dump would look like success. The script proves the dump
instead, in **two branches so the log names the cause that fired**: first
`gzip -cd | tail -5 | grep 'Dump completed'` for the trailer, then a floor of 10
`^CREATE TABLE` lines. On either failure it deletes the archive and exits
non-zero **without** stamping, so the staleness alert fires rather than a bad
dump reaching R2.

The table floor exists because the trailer alone is not enough: an
empty-but-existing database dumps as a complete, valid, trailer-carrying file
with zero tables — exactly what a Dokploy app rename produces (the volume name
derives from the app, so `MYSQL_DATABASE` recreates `easyappointments` empty and
MySQL starts happily; see the `dokploy/booking/docker-compose.yml` header).
Uncaught, it uploads green while R2 lifecycle ages out the last real copy. 14
tables measured 2026-08-19, floor 10 so schema churn doesn't cry wolf. Known
ceiling: it catches a *table-less* database, not an *empty* one — reinstall
EasyAppointments before 04:00 and 14 empty tables pass. Closing that needs a row
floor; not worth the code today.

Archive `booking-mysql-<STAMP>.sql.gz` under `daily/` (`weekly/` Sundays);
retention and lock rules are the shared ones above.

The dataset is tiny and the archive size is not a mistake: `easyappointments` is
14 tables, ~126 rows, 0.4 MB (`information_schema.tables`, 2026-08-19), and the
full dump is 31,064 bytes uncompressed with all 14 `CREATE TABLE` and 9 `INSERT`
statements. The volume's 203M on disk is MySQL 8.0's own ibdata1, redo/undo
tablespaces and binlogs. Small, but real customer booking data, and until this
backup the only production dataset with no off-site copy.

**Smoke test passed 2026-08-19:** a `FORCE_BACKUP=1` run went end to end — dump,
trailer check, upload, stamp — and the object is in R2 as
`daily/booking-mysql-2026-08-19T05-40-19.sql.gz`, 6083 bytes.

**Restore drill last passed: 2026-08-19.** That object was pulled *back down
from R2* (not the local copy in `backup-booking/`, so the off-site copy is what
was tested), 6083 bytes, `Dump completed` trailer intact, restored into a
throwaway `mysql:8.0` container on a throwaway volume, `--network none`, no
published ports, `--memory 512m`. Compared against production with read-only
metadata queries only: 14/14 tables in both, per-table row counts identical
across all 14 (128 rows total), 140 columns / 26
`information_schema.statistics` rows / 25 constraints / 0 routines / 0 triggers
/ 0 views on both sides. Production never written to, no row contents read
either side. Torn down completely — container and volume removed, temp archive
deleted, absence verified in `docker ps -a` and `docker volume ls`,
`backup-booking/` byte-identical. Not proven: that the restored database
*serves*; the drill compared schema and counts, it never pointed
EasyAppointments at the restored copy, and it deliberately did not read row
contents, because that is customer data.

**Restore:**

```sh
gzip -cd booking-mysql-*.sql.gz | docker exec -i booking-ptpwn8-mysql-1 sh -c \
  'MYSQL_PWD=$MYSQL_ROOT_PASSWORD; export MYSQL_PWD; exec mysql -uroot'
```

`MYSQL_PWD`, not `-p`, for the same host-`ps` reason as the dump side. The dump
is `--databases`, so it recreates `easyappointments` itself. Drill it into a
throwaway container first, never straight into production.

## Failure log

- A restore drill runs a *second* database on a node already running the first:
  the capped 512m `mysql:8.0` drill container on 2026-08-19 took vps01 from 4M
  to 61M of swap while production stayed up. Always cap a drill container
  explicitly, and never drill during the 03:00/04:00 backup window; on a 2GB
  node the drill is itself a workload, not an inspection.

- macOS `zcat` is not Debian's: it appends `.Z` and fails on a `.gz`, so a
  dump-integrity check written as `zcat` verified fine on the node and rejected
  a *good* archive when dry-run on a laptop. Use `gzip -cd`; same meaning on
  both.

- Netdata notifications were dead on **all three nodes** from setup until
  2026-08-18 and nothing surfaced it: `deploy.yml` wrote
  `health_alarm_notify.conf` with `umask 077`, giving `600 deploy:deploy` (uid
  1000), unreadable by the container's netdata user (uid 201). Every alarm since
  failed to deliver, including the tightened 80/90 RAM and disk alarms, and the
  config looked present and correct on the host — which is why it went unnoticed
  so long. Fixed by writing the file into the netdataconfig volume as uid 201
  (Alert delivery above). When a container reads a secret file, check the
  *in-container* uid and test as that user, not root.

- `alarm-notify.sh` enables **email by default**, so with Telegram configured
  and no MTA every alert also ran sendmail and logged `account default not
  found` (error 78) — three errors per transition and a non-zero exit. Telegram
  still delivered, so nothing was lost, but that steady error stream hid the
  broken config above. `SEND_EMAIL="NO"` in the templates. The templates' claim
  that every unlisted method "stays at its built-in default (disabled)" was
  simply wrong about email; check a notifier's default before writing that.

- `ezbookkeeping_backup_age` executed no notification from 2026-08-18 07:31:50Z
  until the 2026-08-19 drill. **Root cause:** netdata's
  `health_alarm_execute()` suppresses a notification when the most recent entry
  for the same `alarm_id` carrying `EXEC_RUN` has the **same status** as the new
  transition ("don't send the same notification twice"). That alarm last
  executed 07:31:50Z as CRITICAL, so every CRITICAL after was dropped as a
  duplicate. The escape hatch is a CLEAR that executes and resets the chain, and
  the then-current `delay: down 1h multiplier 1.5 max 4h` in
  `health.d/backup.conf` blocked exactly that: every CLEAR held an hour, the
  alarm re-fired first, the CLEAR was superseded (`UPDATED`) before its delay
  expired (`delay: 3600` on every CLEAR in the records). The two interlock; a
  long `down` delay is fine for a dashboard, useless for notification. **Not**
  recipient-specific: a throwaway `to: sysadmin` alarm on vps02 fired with
  `EXEC_RUN` and `exec_code=0`, and replaying netdata's real-mode arguments by
  hand delivers as both `netdata` and `root` — script, config and token were
  never at fault. Lesson: **an alarm can look armed on the dashboard while being
  permanently silent for one status.** Verify with a real transition, never an
  interactive `alarm-notify.sh test`, and never make a Netdata alarm the only
  delivery path for something that matters. (Two earlier wrong write-ups and a
  superseded clause about restart persistence are archived; the correction is
  the next entry.)

- Netdata's dedup state resets when an alarm's `config_hash_id` changes, not
  merely on restart (measured 2026-08-19: `046da83b…` → `4686c70f…` at the
  04:46:03Z restart, no transition recorded, wedge gone by the 10:01:03Z drill).
  So when an alarm is stuck silent, edit its `.conf` and redeploy; do not just
  restart netdata. Re-run the stale/recover/stale drill after any change to
  `health.d/backup.conf`, to prove CRITICAL → CLEAR → CRITICAL all execute.

- `sed -i` does **not** propagate into a bind-mounted single file: it writes a
  new inode and the container keeps reading the old one. Use `cat new > file`
  for in-place edits of mounted configs (`netdata.conf`, `health.d/*.conf`).

- rclone's S3 backend calls `CreateBucket` before uploading, to create the
  bucket if missing. An R2 token scoped to Object Read & Write cannot, so every
  upload died with `403 AccessDenied: CreateBucket` while the credentials were
  fine. Fix is `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`, not a wider token. Read
  the API call named in a 403 before assuming the key is wrong.

- vps01's system clock is **UTC-4**, not UTC (backup log stamped `-04:00` while
  rclone logged UTC). A cron entry written as plain UTC fires four hours off, so
  do not assume these nodes are UTC: schedule hourly and gate on
  `TZ=<zone> date +%H` inside the script. (Superseded `CRON_TZ` advice archived;
  next entry says why.)

- Debian 12's cron **ignores `CRON_TZ`** (verified on vps01 2026-08-18: a
  `CRON_TZ=Asia/Manila` entry set to fire 3 minutes out in Manila time never
  ran). The backup was therefore running 03:00 *node-local*, not Manila, and
  `deploy.yml`'s comment claimed otherwise. Fixed by running the scripts hourly
  and gating on `TZ=Asia/Manila date +%H` inside them. Never trust a
  timezone-aware cron entry here without testing it with a near-term throwaway.

- `deploy.yml`'s "Install backup cron" step pipes into `crontab -`, which
  **replaces the deploy user's entire crontab**, it does not append. All four
  vps01 entries (`backup-ezbookkeeping.sh` `:00`, `check-backup-age.sh` `:30`,
  `backup-booking.sh` `:10`, `check-backup-age.sh booking …` `:40`) therefore
  live in one heredoc in that step. Add any new scheduled job to that heredoc;
  installing one by hand or in a second step silently deletes the rest.

- `deploy.yml`'s `rsync -az --delete stacks/vps01/` **deleted
  `/opt/stacks/vps01/backup/`** on every deploy: the run log, the local archive,
  and the `.last-success` stamp the Netdata age alarm reads. The alarm did its
  job and sat CRIT ~13.7h unnoticed. Fixed with `--exclude 'backup/'`, now
  alongside `--exclude 'backup-booking/'`, `--exclude '.r2.env'`,
  `--exclude '.telegram.env'`. Any node-side state under a directory an rsync
  `--delete` targets needs an exclude, added in the same commit as the state.

- Dokploy v0.29.14 has **no 2FA and no login/audit log** (absent or
  license-gated). Verified empirically, not from docs: 30 days of `docker
  service logs dokploy` is 38 lines with zero auth events. Don't plan a security
  control around either existing. Authentication and the access log live in
  Cloudflare Access instead (Zero Trust → Logs → Access), the better placement
  anyway: it records attempts that never reach the origin.

- vps00 and vps01 once shared one `CLOUDFLARE_TUNNEL_TOKEN`. Cloudflare
  load-balanced `dokploy.maybeit.work` across both connectors; vps01 had nothing
  on that origin port, so ~2/3 of requests 502'd. Fixed by giving vps01 its own
  tunnel + token (rail 2). Never reuse another node's token when adding a
  service here.
