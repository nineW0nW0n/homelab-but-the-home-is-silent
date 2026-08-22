# SIEM-ish log centralisation on vps02 (OpenObserve), design

Date: 2026-08-22. Status: approved in chat, awaiting implementation plan.

## Goal

One place to search logs from all three nodes, with a security slant:
SSH/auth attempts, Fail2Ban actions, sudo, file-integrity changes, and
every container's stdout. A dashboard, not an alert pipeline. A tool Ex
actually opens, distinct from Netdata (metrics) rather than doubling it.

## Non-goals (deferred, not rejected)

- Cloudflare edge events (Access logins, WAF blocks). Free plan has no
  Logpush; would need an API-polling cron. Cloudflare's dashboard shows
  them already.
- Alert rules and Telegram delivery. OpenObserve has alerting; add the
  first rule when one thing proves worth pinging.
- Rootkit / CIS scanners (Wazuh-class agents). Too heavy for 2GB nodes.
- Cross-node correlation beyond what a single SQL query over one table
  gives.

## Why not the alternatives considered

- Wazuh / Graylog / Elastic / Security Onion: all need an OpenSearch or
  Elasticsearch index that wants 4GB+ alone. Not a fit for a 2GB node
  with no swap by default.
- Loki + Grafana + Alloy: fits, but three containers on vps02 and an
  alerting stack nobody asked for once delivery became dashboard-only.
- Netdata's journal Logs explorer: zero new containers, but the single
  pane across nodes is Netdata Cloud's Logs tab, which needs a paid plan.
  Per-node pages only, so it does not give "one place".
- VictoriaLogs: lighter still, but its UI is a query box; no saved
  dashboards, no login.
- Dozzle: live tail only, no history, no journald. Fails the SSH scope.

## Components

| Node | Service | Role |
|---|---|---|
| vps02 | `openobserve` | Store + UI. Single Rust binary, Parquet on a named volume, local mode. |
| vps02 | `vector` | Ships vps02's own journal to `localhost:5080`. |
| vps00, vps01 | `vector` | Ships that node's journal to `siem-ingest.maybeit.work`. |

No Grafana, no Loki, no Alloy, no `docker.sock` mount anywhere
(`stacks/CLAUDE.md`: a socket mount is host root on an RCE).

All services live in the existing `stacks/<node>/docker-compose.yml`
files and deploy through `deploy.yml` like `cloudflared` and Netdata.
Images pinned to exact tags.

## What gets logged, and how it reaches journald

Vector reads exactly one source per node: the systemd journal. Everything
worth seeing is routed into the journal first, so no second collector and
no Docker API access is needed.

- Already in the journal: `sshd`, `sudo`, Fail2Ban (`backend = systemd`),
  cron, systemd units.
- Container stdout/stderr: `setup-maintenance.sh` switches Docker's
  `daemon.json` to `"log-driver": "journald"`. Entries carry
  `CONTAINER_NAME`, `CONTAINER_ID`, `IMAGE_NAME` fields. `docker logs`
  keeps working with the journald driver. The existing `json-file`
  `log-opts` (10m x 3) stop applying; journald's own cap takes over.
- journald cap: `setup-maintenance.sh` raises `SystemMaxUse` from `200M`
  to `1G` because container logs now land there. Disk is watched by the
  existing Netdata disk alarm.
- File integrity: new `scripts/install-aide.sh` (idempotent POSIX `sh`,
  run as root via the `vps0N-root` alias like the other node scripts):
  `apt-get install aide`, `aideinit` once, daily `/etc/cron.d/aide` that
  runs `aide --check` and pipes output through `logger -t aide`. Changes
  show as log lines with `SYSLOG_IDENTIFIER=aide`. The AIDE database is
  refreshed by the same cron after a successful check so the next run
  diffs against yesterday, not against provisioning day.

Vector config (`stacks/<node>/vector.yaml`, committed, no secrets):
`journald` source (all units; noise filtered later in the UI, not at the
shipper), `http` sink to OpenObserve's `/api/default/<stream>/_json`
endpoint, JSON batch, gzip, basic auth + Access headers from environment.
Streams: `journal` for everything; one stream, split later if a query
ever needs it. The container mounts `/var/log/journal`,
`/run/log/journal` and `/etc/machine-id` read-only and uses the image's
own `journalctl`.

## Transport and exposure

- vps02's Vector posts to `http://localhost:5080` (`network_mode: host`,
  nothing leaves the box).
- vps00/vps01's Vector posts to `https://siem-ingest.maybeit.work`, a
  Public Hostname on vps02's existing tunnel (`CLOUDFLARE_TUNNEL_TOKEN_
  VPS02_METRICS`; rail 2 holds, the token stays vps02's) with origin
  `http://localhost:5080`. Outbound HTTPS only; rail 1 untouched.
- Cloudflare terminates TLS at the edge, so Cloudflare can read log
  lines in transit. Accepted for a homelab; recorded so it is a choice.
- `siem-ingest` gets its own Access application with one policy: service
  auth for a **new** service token named `siem-ingest`. The existing
  `status-worker` token stays scoped to the three `*-metrics` apps
  (`stacks/CLAUDE.md`). Vector sends `CF-Access-Client-Id` /
  `CF-Access-Client-Secret` plus OpenObserve's basic-auth ingest
  credential: two independent locks.
