Parent: ../.claude/CLAUDE.md

# stacks/: per-node compose files

One `docker-compose.yml` per node, deployed by `deploy.yml` to
`/opt/stacks/<node>/`. Each runs that node's `cloudflared` connector
(rail 2, rail 3) plus any node-specific workload not deployed through
Dokploy directly.

## Tunnel mode

`cloudflared` runs in **token mode** (`tunnel run` + `TUNNEL_TOKEN` env).
Ingress/public-hostname routing is owned by the Cloudflare Zero Trust
dashboard (Networks → Tunnels → *tunnel* → Public Hostnames), not a local
config file in this repo. Add or change routes there.

Current routes:
- `dokploy.maybeit.work` → `http://localhost:3000` on vps00, token
  `CLOUDFLARE_TUNNEL_TOKEN`. **Behind a Cloudflare Access application**
  (`dokploy`, 24h session) since 2026-08-16. Policies mirror the
  `*-metrics` apps exactly: `status-worker service auth` (service token,
  so the status Worker can still poll it) then `owner email allow`. An
  unauthenticated request must `302` to `old-firefly-996b.cloudflareaccess.com`;
  a `200` means the policy detached and the control plane is open again.
- `booking.maybeit.work` → `http://localhost:80` on vps01 (Dokploy's own
  Traefik, forwards to the app container per the Domain set in Dokploy's
  UI), token `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`: its own dedicated
  tunnel, not shared with vps00's.
- vps02's Netdata → `http://localhost:19999`, token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`: its own dedicated tunnel,
  vps02's first workload *from this repo*, not shared with vps00's or
  vps01's.

Note vps02 is not the empty node it reads as: Dokploy has installed
`dokploy-traefik` there too, publishing 80/443. Nothing in `stacks/`
declares it; it comes from Dokploy's Remote Server setup, same as on
vps00 and vps01. `docker ps` on a node is the truth, not this
directory.

## Netdata

