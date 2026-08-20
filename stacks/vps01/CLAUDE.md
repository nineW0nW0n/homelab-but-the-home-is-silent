Parent: ../CLAUDE.md

# stacks/vps01/: backups, R2, and the alerting that guards them

vps01 runs the only two production datasets with off-site copies:
ezBookkeeping (SQLite, 03:00) and booking/EasyAppointments (MySQL, 04:00).
Everything here is vps01-only; cross-node compose, tunnel and Netdata rails
live in `../CLAUDE.md`.

Superseded passages are archived in full in
`docs/superpowers/failure-log-archive.md` (2026-08-20); pointers below say
which.

## ezBookkeeping backups

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

`backup_age.plugin` is why vps01's `netdata.conf` alone carries
`[plugins] backup_age = yes`.

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
CRITICAL. Both paths passed all three stages, first CRITICAL, CLEAR, second
CRITICAL. `check-backup-age.sh`, the real delivery path, sent 4/4 Telegram
messages with a clean `.stale-alerted` lifecycle, no caveats. Netdata executed
four consecutive transitions, no suppression:
`10:01:03Z CLEAR -> CRITICAL val=100 flags=PROCESSED,EXEC_RUN,EXEC_IN_PROGRESS,SAVED exec_code=0 delay=0`;
`10:11:03Z CRITICAL -> CLEAR val=0 delay=300` held exactly 300s then executed,
the first executed CLEAR on this alarm since 2026-08-18;
`10:21:03Z CLEAR -> CRITICAL val=100 flags=PROCESSED,EXEC_RUN,SAVED exec_code=0`
undeduped; then a fourth transition, another executed CLEAR. Before the drill,
the last transition that executed was `08-18 07:31:50Z UNINITIALIZED ->
CRITICAL flags=…,EXEC_RUN,EXEC_FAILED exec_code=1`; everything after it up to
`08-19 00:13:53Z` carried no `EXEC_RUN`, and all three CLEARs in that window
showed `delay=3600, flags=UPDATED` — the wedged chain. This is the evidence
that *this* alarm really executes a notification (`../CLAUDE.md`, alert
delivery).

**Not proven: that `down 5m` fixed the wedge.** The alarm was already unwedged
when the drill started (its first CRITICAL executed with no executed CLEAR ahead
of it) — the `04:46:03Z` netdata restart picked up the new `backup.conf`, and
the config-hash change in the failure log below followed. The escape from the
original wedge is at least as attributable to the config-hash change as to the
delay value. Confirmed: the alarm now delivers CRITICAL and CLEAR reliably, and
`down 5m` demonstrably lets a CLEAR land where a re-fire would otherwise
supersede it (under `down 1h` the 10:11 CLEAR would have been due 11:11, after
the 10:17 re-stale).

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

## booking MySQL backups

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
14 tables, **128 rows** (`COUNT(*)` across all 14, 2026-08-20), 0.4 MB, and the
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
across all 14 (128 rows total, re-confirmed by `COUNT(*)` 2026-08-20 — this
figure was right and the "~126" it used to sit beside was not), 140 columns / 26
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

Incident histories behind these rules: `failure-log` skill
(`stacks/vps01/`).

- **Cap a drill container explicitly, and never drill during the
  03:00/04:00 backup window** — on a 2GB node a second database is a
  workload, not an inspection; the last drill pushed vps01 into swap.
- **Use `gzip -cd`, never `zcat`, in dump-integrity checks** — macOS
  `zcat` appends `.Z` and rejects a *good* `.gz` when dry-run on a laptop.
- **A Netdata alarm can look armed and be permanently silent for one
  status** — a notification whose status matches the last executed one is
  dropped as a duplicate, and a long `delay: down` blocks the CLEAR that
  would reset the chain. Verify with a real transition, never an
  interactive `alarm-notify.sh test`, and never make an alarm the only
  delivery path for something that matters. (Two earlier wrong write-ups
  and a superseded restart-persistence clause are archived.)
- **To unstick a silent alarm, edit its `.conf` and redeploy** — dedup
  state resets on a `config_hash_id` change, not on a netdata restart.
  Re-run the stale/recover/stale drill after any change to
  `health.d/backup.conf`.
- **Read the API call named in a 403 before assuming the key is wrong** —
  rclone's S3 backend calls `CreateBucket` first, which an Object Read &
  Write R2 token cannot. Fix is `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`,
  not a wider token.
- **These nodes are not UTC, and Debian 12's cron ignores `CRON_TZ`** —
  so schedule hourly and gate on `TZ=Asia/Manila date +%H` inside the
  script. Never trust a timezone-aware cron entry here without testing it
  with a near-term throwaway. (Superseded `CRON_TZ` advice archived.)
- **Every vps01 cron entry lives in one heredoc** in `deploy.yml`'s
  "Install backup cron" step, which pipes into `crontab -` and so
  *replaces* the crontab. Adding a job anywhere else deletes the rest.
- **Node-side state under an rsync `--delete` target needs an
  `--exclude`, added in the same commit as the state** — `backup/` (run
  log, local archive, `.last-success` stamp) was deleted on every deploy
  and the age alarm sat CRIT unnoticed for half a day.
