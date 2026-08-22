Parent: ../.claude/CLAUDE.md

# stacks/: per-node compose files

One `docker-compose.yml` per node, deployed by `deploy.yml` to
`/opt/stacks/<node>/`. Each runs that node's `cloudflared` connector (rails 2,
3) plus any node-specific workload not deployed through Dokploy directly.

## Tunnel mode and routes

`cloudflared` runs in **token mode** (`tunnel run` + `TUNNEL_TOKEN` env).
Public-hostname routing is owned by the Cloudflare Zero Trust dashboard
(Networks → Tunnels → *tunnel* → Public Hostnames), not by any file here. Add
or change routes there. Every tunnel reports `source: "cloudflare"`, so the
live ingress map is remote state with no version history and no diff against
this list — read it back (`cfd_tunnel/{id}/configurations`, `tooling-setup`)
rather than trusting the routes below, and treat any mismatch as the
dashboard having drifted from the docs, not the reverse.

Eight hostnames are live (six verified 2026-08-20; `siem` and
`siem-ingest` are created by plan Task 10 and unverified until then),
across three tunnels:

- `dokploy.maybeit.work` → `http://localhost:3000` on vps00, token
  `CLOUDFLARE_TUNNEL_TOKEN`. **Behind a Cloudflare Access application**
  (`dokploy`, 24h session) since 2026-08-16, carrying **one** policy:
  `owner email allow`. It does **not** carry a service-token policy — that
  was detached 2026-08-20 so this public Worker's credential could not reach
  the deploy control plane, and re-adding one to "match the `*-metrics` apps"
  re-opens exactly what was closed. Unauthenticated must `302` to
  `old-firefly-996b.cloudflareaccess.com`; a `200` means the policy detached
  and the control plane is open again. Probe `/` only, and **from a PH
  client** — the zone's geo rule 403s everything else before Access is
  reached, and `/api/deploy` is a separate bypass app that answers `401`.
- `vps00-metrics.maybeit.work` → `http://localhost:19999` on vps00, same
  tunnel. Behind its own Access app; the `status-worker` service token opens
  the three `*-metrics` apps and nothing else.
- `booking.maybeit.work` → `http://localhost:80` on vps01 (Dokploy's own
  Traefik, forwarding to whichever container the Domain in Dokploy's UI points
  at), token `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`: its own dedicated tunnel.
- `budget.maybeit.work` → `http://localhost:80` on vps01, same tunnel:
  ezBookkeeping, the SQLite dataset `vps01/CLAUDE.md` backs up. Behind its
  own Access application (`budget`, 24h session) since 2026-08-20, one
  policy: `owner email allow`. Until then the zone geo rule was the only
  thing in front of it, so it was open to anyone in PH. No service-token
  policy — nothing automated polls it. **Access breaks non-browser
  ezBookkeeping clients**, which cannot complete the login flow; if a
  mobile or desktop client needs to sync, that is the trade-off to revisit.
- `vps01-metrics.maybeit.work` → `http://localhost:19999` on vps01, same
  tunnel, behind Access.
- `vps02-metrics.maybeit.work` → `http://localhost:19999` on vps02, token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`: its own dedicated tunnel, behind
  Access, and vps02's first workload *from this repo*.
- `siem.maybeit.work` → `http://localhost:5080` on vps02, same tunnel:
  the OpenObserve UI. Access application `siem`, one policy,
  `owner email allow`, PH-only like `budget` and `dokploy`.
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

**Two service tokens, never crossed.** `status-worker` opens the three
`*-metrics` apps and nothing else; `siem-ingest` opens `siem-ingest` and
nothing else. Adding either token's policy to the other's app hands one
credential a scope it was minted to not have — the same mistake as the
`dokploy` app's detached policy above.

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

## Logs (OpenObserve + Vector)

Design: `docs/superpowers/specs/2026-08-22-siem-openobserve-design.md`.
Netdata is metrics; this is logs, deliberately a separate tool.

- vps02 runs `openobserve` (store + UI, `127.0.0.1:5080`, Parquet on the
  `openobserve-data` volume) and `vector`; vps00/vps01 run `vector`
  only. vps02's Vector posts to `http://127.0.0.1:5080`, the other two
  to `https://siem-ingest.maybeit.work` — outbound HTTPS, rail 1
  untouched.
- **No `docker.sock`** (same reason as Netdata above). Container stdout
  reaches Vector because `scripts/setup-maintenance.sh` sets Docker's
  log driver to `journald`; the journal is Vector's only source, so
  `sshd`, `sudo`, Fail2Ban, cron and every container land in one stream.
  Containers keep the old driver until they are recreated.
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

Backups, R2 retention and locks, restore/alarm drills and the backup
staleness alerting are vps01-only: `stacks/vps01/CLAUDE.md`.

## Failure log

Incident histories behind these rules: `failure-log` skill (`stacks/`).

- **A newly created Access application 404s at the edge before it starts
  `302`ing** — seconds, not minutes (observed 2026-08-20 creating the
  `budget` app). Do not read that 404 as a broken route and start unpicking
  the tunnel: check the ingress and the origin, then re-probe. The control
  that settles it is curling the *other* Access-protected hosts; when they
  all answer the same, propagation is done.

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
