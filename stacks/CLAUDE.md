Parent: ../.claude/CLAUDE.md

# stacks/: per-node compose files

One `docker-compose.yml` per node, deployed by `deploy.yml` to
`/opt/stacks/<node>/`. Each runs that node's `cloudflared` connector (rails 2,
3) plus every workload on that node. No reverse proxy: each app publishes
one loopback port on the `8NXX` scheme (`N` = node, `01-49` apps, `50-99`
tools; Netdata moved `19999`→`8N50` and OpenObserve `5080`→`8251` on
2026-08-24) and `cloudflared` dials it directly.

## Tunnel mode and routes

`cloudflared` runs in **token mode** (`tunnel run` + `TUNNEL_TOKEN` env).
Public-hostname routing is owned by the Cloudflare Zero Trust dashboard
(Networks → Tunnels → *tunnel* → Public Hostnames), not by any file here. Add
or change routes there. Every tunnel reports `source: "cloudflare"`, so the
live ingress map is remote state with no version history and no diff against
this list — read it back (`cfd_tunnel/{id}/configurations`, `tooling-setup`)
rather than trusting the routes below, and treat any mismatch as the
dashboard having drifted from the docs, not the reverse.

Nine routes. Eight are live -- seven read back from the API 2026-08-23
after the Dokploy removal (`dokploy.maybeit.work`, its Access apps, its
CNAME and its WAF bypass were deleted that day), plus `wiki`. The ninth,
`gws.maybeit.work`, was created 2026-08-29 and read back from the API the
same day. Across three tunnels:

- `vps00-metrics.maybeit.work` → `http://localhost:8050` on vps00, token
  `CLOUDFLARE_TUNNEL_TOKEN`. Behind its own Access app.
- `wiki.maybeit.work` → `http://localhost:8001` on vps00, same tunnel
  (created via API 2026-08-26): wiki-kit, see `stacks/vps00/CLAUDE.md`.
  Access application `wiki`, one policy, `owner email allow`.
  Deployed as a test 2026-08-26, **kept 2026-08-27**.
- `gws.maybeit.work` → `http://localhost:8051` on vps00, same tunnel:
  google-workspace-mcp, see `stacks/vps00/CLAUDE.md`. Access application
  `gws-mcp`, two policies — `owner email allow` (the browser leg of
  Google's consent redirect) and `claude-code service auth`, which reuses
  the **same** `claude-code` service token as `wiki`, not a new one. Both
  policies are needed: drop the email policy and the OAuth callback 403s,
  drop the service-token policy and Claude Code cannot connect.
- `booking.maybeit.work` → `http://localhost:8101` on vps01
  (EasyAppointments, its own published loopback port), token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`: its own dedicated tunnel.
  **No Access app, by decision (2026-08-27).** It is the one public-facing
  workload here: clients book appointments without an account, so an
  Access login in front of it would break the thing it exists to do. What
  guards it is the zone geo rule (PH only), EasyAppointments' own login
  for the admin side, and **the zone's single rate-limit rule**, which
  was retargeted here 2026-08-27 from the deleted
  `dokploy.maybeit.work`: `http.host eq "booking.maybeit.work" and
  http.request.method ne "GET"`, block, 20 requests / 10s per
  `ip.src`+`cf.colo.id`, 10s timeout (read back from the API, version 2).
  Non-GET only on purpose — every page load pulls dozens of GET assets
  from this same host, so a host-wide limit would block real visitors;
  form posts and the booking AJAX are what an attacker floods. The
  threshold is deliberately generous: blocking a real client mid-booking
  costs more here than slowing a brute-forcer, and the free plan allows
  exactly one rule, so this is the only slot. Do not "fix" the missing
  Access app — every other hostname having one is not an oversight, it is
  the difference between an ops surface and a public one.
- `budget.maybeit.work` → `http://localhost:8102` on vps01, same tunnel:
  ezBookkeeping, the SQLite dataset `vps01/CLAUDE.md` backs up. Behind its
  own Access application (`budget`, 24h session) since 2026-08-20, **two**
  policies: `owner email allow` and `partner email allow` (read back from
  the API 2026-08-23). Until then the zone geo rule was the only
  thing in front of it, so it was open to anyone in PH. No service-token
  policy — nothing automated polls it. **Access breaks non-browser
  ezBookkeeping clients**, which cannot complete the login flow; if a
  mobile or desktop client needs to sync, that is the trade-off to revisit.
- `vps01-metrics.maybeit.work` → `http://localhost:8150` on vps01, same
  tunnel, behind Access.
- `vps02-metrics.maybeit.work` → `http://localhost:8250` on vps02, token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`: its own dedicated tunnel, behind
  Access, and vps02's first workload *from this repo*.
- `siem.maybeit.work` → `http://localhost:8251` on vps02, same tunnel:
  the OpenObserve UI. Access application `siem`, one policy,
  `owner email allow`, PH-only like `budget`.
  OpenObserve's own login sits behind that.
- `siem-ingest.maybeit.work` → the same origin on vps02, same tunnel:
  the ingest endpoint vps00/vps01's Vector posts to. Access application
  `siem-ingest`, one policy: service auth for the `siem-ingest` token.
  **Exempt from the zone geo rule** (`and http.host ne
  "siem-ingest.maybeit.work"`) because the nodes are US-hosted and would
  403 otherwise; only the country check is lifted, so it is still 403
  without the token, and OpenObserve's basic auth is a second lock
  behind it.

Every tunnel's catch-all is `http_status:404`.

**Ex's partner gets her own policy on the apps she uses, never a shared
login.** One `partner email allow` policy per app, added alongside
`owner email allow`, so access is granted and revoked per app and the
Access log names who did what. Today that is `budget` alone — the
household's books are hers too. Adding her to another app is one more
policy on that app, not a wider policy on this one, and not a second
account sharing the owner's address. Ops surfaces (`siem`, the three
`*-metrics` apps) stay owner-only: nothing there is hers to use, and
a policy that exists is a policy that can be widened by accident.

