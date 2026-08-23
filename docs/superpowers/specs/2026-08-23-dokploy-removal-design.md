# Design: remove Dokploy, move its apps under CI

**Written:** 2026-08-23. Supersedes nothing; this is the first spec for
retiring the Dokploy control plane.

## Why

Two reasons, one measured and one architectural.

**Measured.** Dokploy costs 848 MiB on vps00 (`dokploy` 749.7 MiB,
`dokploy-postgres` 68.5 MiB, `dokploy-traefik` 29.6 MiB), plus 76.7 MiB on
vps01 and 48.4 MiB on vps02 for Traefik alone. vps00 sits at 1400 MB of
1966 MB. Removing Dokploy returns roughly 43% of that node's RAM. For
scale: the entire OpenObserve log stack uses 341 MiB.

The Traefik on **vps00 and vps02 routes nothing.** `cloudflared` on vps00
points at `localhost:3000` (Dokploy itself) and on vps02 at
`localhost:19999` and `localhost:5080`. Neither traverses Traefik. Only
vps01's Traefik is load-bearing.

**Architectural.** Root `CLAUDE.md` says GitHub Actions is the only path to
production, and rail 7 puts one approval in front of it. Dokploy is a
second path with no approval gate, which is the tension behind rail 12's
"rollback is `git revert`" and the whole dead-autodeploy episode in the
failure log. Removing Dokploy makes the repo match its own thesis.

## What stays, what goes

| Component | Fate |
|---|---|
| `dokploy` (Swarm service, vps00) | removed |
| `dokploy-postgres` (Swarm service, vps00) | removed |
| `dokploy-traefik` (vps00, vps02) | removed -- routes nothing |
| `dokploy-traefik` (vps01) | removed; no proxy replaces it |
| `booking` / EasyAppointments + MySQL | moves into `stacks/vps01/` |
| `ezbookkeeping` | moves into `stacks/vps01/` |
| Docker Swarm (all three) | left; no services remain |
| `exim4` (all three) | removed; nothing here sends mail |

## Decisions

**No reverse proxy. `cloudflared` routes straight to each app's loopback
port.** Decided 2026-08-23 after weighing Traefik twice.

Traefik would have bought routing-as-code (a new app is labels in the
compose file rather than a compose change *plus* a Cloudflare ingress
edit), path rewriting, and middlewares. It costs ~80 MiB and, with the
Docker provider, a `docker.sock` mount -- read-only, but that still grants
`docker inspect` on every container, and therefore read access to
`MYSQL_ROOT_PASSWORD`, `DB_PASSWORD` and `EBK_SECURITY_SECRET_KEY` in their
environments. A file-provider Traefik would have avoided the socket while
keeping the features.

Dropped anyway: two fixed apps need none of it, and the removal takes a
container, an image pin, a network hop and a secret-reading surface with
it. `cloudflared` already does hostname *and* path matching; Cloudflare
terminates TLS, so Traefik's ACME machinery would have sat idle.
EasyAppointments is Apache and already logs every request to stdout, so
per-request logging survives for booking without a proxy; ezBookkeeping
logs app events only, and that visibility is the one real loss.

Revisit if the app count grows, or the moment a path needs *rewriting*
rather than matching -- `cloudflared` cannot strip a prefix.

**Keep every existing container and volume name**, however ugly:

- `booking-ptpwn8_mysql-data`
- `vps01booking-ezbookkeeping-rqdyxo_data`
- `vps01booking-ezbookkeeping-rqdyxo_storage`
- containers `booking-ptpwn8-mysql-1`, `ezbookkeeping`

`stacks/vps01/backup-booking.sh` and `backup-ezbookkeeping.sh` hardcode
these (`DB_CONTAINER=`, `VOLUME_PREFIX=`). Renaming buys tidiness and
risks the only irreplaceable thing on these nodes. The volumes are
declared `external: true` so Compose adopts them instead of creating new
empty ones.

**Cut over with zero downtime.** The apps come up on their new loopback
ports while Dokploy's Traefik still holds `:80` and still serves live
traffic. Verify each new port directly, then flip the tunnel's ingress,
then delete Dokploy. No moment where a hostname points at nothing.

## Port scheme

Defined here, applied from here on. Every port below is loopback-only;
`22` remains the only port reachable from off-node (rail 1).

```
   8 N X X
   │ │ └─┴── service number within its category
   │ └────── node: 0 = vps00, 1 = vps01, 2 = vps02
   └──────── fixed prefix

   NN01-NN49   apps   -- user-facing, reached through the tunnel
   NN50-NN99   tools  -- observability and operations
```

