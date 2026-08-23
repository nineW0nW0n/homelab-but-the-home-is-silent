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
| `dokploy-traefik` (vps01) | replaced by a repo-owned `traefik` container |
| `booking` / EasyAppointments + MySQL | moves into `stacks/vps01/` |
| `ezbookkeeping` | moves into `stacks/vps01/` |
| Docker Swarm (all three) | left; no services remain |
| `exim4` (all three) | removed; nothing here sends mail |

## Decisions

**Keep a Traefik, as a repo-owned container.** It costs ~80 MiB on vps01,
and it buys **routing as code**: a new app is labels in
`docker-compose.yml`, committed and reviewed like anything else. Without
it, every new hostname is a compose change *plus* a tunnel-ingress edit in
Cloudflare -- routing split across two places, one of them a dashboard.
This repo's failure log is largely dashboard-versus-docs drift (the geo
rule that silently killed autodeploy; an Access policy count wrong for
three days), so keeping routing in the same commit as the service is worth
real memory.

The counter-argument, recorded so it is not re-derived: `cloudflared`
already routes hostname to port and can match paths, Cloudflare terminates
TLS so Traefik's ACME machinery is idle, and two fixed apps could bind
distinct loopback ports with no proxy at all. That is the cheaper design
and a legitimate choice if memory ever gets tight.

What `cloudflared` cannot do at all: **rewrite** a path (it matches but
cannot strip a prefix) and middlewares -- rate limiting, basic auth, header
manipulation.

The 80 MiB lands on vps01, which sits near 1060 MB of 1966 MB once Dokploy
is gone. vps00 is the constrained node and gets no Traefik.

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

**Cut over with zero downtime.** The new Traefik binds `127.0.0.1:8080`
while Dokploy's still holds `:80`. Verify through the new one with a `Host:`
header, then flip the tunnel's ingress from `:80` to `:8080`, then delete
Dokploy. No moment where a hostname points at nothing.

**Secrets move to GitHub Secrets.** `MYSQL_ROOT_PASSWORD`, `DB_PASSWORD`
and `EBK_SECURITY_SECRET_KEY` exist today only in Dokploy's Postgres. The
first two are baked into the MySQL volume: lose them and the database will
not authenticate, and the fix is a restore rather than a reset. They must
be read out **before** Dokploy is destroyed.

## Non-goals

- Tuning `netdata` (141 MiB per node, now the second-largest consumer).
  Worth its own look; not this change.
- Renaming volumes, containers or the Compose project.
- Replacing Dokploy's UI. Losing the dashboard is accepted, explicitly.
- Touching the backup scripts' logic, schedule or R2 layout.

## Risks

| Risk | Mitigation |
|---|---|
| MySQL starts on an empty database | `external: true` volumes; row count asserted after cutover against the measured baseline (14 tables, `ea_users` 4) |
| Dokploy secrets lost with the control plane | Read out and stored in GitHub Secrets as Task 1, before anything is deleted |
| Apps unreachable during cutover | New Traefik on a spare port, verified before the tunnel moves |
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
