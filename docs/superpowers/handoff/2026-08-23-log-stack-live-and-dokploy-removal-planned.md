# Handoff: log stack live, Dokploy removal planned

**Written:** 2026-08-23, end of session. Two things happened: the
OpenObserve log stack was finished and is live on all three nodes, and the
removal of Dokploy was specced and planned but **not started**.

**Audience:** the next agent. Read `.claude/CLAUDE.md` (root),
`stacks/CLAUDE.md`, `scripts/CLAUDE.md` and
`.github/workflows/CLAUDE.md` first. No real IPs here (rail 5). Commits
are cited by message, not SHA.

---

## Part 1: the log stack is done

All twelve tasks of `docs/superpowers/plans/2026-08-22-siem-openobserve.md`
are complete. OpenObserve on vps02 ingests the systemd journal and every
container's stdout from all three nodes. Verified by query, not by
container state:

```
node: vps02   node: vps01   node: vps00   total: 3
```

Vector authenticates as `vector-ingest@maybeit.work`, not root. **That is
credential separation, not least privilege**: open-source OpenObserve
accepts only `root` and `admin` and rejects `member`/`viewer`/`editor`
with `Custom roles not allowed`, so the ingest user is an admin. The
Cloudflare Access service token is the real gate.

### What it cost, and what now guards it

Seven deploys, six failures, every one of which reported success or said
nothing at all. The pattern is the point:

| Failure | How it presented | Check that now exists |
|---|---|---|
| `current_boot_only: false` rejected for systemd 250-257 | CI green, `ok vector` on all three nodes | restart-counter window in `Verify` |
| Vector 0.57.0 disabled env-var interpolation by default | `invalid uri character`; `vector validate` said `Validated` | none possible -- failure-log entry only |
| Compose truncated a 32-char password at its `#` | looked like wrong credentials | dotenv guard in `approve` |
| OpenObserve panics on a weak root password | crashloop naming nothing | password-policy guard in `approve` |
| `Verify` passed a crashlooping container | `ok vector` for a container that never started | restart-counter window |
| Log driver needs containers *recreated*, not the daemon restarted | `docker info` said `journald` while every container was `json-file` | judgement, in `scripts/CLAUDE.md` |

**`vector validate` structurally cannot catch the interpolation bug** -- an
uninterpolated `${...}` is a valid YAML string. Do not treat a green
validate as evidence that a config can send a request.

### Loose ends from Part 1

- `dokploy-traefik` is the last container still on the `json-file` log
  driver, on all three nodes. Dokploy starts it directly, not via compose.
  The Dokploy removal deletes it, so this resolves itself.
- The `siem.maybeit.work` UI was created but **never opened by anyone**.
  Worth confirming the OpenObserve login works; only Ex can.
- OpenObserve's cap went 384m -> 512m on measured usage (338-343 MiB
  steady). It is not backed up yet -- see Part 2.

---

## Part 2: Dokploy removal, planned not started

- **Spec:** `docs/superpowers/specs/2026-08-23-dokploy-removal-design.md`
- **Plan:** `docs/superpowers/plans/2026-08-23-dokploy-removal.md` (9 tasks)
- **PR:** #60, open, docs only, triggers no deploy

### Why

Measured, not estimated:

| Node | Dokploy components | Memory |
|---|---|---|
| vps00 | `dokploy` 749.7 + `dokploy-postgres` 68.5 + `dokploy-traefik` 29.6 | **848 MiB** |
| vps01 | `dokploy-traefik` | 76.7 MiB |
| vps02 | `dokploy-traefik` | 48.4 MiB |

vps00 sits at 1400 MB of 1966 MB. The Traefik on vps00 and vps02 **routes
nothing** -- `cloudflared` goes straight to `localhost:3000`, `:19999` and
`:5080`. It also ends a standing contradiction: root `CLAUDE.md` says
GitHub Actions is the only path to production, while Dokploy is a second
path with no approval gate.

### The three decisions that shape it

**No reverse proxy.** `cloudflared` dials each app's loopback port.
Traefik was considered twice and dropped: ~80 MiB, and with the Docker
provider a `docker.sock` mount that grants read access to every
container's environment -- where the database passwords live. The
file-provider alternative is recorded in the spec so neither is
re-derived.