Runs on all 3 nodes as a `netdata` service, `network_mode: host`,
bound to `127.0.0.1:19999` (see each node's `netdata.conf`, `[web] bind
to = 127.0.0.1`, not exposed beyond the host; reaching it publicly goes
through that node's `cloudflared` route above). Config is split two ways:
`netdata.conf` (committed, no secrets, identical across nodes) and
`health_alarm_notify.conf` (generated at deploy time by a separate step,
never committed. `docker compose config` doesn't need it to exist,
`docker compose up` does).

## No docker.sock in Netdata

Netdata does **not** get `/var/run/docker.sock`. A `:ro` bind on a socket
restricts nothing: anything that can talk to the Docker API can run
`docker run -v /:/host`, i.e. host root. Mounting it turned any Netdata
RCE into instant root on all three nodes at once.

What that costs: Netdata's cgroup collector used the socket only to
resolve container *names*, so per-container charts are labelled by
cgroup ID instead of a friendly name. The per-container CPU/memory/IO
data itself comes from `/sys/fs/cgroup`, mounted separately and
unaffected, and none of the node-level metrics the status page consumes
(`system.cpu`, `system.ram`, `disk_space./`, `system.load`, `mem.swap`)
ever touched the socket.

`/:/host/root:ro,rslave` **stays**: the disk collectors genuinely need
it, it is read-only, and it grants no write anywhere. Don't remove it in
the same spirit; it isn't the same thing.

## Why network_mode: host (rail 3)

Bridge mode puts `cloudflared` in its own network namespace, so
`http://localhost:PORT` in a Public Hostname route resolves to the
container, not the VPS itself: the origin app is unreachable, 502.
`network_mode: host` makes `localhost` mean the node.

## Netdata Cloud claim

All three agents connect to Netdata Cloud (free Community plan: max 5 nodes,
1 custom dashboard per Room). Claiming is declarative: `NETDATA_CLAIM_TOKEN`
and `NETDATA_CLAIM_ROOMS` come from GitHub secrets into each node's `.env`,
and the compose file passes them to the agent, which claims itself on start.

The **same token goes on every node**, unlike a tunnel token (rail 2): this
one identifies the Space, not the node. Do not mint one per node.

Identity lives in the `netdatalib` volume (`/var/lib/netdata/cloud.d`), so a
claimed agent stays claimed across restarts and redeploys even if the secret
is later unset. Removing a node is a Cloud-side action, not a repo change.

Claiming is outbound HTTPS to `app.netdata.cloud` only. It opens no inbound
port and does not touch rail 1.

Cloud is additive: the per-node dashboards behind each tunnel and the local
health alarms keep working exactly as before. Do not move the backup
staleness alert onto it, for the reason in the failure log.

## Alert delivery

`health_alarm_notify.conf` carries the Telegram bot token, so it is
generated at deploy time and never committed. It is **not** bind-mounted
from the stack directory: `deploy.yml` pipes it into the node's
`<node>_netdataconfig` volume through a throwaway `alpine` container that
also does `chown 201:201` and `chmod 600`.

That indirection exists because the in-container Netdata runs as uid 201
while the deploy user is uid 1000. A bind-mounted `600 deploy:deploy` file
is unreadable to uid 201, and Netdata's failure mode is silent: it logs
"Failed to load config file", forgets Telegram entirely, and falls back to
emailing root on a box with no sendmail.

Verify delivery as the netdata user, never as root (root can read the file
regardless, so a root test passes on a broken setup):

```sh
docker exec -u netdata netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test sysadmin
```

That test proves the script, the config and the token. It does **not** prove
Netdata will ever run them: it passes on a setup where real alerts are
silently dropped (see failure log). A green test is not evidence that alarms
deliver; only a real transition reaching Telegram is.

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

**The staleness alert does not go through Netdata.** `check-backup-age.sh`
runs hourly, reads the same `.last-success` stamp and calls the Telegram API
itself: alert on crossing 36h, re-alert every 12h while stale, one message on
recovery, state in `backup/.stale-alerted`. Netdata's alarm stays for the
chart but is no longer the delivery path (see failure log).

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

Nightly at **04:00 Asia/Manila** (staggered an hour off ezBookkeeping so two
backups never run at once on a 2GB node), same R2 bucket, same hourly-cron
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
container (`docker exec ... sh -c 'exec mysqldump -p"$MYSQL_ROOT_PASSWORD"'`),
so it never appears in a host process argument or a log line.

`set -o pipefail` is not POSIX, so `mysqldump | gzip` reports gzip's exit
status and a half-written dump would look like a success. The script proves
the dump instead: `gzip -cd | tail -5 | grep 'Dump completed'`, and on failure it
deletes the archive and exits non-zero **without** stamping, so the staleness
alert fires rather than a truncated dump reaching R2.

Archive name `booking-mysql-<STAMP>.sql.gz` under `daily/` (`weekly/` on
Sundays); retention is the same server-side R2 lifecycle rules, 7 and 28 days.

**Smoke test passed 2026-08-19**: a `FORCE_BACKUP=1` run went end to end,
dump, trailer check, upload, stamp, and the object is present in R2 as
`daily/booking-mysql-2026-08-19T05-40-19.sql.gz`, 6083 bytes. **No restore
drill has been run yet**, so the archive is proven to arrive, not proven to
restore.

The dataset is tiny and the archive size is not a mistake: `easyappointments`
is 14 tables, ~126 rows, 0.4 MB (`information_schema.tables`, 2026-08-19),
and the full dump is 31,064 bytes uncompressed with all 14 `CREATE TABLE` and
9 `INSERT` statements. The volume's 203M on disk is MySQL 8.0's own ibdata1,
redo/undo tablespaces and binlogs. Small, but real customer booking data, and
until this backup it was the only production dataset with no off-site copy.

**Restore:** pull the archive, then
`gzip -cd booking-mysql-*.sql.gz | docker exec -i booking-ptpwn8-mysql-1 sh -c
'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'`. The dump is `--databases`, so
it recreates `easyappointments` itself. Drill it into a throwaway container
first, never straight into production.

## Failure log

- macOS `zcat` is not Debian's: it appends `.Z` and fails on a `.gz`, so a
  dump-integrity check written as `zcat` verified fine on the node and
  rejected a *good* archive when dry-run on a laptop. Use `gzip -cd` in these
  scripts; it means the same thing on both.

- Netdata notifications were dead on **all three nodes** from setup until
  2026-08-18 and nothing surfaced it: `deploy.yml` wrote
  `health_alarm_notify.conf` with `umask 077`, giving `600 deploy:deploy`
  (uid 1000), and the container's netdata user (uid 201) could not read it.
  Every alarm since then failed to deliver, including the tightened 80/90
  RAM and disk alarms. The config looked present and correct on the host,
  which is exactly why it went unnoticed for so long. Fixed by writing the
  file into the netdataconfig volume as uid 201 (see alert delivery above).
  When a container reads a secret file, check the *in-container* uid, and
  test as that user rather than root.

- `alarm-notify.sh` enables **email by default**, so with Telegram configured
  and no MTA installed every alert also ran sendmail and logged
  `account default not found` (error 78) — three errors per alarm
  transition, and `alarm-notify.sh` exiting non-zero. Telegram still
  delivered, so nothing was lost, but that steady error stream is what hid
  the genuinely broken config above. `SEND_EMAIL="NO"` in the templates.
  The templates' claim that every unlisted method "stays at its built-in
  default (disabled)" was simply wrong about email; check a notifier's
  default before writing that sentence.

- `ezbookkeeping_backup_age` has executed no notification since 2026-08-18
  07:31:50Z. Written up wrongly twice before the cause was found: first as
  "never executed, while stock alarms always did", then as a node-wide
  stoppage. **Root cause (2026-08-19):** netdata's `health_alarm_execute()`
  suppresses a notification when the most recent entry for the same
  `alarm_id` that carried `EXEC_RUN` has the **same status** as the new
  transition — its "don't send the same notification twice" rule. That alarm
  last executed at 07:31:50Z with status CRITICAL, so every CRITICAL since
  is dropped as a duplicate. The state persists across netdata restarts,
  which is why restarting never helped. The escape hatch would be a CLEAR
  that executes and resets the chain, and `delay: down 1h multiplier 1.5 max
  4h` in `health.d/backup.conf` blocks exactly that: every CLEAR is held an
  hour, the alarm re-fires first, and the CLEAR is superseded (`UPDATED`)
  before its delay expires. The two mechanisms interlock. **Not**
  recipient-specific, contrary to the first two write-ups: a throwaway
  `to: sysadmin` alarm on vps02 fired and carried `EXEC_RUN` with
  `exec_code=0`. Script, config and token were never at fault — replaying
  netdata's real-mode arguments by hand delivers, as `netdata` and as
  `root`. The lesson: **an alarm can look armed on the dashboard while being
  permanently silent for one status.** Verify with a real transition, never
  an interactive `alarm-notify.sh test`, and never make a Netdata alarm the
  only delivery path for something that matters.

- `sed -i` does **not** propagate into a bind-mounted single file: it writes
  a new inode and the container keeps reading the old one. Use
  `cat new > file` for in-place edits of mounted configs (`netdata.conf`,
  `health.d/*.conf`) on these nodes.

- `delay: down 1h multiplier 1.5 max 4h` in `health.d/backup.conf` holds
  every CLEAR for an hour and cancels it outright if the alarm re-fires
  first, so a flapping alarm never sends a recovery (`delay: 3600` on every
  CLEAR in the transition records). Fine for a dashboard, useless as
  notification.

- rclone's S3 backend calls `CreateBucket` before uploading, to create the
  bucket if it is missing. An R2 token scoped to Object Read & Write cannot
  do that, so every upload died with `403 AccessDenied: CreateBucket` while
  the credentials were in fact fine. Fix is
  `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`, not a wider token. Read the API
  call named in a 403 before assuming the key is wrong.

- vps01's system clock is **UTC-4**, not UTC (seen in the backup log's
  `-04:00` stamps while rclone logged UTC). Any cron entry written as plain
  UTC would fire four hours off, so do not assume these nodes are UTC.
  This entry used to end "the backup crontab pins `CRON_TZ` for this reason;
  do the same for anything else scheduled here" — **superseded**: Debian's
  cron ignores `CRON_TZ` entirely (see the entry below). Schedule hourly and
  gate on `TZ=<zone> date +%H` inside the script instead.

