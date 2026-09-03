# HANDOFF: retire netdata and the three metrics names

TARGET REPO: homelab-but-the-home-is-silent (NOT this repo).
ISSUED BY: phoenixlab, docs/exec-plans/consolidation.md step 17.
AUDIENCE: an agent working in the homelab repo. Terse by intent.

## READ THIS FIRST — THIS SPEC IS WRITTEN FROM OUTSIDE YOUR REPO

It does not know your rails. Reconcile every instruction against your
`.claude/CLAUDE.md` and run `scripts/check-rails.sh` before committing. Where
this spec and a rail conflict, THE RAIL WINS — amend and report back rather
than following this file.

Known reconciliations, from reading your rails on 2026-09-03:

  - **rail 12 (rollback is `git revert` + push, not manual node surgery)
    conflicts with removing the volumes.** `docker compose up` does not delete
    a named volume when its service disappears; only a hand-run
    `docker volume rm` does. That is node surgery and it is not revertible.
    Section 3 isolates it as a separate, explicitly-permissioned act. Do the
    revertible part first and stop there if you prefer.
  - **rail 8 (validate before deploy)** is why section 2 exists. Removing the
    service without removing its probe leaves a deploy that fails on every
    node, forever.
  - **rail 5 (real IPs never committed)** — and note the reverse direction
    applies to this file: phoenixlab may not name your hostnames, so the three
    `*-metrics` names, the KV namespace id and the apex are referred to
    obliquely below. Read them out of your own `wrangler.toml` and
    `docker-compose.yml`; do not expect them here.

## GOAL

Netdata stops running on vps00, vps01 and vps02, and the three `*-metrics`
hostnames, their Access applications and their ingress rules cease to exist.

The Beszel hub on the Ashes node has carried all four systems since 2026-09-03
and is the replacement. This handoff is the second half of that swap.

**The status Worker is NOT deleted.** Only its polling is. Decided 2026-09-03,
recorded in phoenixlab's ADR 0006, and the reason is a dependency this spec
nearly missed: that Worker also serves `/privacy` and `/terms`, which exist at
the apex because Google's OAuth consent screen requires reachable policy and
terms URLs, and because the zone-wide country block exempts only the apex. A
later phoenixlab step rebuilds the Google Workspace MCP server with a **fresh
consent flow**, so those two routes are a precondition, not decoration.

Ordering still holds, for the original reason: the poller goes **before**
netdata does. It polls the three `*-metrics` origins and renders a node down
when a poll fails, so stopping netdata first shows three healthy nodes as dead
on a public page for as long as the gap lasts.

## DONE-WHEN

1. The apex answers at `/`, `/privacy` and `/terms` — three real requests, not
   a green deploy — and the page at `/` reports no node as down.
2. `docker ps` on each node shows no netdata container.
3. `scripts/check-rails.sh` passes.
4. `validate.yml` passes and a full `deploy.yml` run reaches all three nodes
   green — this is the one that catches section 2.
5. The three `*-metrics` hostnames do not resolve.

## 0. THE POLLER, FIRST AND SEPARATELY

Goes: the polling module, the KV binding and namespace it writes, the
`NODE_HOSTS` var, the Worker secrets holding the Access service token, and the
`/debug` path if it exists only to show poll output.

Stays: the apex route, `/privacy`, `/terms`, and the page itself.

**What the page shows with no data is your decision and must be proven by
loading it.** It fails closed today — that is documented in your own record —
so the default outcome of deleting a poller is a public page rendering three
healthy hosts as dead. Whether you strip the status section, serve a static
neutral payload, or make the fetch failure render as unknown, the test is the
same: open the page in a browser and look at it. A green deploy proves nothing
here.

Do this, verify it, and stop. Everything below can wait; nothing below is safe
until this is done.

## 1. WHAT TO REMOVE, PER NODE

- the `netdata` service block in `stacks/vps0N/docker-compose.yml`
- its three named volumes' declarations: `netdataconfig`, `netdatalib`,
  `netdatacache` (the declarations; the volumes themselves are section 3)
- the whole of `stacks/vps0N/health.d/`
- the `cloudflared` ingress entry routing the `*-metrics` hostname, wherever
  your tunnel config declares it