A tool that exists on every node keeps the **same last two digits** on all
of them, so the node digit is the only thing that changes:

| Port | Node | Category | Service |
|---|---|---|---|
| 8101 | vps01 | app | `booking.maybeit.work` |
| 8102 | vps01 | app | `budget.maybeit.work` |
| 8050 | vps00 | tool | netdata |
| 8150 | vps01 | tool | netdata |
| 8250 | vps02 | tool | netdata |
| 8251 | vps02 | tool | openobserve |

**Why per-node blocks, and not one scheme repeated everywhere.**
`cloudflared` runs `network_mode: host` and dials `localhost:PORT`. If
every node used identical ports, a mixed-up tunnel token or route would
land on the wrong node and still return `200` from the wrong service --
which is rail 2's original incident, where a shared token load-balanced
across nodes with different origins. Distinct per-node ports make that
misroute fail with connection-refused instead of quietly serving wrong
data. The scheme is a safety property first and a lookup convenience
second.

Renumbering `19999` and `5080` is **not** part of this migration. Each
move touches tunnel ingress, deploy probes, `check-rails.sh`'s sweep list
(a rail-1 enforcement point) and -- for `5080` -- Vector's ingest URL on
all three nodes. They ship as their own PRs, one service at a time, each
independently verified. See "Follow-on work".

**Secrets move to GitHub Secrets.** `MYSQL_ROOT_PASSWORD`, `DB_PASSWORD`
and `EBK_SECURITY_SECRET_KEY` exist today only in Dokploy's Postgres. The
first two are baked into the MySQL volume: lose them and the database will
not authenticate, and the fix is a restore rather than a reset. They must
be read out **before** Dokploy is destroyed.

## Non-goals

- Renaming volumes, containers or the Compose project.
- Replacing Dokploy's UI. Losing the dashboard is accepted, explicitly.
- Changing the existing backup scripts' logic, schedule or R2 layout.
- Renumbering `19999` and `5080` (own PRs, see below).

## Follow-on work

Each is its own PR with its own verification. Ordered by dependency, not
importance.

**1. Netdata to metrics only.** Ex's call: Netdata covers metrics for
nodes and containers; logs are OpenObserve's job alone. Disable
`sd-jrnl.plugin` and `sd-unit.plugin` along with three receivers nothing
feeds -- `otel-plugin` (`127.0.0.1:4317`), statsd (`127.0.0.1:8125`) and
`netflow`. Then measure and set `mem_limit` to the observed figure plus
headroom, the method that moved OpenObserve 384m to 512m.

Recorded cost, accepted: when OpenObserve or Vector is down, there is no
longer a dashboard showing that node's logs. Recovery reading is `ssh` plus
`journalctl`.

**2. Back up OpenObserve to R2.** **This reverses a documented decision.**
`stacks/CLAUDE.md` says the volume is deliberately not backed up because
"logs are evidence, not a dataset". That line must be rewritten, not left
to contradict the new script. The reasoning changed: with Netdata reduced
to metrics, OpenObserve holds the only copy of the fleet's logs.

Follow the shape of `backup-ezbookkeeping.sh` exactly -- stop the
container, tar the volume, start it, upload with rclone, stamp
`.last-success` only after the object exists off-node, and register it with
`check-backup-age.sh`. Two things need deciding at implementation time,
both measured rather than assumed: the archive's growth rate (30 days of
three nodes' logs is not the 212 KB ezBookkeeping produces), and whether it
belongs under the existing `daily/` or `weekly/` prefix -- R2's lifecycle
rules are scoped to those two prefixes, so a third would expire never.

**3. Netdata onto the port scheme.** `19999` becomes `8050` / `8150` /
`8250`. Touches `netdata.conf`, three tunnels' ingress, the deploy probes
and the sweep list.

**4. OpenObserve onto the port scheme.** `5080` becomes `8251`. The
riskiest of the renumbers: Vector's `OPENOBSERVE_INGEST_URL` on vps02 is
loopback and moves with it, and a mistake makes the log stack go quiet
rather than fail loudly. Verify by querying for a fresh marker from all
three nodes, not by container state.

**5. Rail 1 gets an enforcement point.** Record the post-migration
listener set (`ss -lntp`, all three nodes) in `stacks/CLAUDE.md` as a
baseline, and add a scheduled workflow running the off-node port sweep.
Node addresses come from the existing `VPS0N_HOST` secrets; the job prints
only `port OPEN/closed`, never an address (rail 5). Rail 1 has been
source-checked only since it was written -- this is the first thing that
would actually catch an open port.

**6. Disable `cloudflared`'s metrics listener** (`127.0.0.1:20241` on
vps01 and vps02). Nothing scrapes it.

