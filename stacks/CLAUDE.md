Parent: ../.claude/CLAUDE.md

# stacks/ — per-node compose files

One `docker-compose.yml` per node, deployed by `deploy.yml` to
`/opt/stacks/<node>/`. Each runs that node's `cloudflared` connector
(rail 2, rail 3) plus any node-specific workload not deployed through
Dokploy directly.

## Tunnel mode

`cloudflared` runs in **token mode** (`tunnel run` + `TUNNEL_TOKEN` env) —
ingress/public-hostname routing is owned by the Cloudflare Zero Trust
dashboard (Networks → Tunnels → *tunnel* → Public Hostnames), not a local
config file in this repo. Add or change routes there.

Current routes:
- `dokploy.maybeit.work` → `http://localhost:3000` on vps00, token
  `CLOUDFLARE_TUNNEL_TOKEN`. **Behind a Cloudflare Access application**
  (`dokploy`, 24h session) since 2026-08-16 — policies mirror the
  `*-metrics` apps exactly: `status-worker service auth` (service token,
  so the status Worker can still poll it) then `owner email allow`. An
  unauthenticated request must `302` to `old-firefly-996b.cloudflareaccess.com`;
  a `200` means the policy detached and the control plane is open again.
- `booking.maybeit.work` → `http://localhost:80` on vps01 (Dokploy's own
  Traefik, forwards to the app container per the Domain set in Dokploy's
  UI), token `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING` — its own dedicated
  tunnel, not shared with vps00's.
- vps02's Netdata → `http://localhost:19999`, token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` — its own dedicated tunnel,
  vps02's first workload *from this repo*, not shared with vps00's or
  vps01's.

Note vps02 is not the empty node it reads as: Dokploy has installed
`dokploy-traefik` there too, publishing 80/443. Nothing in `stacks/`
declares it — it comes from Dokploy's Remote Server setup, same as on
vps00 and vps01. `docker ps` on a node is the truth, not this
directory.

## Netdata

Runs on all 3 nodes as a `netdata` service, `network_mode: host`,
bound to `127.0.0.1:19999` (see each node's `netdata.conf`, `[web] bind
to = 127.0.0.1` — not exposed beyond the host; reaching it publicly goes
through that node's `cloudflared` route above). Config is split two ways:
`netdata.conf` (committed, no secrets, identical across nodes) and
`health_alarm_notify.conf` (generated at deploy time by a separate step,
never committed — `docker compose config` doesn't need it to exist,
`docker compose up` does).

## Why network_mode: host (rail 3)

Bridge mode puts `cloudflared` in its own network namespace, so
`http://localhost:PORT` in a Public Hostname route resolves to the
container, not the VPS itself — the origin app is unreachable, 502.
`network_mode: host` makes `localhost` mean the node.

## Alert thresholds

`health.d/ram.conf` and `health.d/disks.conf` (identical across all 3
nodes, mounted over Netdata's stock files of the same name — same
directory, same override-by-filename as `netdata.conf`, not a merge, so
each is a full copy with only the threshold lines changed) tighten
`ram_in_use` and `disk_space_usage` warn/crit from Netdata's stock
90%/98% to 80%/90%, per the design spec — a 2GB node fills fast. Inode
usage and the other stock disk/ram alarms are untouched. No deploy.yml
change needed — `rsync -az --delete stacks/vps0N/` already ships
subdirectories, and the existing `docker compose restart netdata` step
picks up the new mounts.

## Why one token per node (rail 2)

Cloudflare load-balances a hostname's requests across *every* connector
registered to its tunnel — a route isn't pinned to a specific node.
Sharing one token across nodes with different origins means Cloudflare
sends some requests to a node with nothing listening on that origin port.

## Failure log

- vps00 and vps01 once shared one `CLOUDFLARE_TUNNEL_TOKEN`. Cloudflare
  load-balanced `dokploy.maybeit.work` across both connectors; vps01 had
  nothing on that origin port, so ~2/3 of requests 502'd. Fixed by giving
  vps01 its own tunnel + token (rail 2). Never reuse another node's token
  when adding a service here.