- `deploy.yml`'s "Install backup cron" step pipes into `crontab -`, which
  **replaces the deploy user's entire crontab**, it does not append. That is
  fine while the backup is its only entry; the moment a second scheduled job
  exists on vps01, this step will silently delete it. Add the second entry to
  the same step rather than installing it by hand.

- Dokploy v0.29.14 has **no 2FA and no login/audit log** (absent or
  license-gated). Verified empirically, not just from docs: 30 days of
  `docker service logs dokploy` is 38 lines with zero auth events. Don't
  plan a security control around either existing. Authentication and the
  access log both live in Cloudflare Access instead (Zero Trust → Logs →
  Access), which is the better placement anyway: it records attempts
  that never reach the origin.

- vps00 and vps01 once shared one `CLOUDFLARE_TUNNEL_TOKEN`. Cloudflare
  load-balanced `dokploy.maybeit.work` across both connectors; vps01 had
  nothing on that origin port, so ~2/3 of requests 502'd. Fixed by giving
  vps01 its own tunnel + token (rail 2). Never reuse another node's token
  when adding a service here.

- Debian 12's cron **ignores `CRON_TZ`** (verified empirically on vps01,
  2026-08-18: a `CRON_TZ=Asia/Manila` entry scheduled to fire 3 minutes out
  in Manila time never ran). The backup was therefore scheduled for 03:00
  *node-local*, not Manila, and `deploy.yml`'s comment claimed otherwise.
  Fixed by running the script hourly and gating on `TZ=Asia/Manila date +%H`
  inside the script. Never trust a timezone-aware cron entry here without
  testing it with a near-term throwaway entry.

- `deploy.yml`'s `rsync -az --delete stacks/vps01/` **deleted
  `/opt/stacks/vps01/backup/`** on every deploy: the run log, the local
  archive, and the `.last-success` stamp the Netdata age alarm reads. The
  alarm did its job and sat CRIT for ~13.7h unnoticed. Fixed with
  `--exclude 'backup/'`. Any node-side state living under a directory an
  rsync `--delete` targets needs an exclude, added in the same commit as the
  state.