**Port scheme, `8NXX`.** `N` is the node, `XX01-XX49` apps, `XX50-XX99`
tools; a tool present on every node keeps the same last two digits.
`booking` 8101 and `budget` 8102 land in the migration. It is a **safety
property before a convenience**: `cloudflared` dials `localhost:PORT` under
`network_mode: host`, so identical ports across nodes let a mixed-up route
return 200 from the wrong node -- rail 2's original incident. Renumbering
`19999` and `5080` is deliberately *not* in this migration.

**Names are frozen.** `booking-ptpwn8_mysql-data`,
`vps01booking-ezbookkeeping-rqdyxo_data`, `..._storage`, and containers
`booking-ptpwn8-mysql-1` / `ezbookkeeping` keep their Dokploy-derived
names. `backup-booking.sh` and `backup-ezbookkeeping.sh` hardcode them, and
a rename starts MySQL on an empty database. The volumes are `external:
true` so a wrong name fails loudly instead of silently creating an empty
one.

### Blocking, and only Ex can do it

**Task 1 must happen while Dokploy is still running.** Three secrets exist
only in its Postgres. Two are baked into the MySQL volume; losing them
turns the migration into a restore.

| Dokploy's name | New GitHub secret |
|---|---|
| `MYSQL_ROOT_PASSWORD` | `BOOKING_MYSQL_ROOT_PASSWORD` |
| `DB_PASSWORD` | `BOOKING_MYSQL_APP_PASSWORD` |
| `EBK_SECURITY_SECRET_KEY` | `BUDGET_SECRET_KEY` |

### Follow-on PRs, in dependency order

Ex asked for "as many PRs as it takes to move them sanely". Each carries
its own verification:

1. **Netdata to metrics only** -- disable `sd-jrnl`, `sd-unit`,
   `otel-plugin` (`:4317`), statsd (`:8125`), `netflow`. Then measure and
   re-cap. **Accepted cost, recorded:** no dashboard view of a node's logs
   while OpenObserve is down.
2. **Back up OpenObserve to R2.** **Reverses a documented decision** --
   `stacks/CLAUDE.md` says the volume is deliberately not backed up. That
   line must be rewritten, not left contradicting the script. Two things
   to measure rather than assume: the archive's growth rate (30 days of
   three nodes is nothing like ezBookkeeping's 212 KB), and which prefix
   to use -- R2 lifecycle rules are scoped to `daily/` and `weekly/`, so a
   third prefix would never expire.
3. **Netdata onto the scheme** -- `19999` to `8050`/`8150`/`8250`.
4. **OpenObserve onto the scheme** -- `5080` to `8251`. Riskiest: Vector's
   ingest URL moves with it, and a mistake makes the log stack go quiet
   rather than fail loudly. Verify with a fresh marker from all three
   nodes.
5. **Rail 1 gets an enforcement point** -- record the listener baseline in
   `stacks/CLAUDE.md` and add a scheduled off-node port sweep. Addresses
   come from `VPS0N_HOST` secrets; the job prints only `port OPEN/closed`.
   Ex confirmed that is acceptable.
6. **Disable `cloudflared`'s `:20241` metrics listener.**
7. **Rename the inconsistent secrets** to `<OWNER>_<THING>[_VPS0N]`. The
   full table is in the spec. **This PR must also make the guard fail on
   empty**: `${{ secrets.TYPO }}` renders as an empty string, `actionlint`
   sees valid syntax, and the guard currently prints `skip NAME: not set`
   and continues -- so a rename typo would deploy an empty tunnel token
   and report success.

---

## Things a future session should not "tidy up"

- The frozen container and volume names. They look like Dokploy leftovers
  because they are; that is deliberate and load-bearing.
- `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` on every Vector.
  It is not a workaround for our config; 0.57.0 disabled interpolation for
  everyone.
- The `:-none` fallbacks on the CF-Access headers in `vector.yaml`. An
  empty header value is a shape nothing here has exercised.
- The three `vector.yaml` copies being byte-identical. `check-rails.sh`
  enforces it.
