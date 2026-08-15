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

## Outstanding manual steps before first deploy

- `wrangler.toml`'s `[[kv_namespaces]]` `id` is still the literal
  placeholder `REPLACE_AFTER_RUNNING: ...` — no real KV namespace has
  been created yet. Run `wrangler kv namespace create STATUS_KV` with
  real Cloudflare credentials and paste the returned id into
  `wrangler.toml` before merging this branch to `main` —
  `deploy-worker.yml` deploys on every push to `worker/status/**`, and a
  deploy against the placeholder id will fail (or bind to nothing).
- `poll.js`'s Netdata chart/dimension names (`system.cpu`/`idle`,
  `system.ram`/`used`, `disk_space._`/`used`) are unverified guesses —
  no live Netdata instance has confirmed them yet. Confirm against a
  real node's `/api/v1/charts` response before or shortly after first
  production deploy.

## Failure log