vps01 additionally carries `health.d/backup.conf`. It goes with the rest. Its
alert is NOT lost: `check-backup-age.sh` owns that delivery outright and runs
from cron independently — its own header says so. What dies is the chart, the
plugin and the dashboard entry.

## 2. WHAT BREAKS IF YOU REMOVE ONLY HALF

Three places reference netdata outside the compose files. All three fail
*after* a successful-looking removal, which is why they are listed before the
verification rather than in it.

- `scripts/verify-node.sh` takes a netdata port as its first argument and
  probes `/api/v1/info` on it. Left in place, every deploy fails at the probe.
- `.github/workflows/deploy.yml` passes that port argument (near the
  verify-node invocation), writes `health_alarm_notify.conf` into the
  `${NODE}_netdataconfig` volume as uid 201, and runs
  `docker compose restart netdata vector`. All three break.
- `worker/status/src/poll.js` polls the three origins and dies with the Worker,
  not with netdata. See BLOCKED above.

## 3. THE VOLUMES — SEPARATE, AND NOT REVERTIBLE

Three named volumes per node hold metric history. phoenixlab's plan discards
them with no copy taken, decided rather than overlooked.

They are called out separately because rail 12 says rollback is `git revert` +
push. A removed volume does not come back that way. Sections 1 and 2 are fully
revertible; this one is not.

**Ask before running it**, and treat "the containers are gone and the deploy is
green" as a complete and safe stopping point. There is no operational reason
these must be deleted in the same session.

## 4. ONE DANGLING COMMENT

`stacks/vps01/check-backup-age.sh` sets `STALE_HOURS=36` under the comment
"Matches health.d/backup.conf's warn threshold so the two agree about what
'stale' means." That file is deleted here. The constant stays; the comment now
cites nothing. Reword it to state the threshold on its own terms, in the same
commit that deletes the config.

## 5. VERIFY (run these, do not assume)

1. `docker ps` on each node: no netdata container.
2. A full `deploy.yml` run, green on all three nodes. Section 2's breakages
   only surface here.
3. `check-backup-age.sh` still delivers: touch the stamp file backwards past
   36h on vps01 and confirm the notification arrives. Its delivery is
   independent of netdata, and this is what proves that rather than assumes it.
4. The three `*-metrics` hostnames do not resolve.

## 6. DO NOT

1. DO NOT remove netdata before section 0 is done and verified. The apex fails
   closed and renders three healthy nodes as down.
2. DO NOT delete the Worker, its apex route, `/privacy` or `/terms`. Those two
   routes gate a later phoenixlab step that needs a working Google consent
   screen, and they cannot move to a subdomain while the country block exempts
   only the apex.
3. DO NOT remove `check-backup-age.sh`, its cron entries, `.telegram.env`, or
   the `backup/` rsync excludes. That script is the only working delivery path
   for backup staleness and has been since netdata's health engine was observed
   never executing its notification for that alarm.
4. DO NOT remove `vector`. It keeps shipping to the existing log store until
   each node clears — phoenixlab step 18, not this one.
5. DO NOT delete the volumes in the same act as the containers without asking.
   Rail 12, section 3.
6. DO NOT delete the Access service token before section 0 removes the code
   that uses it. Deleting it first makes every apex page load fail against the
   three origins, which is the fail-closed case again.

## 7. ROLLBACK

`git revert` + push restores the service blocks, the health configs and the
deploy wiring; the containers come back on the next deploy. DNS records and
Access applications are recreated by hand — three of each. The volumes, if
section 3 has run, do not come back at all.

## 8. NOT YOUR JOB

The three DNS records, the three Access applications, the three ingress rules
at the Cloudflare end and the Worker's service token are deleted from the
phoenixlab side, through the connection already used for the step 9 audit.
Report when the containers are gone; do not delete zone objects yourself.

The KV namespace in section 0 is the exception and is yours: it is an account
resource your `wrangler.toml` declares, not a zone object, and nothing outside
your repo refers to it.

Configuring the replacement alerting on the hub is also phoenixlab's, and it
runs *before* any of this: the parity test gates the whole handoff.
