Parent: ../../.claude/CLAUDE.md

# worker/status/ — maybeit.work status dashboard (Cloudflare Worker)

Serves the status page at the `maybeit.work` apex. Polls node health
fresh on every page load — no Cron Trigger, see failure log for why.
Deliberately **not** deployed via Dokploy/VPS — see the design spec for
why (`docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`).

## Layout

- `src/render.js` — pure function, status JSON in, HTML out. No fetch,
  no KV — this is the only part with real branching logic, and the only
  part with a test.
- `src/poll.js` — polls each node's Netdata API (through the
  Access-gated tunnel route) + a plain Dokploy reachability check,
  returns a status snapshot. `fetch` is injectable for testing.
- `src/index.js` — the `fetch` handler polls fresh, writes the snapshot
  to KV, then renders it (or returns it raw at `/debug`). No
  `scheduled` handler — deliberately, see failure log.

## Local dev

`npm install`, `npx wrangler dev`, then hit `http://localhost:8787/` —
every load polls live, no separate step needed.

## Secrets

`CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` — the Cloudflare
Access service token created in the design's Cloudflare dashboard step.
Set via `wrangler secret put`, never in this directory.

## Failure log

- `poll.js`'s Netdata chart/dimension names were unverified guesses at
  first deploy; confirmed against a live vps00 node's `/api/v1/charts`
  (2026-08-16) and two were wrong. `system.cpu` has no `idle` dimension
  in this deployment's Netdata config — fixed by summing the
  busy-state dimensions instead (falls back to `100 - idle` if a config
  does report one, see `queryCpuBusyPercent`). The root filesystem
  chart id keeps the literal `/` (`disk_space./`), not sanitized to `_`
  as guessed. `system.ram`/`used` was correct as guessed.
- Cloudflare Cron Triggers can't reliably poll this account's own
  Access-protected Netdata apps. Even with a confirmed-working
  `CF_ACCESS_CLIENT_ID`/`SECRET`, `scheduled()` calling `pollAll`
  directly got a 403 from Access on every Netdata call, every tick, no
  exceptions — while the identical call succeeded from a real
  HTTP-triggered `fetch()` invocation every time. First workaround
  tried: have `scheduled()` self-fetch `/__poll` so the real poll ran
  inside a nested `fetch()` invocation instead. **That didn't work
  either** — still 403'd at the next real cron tick, even though
  manually hitting `/__poll` from outside Cloudflare (plain curl)
  worked every time. So it's not "scheduled vs fetch handler type",
  it's that anything in a request chain rooted at a Cron Trigger gets
  hit, no matter how many fetch() hops deep. Root cause not confirmed
  (Cloudflare-side, nothing visible from this repo to dig further).
  Current fix: no Cron Trigger at all — `wrangler.toml` has no
  `[triggers]` block, `index.js` has no `scheduled()` handler, and the
  `fetch()` handler polls fresh on every page load instead of reading a
  cached KV snapshot. Trade-off accepted deliberately: page load is
  slower (waits on live Netdata + Dokploy calls) in exchange for
  actually working. KV write stays, only to carry `lastSeen` forward
  across visits when a node's down at the current one.
- Separately, vps02's Cloudflare Tunnel showed `Inactive` / 0 replicas
  in the dashboard — cloudflared on vps02 had never once connected,
  Netdata calls to it got a 530 (Cloudflare-level, not Access). Fixed
  by rotating the tunnel token (Cloudflare dashboard → Tunnels →
  vps02-metrics → Rotate token) and updating
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, then re-running `deploy.yml`
  to push it. Confirmed healthy (1 active replica) after. Root cause of
  the original bad token unclear — likely a bad paste when it was first
  set (the value was never visible to the assistant, added directly by
  a human via the dashboard in an earlier session).