**Two service tokens, never crossed.** `status-worker` opens the three
`*-metrics` apps and nothing else; `siem-ingest` opens `siem-ingest` and
nothing else. Adding either token's policy to the other's app hands one
credential a scope it was minted to not have — the mistake the status
Worker's token once made against the Dokploy control plane (detached
2026-08-20, app deleted 2026-08-23).

**One token per node (rail 2):** Cloudflare load-balances a hostname across
*every* connector on its tunnel — a route is not pinned to a node — so one
token shared between nodes with different origins sends some requests to a node
with nothing on that origin port. Half of this is checkable without touching a
node: each tunnel's connector list must show exactly **one** distinct
`client_id` (verified 2026-08-20 — three tunnels, one connector each, 4 edge
connections, `cloudflared 2024.12.2`), and a shared token surfaces as two
connectors on one tunnel. It proves nothing about the token *files* on disk, and
only holds while both nodes are running, so it supplements the per-node check,
never replaces it. Never fetch `/cfd_tunnel/{id}/token` to compare tokens — that
returns secret material (rail 11).

**`network_mode: host` (rail 3):** bridge mode gives `cloudflared` its own
netns, so `http://localhost:PORT` in a route resolves to the container, not the
VPS: origin unreachable, 502.

`docker ps` on a node is the truth, not this directory. Until 2026-08-23
every node ran a `dokploy-traefik` nothing in `stacks/` declared; since
then every container on every node comes from its compose file, and a
container that does not is drift to investigate.

## Listener baseline (recorded 2026-08-24, extended 2026-09-02)

`ss -lntH` on each node, post port-scheme migration. Anything beyond this
set is drift to investigate; the scheduled off-node sweep
(`.github/workflows/port-sweep.yml`, daily) enforces the public half of
rail 1, but only `ss` on the node sees loopback listeners and UDP.

- all three: `0.0.0.0:22` + `[::]:22` (sshd), `127.0.0.1:20241`
  (cloudflared's built-in metrics endpoint -- it has no off switch, and
  loopback-only is the accepted state; the design spec's "disable it"
  item closes as not-doable, 2026-08-24), and TCP 45876 (beszel-agent,
  added 2026-09-02) -- **bind address not yet measured**: `ss -ltnp` on
  all three (2026-09-02) showed nothing on 45876, because the service is
  not deployed yet. Read it back after the first deploy: whether it binds
  `0.0.0.0` only or `[::]` as well is what decides whether the IPv4-only
  ufw rule below is sufficient.
