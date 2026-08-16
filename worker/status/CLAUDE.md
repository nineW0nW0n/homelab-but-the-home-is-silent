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
- `src/index.js` — wires `fetch` (render from KV, plus `/__poll` and
  `/debug`) and `scheduled` (self-fetch `/__poll`) handlers together.
  `scheduled` doesn't poll directly -- see failure log below for why.

## Local dev

`npm install`, `npx wrangler dev`, then
`curl "http://localhost:8787/__poll"` to manually fire the poll locally
before hitting `http://localhost:8787/`. Don't use
`--test-scheduled`/`/__scheduled` for this -- `scheduled()` self-fetches
the *production* `maybeit.work/__poll` (see failure log), so exercising
it locally would poll and write to real production KV.

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
- Even with a confirmed-working `CF_ACCESS_CLIENT_ID`/`SECRET` (rotated
  and verified via direct curl and via a `fetch()`-handler request),
  `scheduled()` calling `pollAll` directly still got a 403 from
  Cloudflare Access on every Netdata call, every cron tick, no
  exceptions. The identical `pollAll` call succeeds every time when run
  inside a `fetch()` invocation instead. Root cause not confirmed
  (Cloudflare-side, not something visible from this repo) -- Cron
  Trigger subrequests to this account's own Access-protected apps
  appear to hit Access differently than an HTTP-triggered subrequest.
  Workaround: `scheduled()` only does `fetch('https://maybeit.work/__poll')`
  (a self-fetch), and the real poll+KV-write logic lives behind that
  route instead, so it always runs in a `fetch()` context. If Cloudflare
  ever fixes the underlying behavior, `scheduled()` could poll directly
  again -- not urgent, the self-fetch has no real downside.
