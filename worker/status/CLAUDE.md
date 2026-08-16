Parent: ../../.claude/CLAUDE.md

# worker/status/ — maybeit.work status dashboard (Cloudflare Worker)

Serves the status page at the `maybeit.work` apex and polls node health
on a Cron Trigger. Deliberately **not** deployed via Dokploy/VPS — see
the design spec for why (`docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`).

## Layout

- `src/render.js` — pure function, status JSON in, HTML out. No fetch,
  no KV — this is the only part with real branching logic, and the only
  part with a test.
- `src/poll.js` — polls each node's Netdata API (through the
  Access-gated tunnel route) + a plain Dokploy reachability check,
  returns a status snapshot. `fetch` is injectable for testing.
- `src/index.js` — wires `fetch` (render from KV) and `scheduled` (poll,
  write to KV) handlers together. No logic of its own.

## Local dev

`npm install`, `npx wrangler dev --test-scheduled`, then
`curl "http://localhost:8787/__scheduled?cron=*+*+*+*+*"` to manually
fire the poll locally before hitting `http://localhost:8787/`.

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
