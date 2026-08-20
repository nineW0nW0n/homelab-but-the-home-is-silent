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
its own dedup state (`vps01/CLAUDE.md` failure log), not the recipient.

## vps01: backups, R2, and their alerting

All of it — the two backup scripts, R2 lifecycle and lock rules, the restore
and alarm drills, `check-backup-age.sh` and its direct-to-Telegram path,
`backup_age.plugin`, the backup cron entries, the booking MySQL specifics, and
the failure-log entries for them — lives in **`vps01/CLAUDE.md`**. Nothing
here is true of vps00 or vps02.

**Dokploy project prefixes (all nodes).** Container and volume names created by
Dokploy carry the project prefix (`booking-ptpwn8-mysql-1`,
`vps01booking-ezbookkeeping-rqdyxo_data`) and change if the app is recreated or
renamed. Anything that names one by hand — a backup script's `VOLUME_PREFIX`,
`deploy.yml`'s health probes — breaks silently at that point. Check the live
name with `docker ps` / `docker volume ls` first.

## Failure log

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

- `sed -i` does **not** propagate into a bind-mounted single file: it writes a
  new inode and the container keeps reading the old one. Use `cat new > file`
  for in-place edits of mounted configs (`netdata.conf`, `health.d/*.conf`).

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