**7. Rename the inconsistent secrets.** The convention below is applied to
the three new secrets by this migration; the existing set is brought in
line afterwards, as its own PR.

## Secret naming

```
<OWNER>_<THING>[_VPS0N]
```

- **OWNER** is the vendor or the workload: `CLOUDFLARE`, `R2`, `TELEGRAM`,
  `NETDATA`, `OPENOBSERVE`, `SSH`, `BOOKING`, `BUDGET`, `WORKER`.
- **Node scope is always a suffix**, always `_VPS0N`, never in the middle.
- Credential pairs use consistent halves: `_ID`/`_SECRET` for tokens,
  `_USER`/`_PASSWORD` for logins.
- No ownerless names.

Workloads are named for the **hostname they serve**, not the software:
`BOOKING`/`BUDGET`, not `EASYAPPOINTMENTS`/`EZBOOKKEEPING`. Swapping the
budget app later leaves `BUDGET_SECRET_KEY` still true.

A GitHub secret's name is independent of the container's variable name.
The MySQL image requires `MYSQL_ROOT_PASSWORD` inside the container; only
the source is renamed:

```yaml
MYSQL_ROOT_PASSWORD: ${BOOKING_MYSQL_ROOT_PASSWORD}
EBK_SECURITY_SECRET_KEY: ${BUDGET_SECRET_KEY}
```

Applied by this migration:

| Dokploy's name | GitHub secret |
|---|---|
| `MYSQL_ROOT_PASSWORD` | `BOOKING_MYSQL_ROOT_PASSWORD` |
| `DB_PASSWORD` | `BOOKING_MYSQL_APP_PASSWORD` |
| `EBK_SECURITY_SECRET_KEY` | `BUDGET_SECRET_KEY` |

Deferred to follow-on 7:

| Current | Problem | Becomes |
|---|---|---|
| `CF_ACCESS_CLIENT_ID`/`_SECRET` | second prefix for one vendor; does not say which app | `CLOUDFLARE_ACCESS_STATUS_CLIENT_ID`/`_SECRET` |
| `CF_ACCESS_SIEM_CLIENT_ID`/`_SECRET` | same prefix problem | `CLOUDFLARE_ACCESS_SIEM_CLIENT_ID`/`_SECRET` |
| `CLOUDFLARE_TUNNEL_TOKEN` | vps00's, but unsuffixed -- reads global | `CLOUDFLARE_TUNNEL_TOKEN_VPS00` |
| `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING` | trailing tunnel name is dead weight | `CLOUDFLARE_TUNNEL_TOKEN_VPS01` |
| `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` | actively wrong: that tunnel carries `siem` too | `CLOUDFLARE_TUNNEL_TOKEN_VPS02` |
| `VPS00_HOST` / `_VPS01` / `_VPS02` | node as *prefix*, against the rule | `SSH_HOST_VPS0N` |
| `DEBUG_KEY` | ownerless | `WORKER_DEBUG_KEY` |

**The rename PR must also make the guard fail on empty.** A renamed-but-
missed secret reference does not error -- `${{ secrets.TYPO }}` renders as
an empty string, `actionlint` sees valid syntax, and the dotenv guard
currently prints `skip NAME: not set` and continues. That would deploy an
empty tunnel token or database password and report success. Requiring
non-empty for known-required names turns the single most likely failure of
a rename into a loud CI stop before any node is touched.

## Risks

| Risk | Mitigation |
|---|---|
| MySQL starts on an empty database | `external: true` volumes; row count asserted after cutover against the measured baseline (14 tables, `ea_users` 4) |
| Dokploy secrets lost with the control plane | Read out and stored in GitHub Secrets as Task 1, before anything is deleted |
| Apps unreachable during cutover | Apps come up on their new ports and are verified while Dokploy still serves `:80`; the tunnel moves only after |
| Backup scripts break on renamed things | Nothing is renamed; scripts asserted working after cutover |
| Swarm removal breaks networking | `dokploy-network` is an overlay Dokploy created; the new stack uses a plain bridge network and does not reference it |

## Verification

The migration is done when all of the following hold, each checked rather
than assumed:

1. `booking.maybeit.work` and `budget.maybeit.work` return 200 through the
   tunnel.
2. Booking's database still reports 14 tables and `ea_users` 4.
3. `FORCE_BACKUP=1` runs of both backup scripts succeed and the objects
   appear in R2.
4. No container named `dokploy*` exists on any node.
5. `docker info` reports Swarm `inactive` on all three.
6. vps00 memory use is below 700 MB.
7. `pre-commit run --all-files` green; `check-rails.sh` green.