- vps00: `127.0.0.1:8050` (Netdata), `:8001` (wiki-kit Caddy, since
  2026-08-26), `:8051` (google-workspace-mcp, since 2026-08-29)
- vps01: `127.0.0.1:8101` (booking), `:8102` (budget), `:8150` (Netdata)
- vps02: `127.0.0.1:8250` (Netdata), `:8251` (OpenObserve)

## Netdata

All 3 nodes, `network_mode: host`, bound to `127.0.0.1:8N50` per node --
8050/8150/8250, `[web] default port` + `bind to` in `netdata.conf`; public
access only via that node's `cloudflared` route.
Config splits two ways: `netdata.conf` (committed, no secrets; identical on
vps00/vps02, vps01 adds `[plugins] backup_age = yes`) and
`health_alarm_notify.conf` (generated at deploy time, never committed —
`docker compose config` doesn't need it to exist, `docker compose up` does).

**Retention 3d, cap 256m, since 2026-08-29.** `dbengine tier 0 retention
time = 3d` in `netdata.conf` and `mem_limit: 256m` / `mem_reservation: 128m`
in each node's compose file. Both moved together: the agent had been sitting
at 87-90% of the old 200m cap and dbengine is what fills it. See the failure
log below for the measurements and for the number still owed.

**Metrics only, since 2026-08-23.** `systemd-journal`, `systemd-units`,
`otel`, `statsd` and `netflow` are `= no` in `[plugins]`: logs are
OpenObserve's job, and the three receivers had no sender. Accepted cost:
while OpenObserve or Vector is down there is no dashboard view of a node's
logs; recovery reading is `ssh` + `journalctl`. The plugin keys are the
ones the agent prints at `http://127.0.0.1:8N50/netdata.conf`, not the
binary names in `ps` (`sd-jrnl.plugin` is `systemd-journal`). Effective
values were read back from that URL on vps02 before merging: assert there,
never from the file you wrote. Note `netflow` had been listening on
`0.0.0.0:2055`/`6343` UDP on every node -- Netdata is `network_mode: host`,
so `daemon.json`'s loopback bind never applied to it and UFW was the only
layer in front. The TCP sweep in rail 1 does not see UDP; `ss -lunp` on
the node does.

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
onto it: never make an alarm the only delivery path for something that matters.

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
a real transition reaching Telegram is evidence. One production alarm has it:
`ezbookkeeping_backup_age`, via the 2026-08-19 drill recorded in
`vps01/CLAUDE.md`. The `to: sysadmin` recipient path has its own separate proof
below, from a throwaway alarm on vps02 — a different claim, and neither one
makes the other redundant.

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
to its own dedup state (`vps01/CLAUDE.md` failure log — that entry moved
there with the backup sections), not a property of the recipient.

## Beszel agents

`henrygd/beszel-agent:0.18.8` on all three nodes, `network_mode: host`,
TCP 45876 -- vendor-fixed, so it does **not** follow the `8NXX` scheme
above, and unlike every other workload port it is not loopback-bound.
The hub lives on the Ashes node, outside this repo, and dials **inward**
over SSH; the agent never dials out, and `KEY` is the hub's SSH *public*
key, not a secret. Nothing is published -- no DNS record, no Access app,
no tunnel ingress rule. Rest of the detail: each node's compose comments.

**Host mode makes ufw the only guard.** The listener never traverses
FORWARD, so `DOCKER-USER` never sees it and `daemon.json`'s loopback
bind does not apply; its traffic hits `filter INPUT`. `harden-node.sh:44`
sets `ufw default deny incoming`, so 45876 is closed until a
**hand-applied, per-node, source-restricted** rule opens it: `ufw allow
from <hub-ip> to any port 45876 proto tcp`. **Applied on all three nodes
2026-09-02**, source verified equal to the operator's `Host ashes` entry
-- read `ufw status` before re-applying rather than assuming it is
missing. `IPV6=yes` on all three with no v6 rule for 45876: not a hole,
the default deny covers v6, but a hub dialling a node over IPv6 would be
dropped. The rule is uncommitted on purpose (rail 5), so **no script
creates it** and a node rebuilt from `scripts/` alone comes up without it
while the hub silently loses that node. Bridge mode with `ports:` would
move the traffic to FORWARD/`DOCKER-USER`, where the ufw source
restriction does not apply. 45876 is in `port-sweep.yml`'s list, so the
twice-daily off-node sweep, from GitHub-hosted runners and never the
hub's address, asserts it reads closed from the internet.

**128m/32m are measured, on a different host** -- the same image on the
hub's node used 11.85 MiB resident after 30 minutes, with a Docker socket
these three do not get. Read `docker stats` here anyway once they have run
a week. Note all three nodes carry 2047 MB of swap on `/swapfile`
(`scripts/add-swap.sh`), so root's "no swap by default" describes the
provider image, not the nodes as they run today. **No `docker.sock`**
(same reason as Netdata above) and no healthcheck: nothing to curl, and
the hub's connection is the liveness signal. **Netdata is unaffected**;
retiring it is a separate, later decision blocked on comparing alerts.

## Logs (OpenObserve + Vector)

Design: `docs/superpowers/specs/2026-08-22-siem-openobserve-design.md`.
Netdata is metrics; this is logs, deliberately a separate tool.

- vps02 runs `openobserve` (store + UI, `127.0.0.1:8251`, Parquet on the
  `openobserve-data` volume) and `vector`; vps00/vps01 run `vector`
  only. vps02's Vector posts to `http://127.0.0.1:8251`, the other two
  to `https://siem-ingest.maybeit.work` — outbound HTTPS, rail 1
  untouched.
- **No `docker.sock`** (same reason as Netdata above). Container stdout
  reaches Vector because `scripts/setup-maintenance.sh` sets Docker's
  log driver to `journald` — once that script has been run by hand on the
  nodes (plan Task 9); it is not part of `deploy.yml`. The journal is
  Vector's only source, so `sshd`, `sudo`, Fail2Ban, cron and every
  container land in one stream. Containers keep the **old** driver until
  dockerd is restarted *and* they are recreated: `setup-maintenance.sh`
  deliberately never restarts Docker, so recreating a container on its
  own changes nothing.
- `vector.yaml` is **byte-identical on all three nodes** and
  `check-rails.sh` fails if the copies drift; per-node differences are
  environment only (`NODE_NAME`, `OPENOBSERVE_INGEST_URL`, and on
  vps00/vps01 the `CF_ACCESS_SIEM_*` pair). Edit all three together.
- The `CF-Access-*` headers are sent **empty** on vps02: it posts to
  localhost and never crosses the edge, and OpenObserve ignores them.
  That is why they default to empty in `vector.yaml` rather than being
  required.
- Credentials: `OPENOBSERVE_ROOT_EMAIL`/`_PASSWORD` are the **UI** login.
  Ingest uses `OPENOBSERVE_INGEST_USER`/`_PASSWORD`, which are a
  dedicated OpenObserve user created in the UI — until plan Task 12
  rotates them, the root credentials are used for ingest too. Rotate,
  don't leave it.
- `mem_limit`s (rail 4) are **hedged, not measured**: openobserve
  384m/192m, vector 128m/64m, plus `ZO_MEMORY_CACHE_MAX_SIZE=64` because
  OpenObserve sizes its cache from host RAM, not the cgroup limit.
  Measure after a week and replace these numbers.
- Retention is `ZO_COMPACT_DATA_RETENTION_DAYS=30`, and the volume is
  **not backed up**: logs are evidence, not a dataset, and losing 30
  days of them on a rebuild is accepted.
- **Vector authenticates as `vector-ingest@maybeit.work`, not root**
  (2026-08-23). Rotating or deleting it never touches the account Ex logs
  in with. It is an **admin** user, though, and that is a ceiling not a
  choice: open-source OpenObserve accepts only `root` and `admin`, and
  rejects `member`, `viewer` and `editor` with `Custom roles not allowed`.
  So this buys credential separation, **not** least privilege -- a leaked
  ingest credential still has admin on the org. The real gate in front of
  the endpoint is the Cloudflare Access service token.
- **Measured memory, 2026-08-23**, after ~50 min of ingest from three
  nodes: `openobserve` 338-343 MiB steady (three samples, not growing),
  `vector` 56 MiB, `netdata` 141 MiB, `cloudflared` 31 MiB; host 1061 MB
  of 1966 MB used. OpenObserve's cap was raised 384m -> 512m on the back
  of that, because 89% of a cap is not a working margin.
- **Apply that margin rule to every cap in the file, not the one service
  you are measuring.** The 2026-08-23 raise fixed OpenObserve and left
  `netdata` at 200m; by 2026-08-29 it read 175/179/173 MiB on
  vps00/vps01/vps02 -- 87-90% of its cap, the exact number that had
  justified the OpenObserve raise six days earlier. No OOM kill yet
  (`RestartCount` 0, `State.OOMKilled` false on all three), so nothing
  ever surfaced it. Raised to 256m/128m and retention trimmed 7d -> 3d
  the same day. **The new figure is not measured yet (issue #84):**
  re-read `docker stats` and `netdata.memory` a few days after the deploy
  and replace this sentence with the number.
- **Netdata's memory is dbengine, and retention is the only lever.** Its
  own `netdata.memory` chart on vps01 (2026-08-29) accounts for 104 MB,
  of which `dbengine` is 93.4 MB; everything else is under 5 MB each.
  `dbengine page cache size` was already at the stock 32MiB, so the cache
  is not what grew -- the mmap'd journal v2 index files are, and those
  scale with `dbengine tier 0 retention time`. RSS runs well above the
  agent's own total (179 MiB vs 104 MB) because allocator and mapped
  files are not in that chart; judge the cap by `docker stats`, tune with
  the chart.
- **`deploy.yml`'s verify step proves liveness, not ingestion** — only
  that the `vector` container is running. Prove ingestion by hand, once
  per node: `logger -t siem-test "hello from $(hostname)"`, then find
  that line in the `journal` stream with the right `node` value.
- **Wire format confirmed 2026-08-23, first successful ingest:** Vector's
  `json` codec sends a JSON array and OpenObserve's `/_json` accepts it
  as-is. No `framing.method` needed; don't add one.
- **OpenObserve lowercases field names on ingest.** The journal's
  `SYSLOG_IDENTIFIER` is queried as `syslog_identifier`; querying the
  original case returns `unknown field`, with the lowercase form as its
  suggestion. Search with SQL over the stream, e.g.
  `SELECT node, syslog_identifier, message FROM journal WHERE
  syslog_identifier = 'siem-test'`.
- **`doc_num` on `/api/default/streams` reads 0 while rows are already
  queryable** -- it counts what has been flushed to disk, not what is in
  the WAL. Use `_search` to decide whether ingestion works; a zero there
  means nothing arrived, a zero on `doc_num` means nothing yet.

Backups, R2 retention and locks, restore/alarm drills and the backup
staleness alerting are vps01-only: `stacks/vps01/CLAUDE.md`.

## Failure log

Incident histories behind every rule here: `failure-log` skill (`stacks/`).

- **Check `docker inspect -f '{{.State.StartedAt}}'` before trusting a
  `memory.peak`.** A comment-only change is not a config delta, so Compose
  leaves the container running and its peak keeps the *old* window; a real
  change recreates it and the peak has no history. Both read as fresh.
- **Deleting a hostname does not delete the Cloudflare rules aimed at it.**
  Re-read every zone ruleset expression for the name afterwards. A rule
  that survives its target reads as coverage while matching nothing, and
  the free plan allows exactly one rate-limit rule.
- **When a service's port moves, grep its image's baked-in healthcheck
  too.** A stale healthcheck reports `unhealthy` while the service answers
  fine on the real port, so anything keyed on Docker health status
  false-alarms. Override `healthcheck:` per node in compose.
- **A newly created Access application 404s at the edge before it starts
  `302`ing** — seconds, not minutes. Do not read it as a broken route and
  start unpicking the tunnel: check the ingress and the origin, then
  re-probe. Curling the *other* Access-protected hosts is the control that
  settles it.
- **When a container reads a secret file, check the *in-container* uid and
  test as that user, not root.** Host-side `600 deploy:deploy` looks
  correct and is unreadable by a container running as another uid (Alert
  delivery above).
- **Set `SEND_EMAIL="NO"` in the notify templates.** `alarm-notify.sh`
  enables email **by default**, so with no MTA every alert also runs
  sendmail — a steady error stream that hides real breakage. Check a
  notifier's real default before writing that an unlisted method is
  disabled.
- **Never `sed -i` a bind-mounted single file:** it writes a new inode and
  the container keeps reading the old one. Use `cat new > file` for
  `netdata.conf` and `health.d/*.conf`.
- **A web control plane with no 2FA and no audit log is only as safe as
  the Access app in front of it** (Dokploy v0.29.14 had neither, verified
  empirically; removed 2026-08-23). Authentication and the access log for
  every ops surface live in Cloudflare Access (Zero Trust → Logs →
  Access), which also records attempts that never reach the origin.
- **Count Access policies by reading them back, never from what the last
  session added.** This file said `budget` carried one policy for three
  days while the app carried two. Ask
  `/accounts/{id}/access/apps/{app}/policies` before writing a count — an
  undocumented policy is an access grant nobody is reviewing.
- **OpenObserve panics at startup on a root password it considers weak**,
  so the symptom is a crashloop, not a message about credentials. It
  collides with the dotenv rule (`#` and `$` truncate or interpolate); the
  overlap is narrow, and `!`, `@`, `%`, `-` and `_` satisfy both.
  `ZO_ROOT_USER_*` applies only at first boot, so changing the secret
  afterwards does nothing until the `openobserve-data` volume is wiped --
  safe here, that volume is explicitly not backed up.
- **A newly created hostname stays unresolvable for up to 30 minutes.**
  The zone's SOA minimum is 1800s, so a resolver asked for the name
  *before* the record existed caches the NXDOMAIN that long, and the nodes
  run no local caching daemon -- there is nothing to flush. Wait it out;
  create the DNS record before pointing anything at it to skip it.
- **`vector validate` cannot prove interpolation.** Vector 0.57.0 disabled
  config env-var interpolation by default, so every `${...}` in
  `vector.yaml` is a literal string unless the container sets
  `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` -- and an
  uninterpolated `${...}` is perfectly good YAML, so validate passes on a
  config that cannot send a single request. Only a real request proves it.
  Checked by `scripts/check-rails.sh` (the env var, not the request).
- **Never set `current_boot_only: false` on the Vector journald source.**
  Vector rejects it outright for systemd 250-257 and Debian 12 runs 252,
  so no node can ever take it; it crashlooped all three while `Verify`
  called them green. Losing the pre-reboot backfill is the price of a
  Vector that starts. Checked by `scripts/check-rails.sh`.
- **Never pin a journald source to `/var/log/journal`** — a node with
  volatile journal storage has nothing there, so Vector ships nothing and
  still reports healthy. Assert `Storage=persistent`
  (`setup-maintenance.sh`) and let Vector follow `journalctl`'s own
  resolution. Checked by `scripts/check-rails.sh` (the
  `journal_directory` key).
- **Never reuse another node's tunnel token** (rail 2). Cloudflare
  load-balances the hostname across both connectors, so ~2/3 of requests
  land on the node with nothing on that origin port and 502.
- **A control plane is a workload: measure it and cap it like one, or do
  not run it.** Dokploy's was 749.7 MiB of a 1966 MB node, and its Traefik
  on two of the three nodes routed nothing at all.
- **Query a *container* name from inside the container's netns before
  calling Docker networking healthy.** Embedded DNS forgot every container
  name on a user-defined network on two nodes at once while `127.0.0.11`
  still resolved external names -- so `wget google.com` proves nothing.
  Repair with `docker network disconnect <net> <c>` then `connect --alias
  <service> --alias <container>`: a plain `connect` restores the container
  name and **drops the Compose service alias**, which is the name the app
  actually dials. Probe the app on its loopback port after any change to
  Docker networking on a node.
- **A `network_mode: host` listener sits behind ufw and nothing else, so
  reason about it with `ufw`, not `DOCKER-USER`.** Host-mode traffic never
  traverses FORWARD, so the `DOCKER-USER` drops never see it and
  `daemon.json`'s loopback bind cannot constrain it; it arrives on `filter
  INPUT`. The repo's usual Docker mental model therefore gives the wrong
  answer twice over -- Netdata's `netflow` UDP listeners (Netdata section
  above) and beszel-agent's TCP 45876. Check which chain a port lands in
  before calling it closed, and note that moving such a service to bridge
  mode silently swaps which layer is enforcing.
