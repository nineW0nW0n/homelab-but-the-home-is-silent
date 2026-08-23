# Handoff: Dokploy removed

**Written:** 2026-08-23, end of session. All nine tasks of
`docs/superpowers/plans/2026-08-23-dokploy-removal.md` are done except the
off-node port sweep and one GitHub secret delete, both of which only Ex
can run (see the end).

**Audience:** the next agent. Read `.claude/CLAUDE.md` (root),
`stacks/CLAUDE.md`, `stacks/vps01/CLAUDE.md` first. No real IPs here
(rail 5). Commits cited by message, not SHA.

---

## What moved

| Before | After |
|---|---|
| `booking` and `ezbookkeeping` as Dokploy Compose apps, served through Dokploy's Traefik on `:80` | Three services in `stacks/vps01/docker-compose.yml`, `easyappointments` on `127.0.0.1:8101`, `ezbookkeeping` on `127.0.0.1:8102`, deployed by `deploy.yml` |
| Tunnel `vps01-booking` routed both hostnames to `localhost:80` | Routes to `localhost:8101` / `localhost:8102`, read back from the API (config version 4) |
| `dokploy` + `dokploy-postgres` Swarm services on vps00, `dokploy-traefik` on all three | Gone. Swarm inactive on all three. `exim4` purged too |
| `dokploy.maybeit.work`: tunnel route, CNAME, two Access apps, WAF skip rule | All deleted, each confirmed by re-reading |
| Three secrets only in Dokploy's Postgres | `BOOKING_MYSQL_ROOT_PASSWORD`, `BOOKING_MYSQL_APP_PASSWORD`, `BUDGET_SECRET_KEY` in GitHub, wired through `deploy.yml` and its dotenv guard |
| `dokploy/`, `bootstrap-dokploy.sh`, `cap-dokploy-resources.sh` in the repo | Deleted (PR #62) |

PRs: #60 (spec + plan), #61 (stack + workflow), #62 (repo and docs).

## Measured, not estimated

Memory `used` from `free -m`, 1966 MB nodes:

| Node | Before | After prune | ~30 min later |
|---|---|---|---|
| vps00 | ~1400 MB | 593 MB | 627 MB |
| vps01 | — | 1100 MB | 1112 MB |
| vps02 | — | 969 MB | 1000 MB |

Data: `ea_users` was `4` before and `4` after; MySQL logged no
`Initializing database`; the volume held 14 table files both times.
Both backup scripts ran unchanged against the moved containers and
uploaded to R2 (`backup-booking: done`, `backup-ezbookkeeping: done`).
All three app containers log to `journald` and their rows reach
OpenObserve under `node = vps01` (7 / 15 / 54 rows in the first hour).

## The cutover was a short outage, not side-by-side

The plan's first draft said the new containers would come up alongside
Dokploy's. They could not: container names are frozen to the strings
Dokploy's containers already held, and two MySQL processes cannot share
one data volume. Sequence that actually ran: merge #61, run parks at the
`approve` gate, `docker rm -f` Dokploy's three containers on vps01
(volumes untouched, confirmed `3`), approve, verify step green, flip the
tunnel. Minutes of downtime. The plan was corrected in the same PR.

## Things a future session must not "tidy up"

- **Frozen names.** Volumes `booking-ptpwn8_mysql-data`,
  `vps01booking-ezbookkeeping-rqdyxo_data`, `..._storage`; containers
  `booking-ptpwn8-mysql-1`, `ezbookkeeping`. The backup scripts hardcode
  them; `external: true` makes a wrong name fail loudly. Entry in
  `stacks/vps01/CLAUDE.md`'s failure log.
- The `8NXX` port scheme: `N` is the node, `01-49` apps, `50-99` tools.
  Identical ports across nodes is how a mis-routed hostname returns 200
  from the wrong node (rail 2's original incident). `19999` and `5080`
  are still off-scheme on purpose; moving them is follow-on work.
- No reverse proxy. Weighed twice, dropped over ~80 MiB and a
  `docker.sock` mount. Spec records the file-provider alternative.

## What the classifier blocks, so plan around it

The auto-mode classifier refused, every time: any command carrying
`$MYSQL_ROOT_PASSWORD`, `docker rm -f` / `docker service rm` /
`docker swarm leave` on a node, `gh secret delete`, and any Cloudflare
`execute` call batching several deletes. Single-purpose Cloudflare
writes (one PUT, one DELETE plus a read-back) went through. Ex ran the
node-side deletes with the `!` prefix and pasted the output. Write the
exact command, say what the expected output is, and ask for only the
lines that matter.

## Open, in order

1. **Only Ex:** the off-node port sweep (22 open, `80 443 2377 3000 5080
   8080 8101 8102 19999` closed, on all three). Not run as of this
   handoff. `DOKPLOY_API_TOKEN` is deleted.
2. **Done 2026-08-23, after Ex said yes:** Dokploy's two volumes and
   `/etc/dokploy` (its `ssh/` held the private key) deleted on vps00,
   then the `dokploy` line removed from root's `authorized_keys` on
   vps01/vps02. Root access re-tested on both. `infra/CLAUDE.md` has the
   key table.
3. The seven follow-on PRs in the spec, unchanged: Netdata to metrics
   only; OpenObserve to R2 (reverses `stacks/CLAUDE.md`'s "not backed
   up" line); Netdata and OpenObserve onto the port scheme; rail 1's
   scheduled sweep; `cloudflared` `:20241` off; secret renames with the
   guard failing on empty.
4. `stacks/vps01/docker-compose.yml` still bind-mounts nothing for the
   apps and passes `EBK_USER_ENABLE_REGISTER: "false"` as a literal;
   creating another ezBookkeeping account now means a one-commit flip
   and a deploy, not a Dokploy env edit.