- The zone geo rule `Block non-local traffic` gains
  `and http.host ne "siem-ingest.maybeit.work"`: the nodes are US-hosted
  and would 403 otherwise. Only the country check is lifted, only on
  that hostname, which is still gated by service token and basic auth.
- UI: `siem.maybeit.work`, same tunnel, same origin, Access application
  `siem` with the `owner email allow` policy, PH-only like `budget` and
  `dokploy`. OpenObserve's own login sits behind that.
- Port 5080 binds loopback through `daemon.json`'s existing `"ip":
  "127.0.0.1"`. The off-node sweep list in root `CLAUDE.md` rail 1 gains
  5080 and must read closed.

## Secrets

GitHub Actions secrets, written into each node's `.env` by `deploy.yml`
the way tunnel tokens are. Never committed, never printed in full
(rail 11).

| Secret | Used on | Purpose |
|---|---|---|
| `OPENOBSERVE_ROOT_EMAIL` | vps02 | `ZO_ROOT_USER_EMAIL`, UI login |
| `OPENOBSERVE_ROOT_PASSWORD` | vps02 | `ZO_ROOT_USER_PASSWORD` |
| `OPENOBSERVE_INGEST_AUTH` | all | basic-auth value Vector sends (`base64(email:password)` of a dedicated ingest user created in the UI after first boot; root creds until then) |
| `CF_ACCESS_SIEM_CLIENT_ID` | vps00, vps01 | service token header |
| `CF_ACCESS_SIEM_CLIENT_SECRET` | vps00, vps01 | service token header |

## Memory (rail 4) and retention

Hedged until measured on the nodes; adjust after the first week.

| Service | `mem_limit` | `mem_reservation` |
|---|---|---|
| `openobserve` (vps02) | 384m | 192m |
| `vector` (each node) | 128m | 64m |

vps02 after: cloudflared 64m + Netdata 200m + openobserve 384m + vector
128m = 776m of caps, inside the ~1.2GB left after Dokploy's Traefik and
agent. vps00/vps01 add 128m each.

Retention: `ZO_COMPACT_DATA_RETENTION_DAYS=30`. OpenObserve data on a
named volume `openobserve-data`. Not backed up: logs are evidence, not a
dataset; losing 30 days of them on a rebuild is acceptable.

## Rollout order

1. Repo changes, one PR: compose + `vector.yaml` on three stacks,
   `deploy.yml` secret plumbing, `setup-maintenance.sh` (log driver,
   journald cap), `scripts/install-aide.sh`, docs and rails updates.
2. GitHub secrets set by Ex (five above).
3. Cloudflare, in this order, dashboard-driven with Claude leading the
   browser and stopping where Ex must act: service token `siem-ingest`;
   Access app `siem-ingest` (service auth policy); Access app `siem`
   (owner email); two Public Hostnames on vps02's tunnel; geo rule
   exemption. Verified afterwards through the read-only Cloudflare MCP
   servers, not assumed.
4. Node side, as root from the laptop: `setup-maintenance.sh` on all
   three (restarts Docker; containers keep the old log driver until
   recreated), then `install-aide.sh` on all three.
5. Merge, approve `deploy.yml`. The deploy recreates the stack
   containers, which picks up the journald driver. booking and
   ezBookkeeping are Dokploy-managed and are recreated from the Dokploy
   UI (Redeploy) so they switch too: seconds of downtime on vps01, stated
   in advance.
6. Create the dedicated ingest user in the OpenObserve UI, rotate
   `OPENOBSERVE_INGEST_AUTH` from root creds to it, redeploy.

## Verification (definition of done)

- `docker compose config` passes for all three stacks; `pre-commit run
  --all-files` green; `shellcheck -s sh` clean; `check-rails.sh` still
  passes (every new service has `mem_limit`/`mem_reservation`).
- `install-aide.sh` and the changed `setup-maintenance.sh` run twice on
  one node; the second run is a no-op.
- `logger -t siem-test "hello from $(hostname)"` on each node shows up
  in the `journal` stream within one minute, with the right `host`.
- A container log line (e.g. cloudflared's startup) is visible with its
  `CONTAINER_NAME`.
- Off-node sweep: 22 open; 80/443/2377/3000/5080/19999 closed on all
  three nodes.
- `curl -sI https://siem-ingest.maybeit.work/` without headers from a
  PH client: Access 403/302, never 200. `https://siem.maybeit.work/`
  unauthenticated: 302 to `old-firefly-996b.cloudflareaccess.com`.
- `cfd_tunnel/{id}/configurations` for vps02's tunnel shows exactly the
  three hostnames (`vps02-metrics`, `siem`, `siem-ingest`); connector
  list still one `client_id`.

## Docs touched in the same PR

- `stacks/CLAUDE.md`: hostname list gains `siem` and `siem-ingest`, the
  service-token scoping note gains the `siem-ingest` token.
- `scripts/CLAUDE.md`: `setup-maintenance.sh` entry updated,
  `install-aide.sh` added.
- Root `CLAUDE.md`: rail 1 sweep list gains 5080; "When" paragraph says
  three workloads live.
- `README.md`: one line on what runs on vps02 now.
- Memory `cloudflare-blocks-non-ph-traffic`: exemption list gains
  `siem-ingest`.
