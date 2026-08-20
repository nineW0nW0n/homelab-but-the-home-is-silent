Parent: ../../.claude/CLAUDE.md

# worker/status/: maybeit.work status dashboard (Cloudflare Worker)

Serves the status page at the `maybeit.work` apex. No Cron Trigger and no
`scheduled()` handler, deliberately (see failure log): polling happens
inside `fetch()`, on a `/status.json` request, and only when the KV
snapshot is older than `POLL_TTL_MS`. Deliberately **not** deployed via
Dokploy/VPS; the design spec says why
(`docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`).

## Layout

- `src/page.html`: the designed front-end, a straight committed copy of
  `nineW0nW0n/maybeitwork-site`'s `index.html` (own repo, own README; that
  repo's "Deploy: GitHub → Dokploy" line is stale, this Worker is the real
  deploy path). Self-contained, fonts inlined as `data:` URIs, no CDN, and it
  pulls its own data: one `GET /status.json` on load, 800ms abort, no
  auto-refresh; its DATA CONTRACT comment has the shape. Served byte-for-byte
  through a Wrangler `Text` module rule (`import page from './page.html'`),
  no server templating. Copy-paste, not a submodule: one static file doesn't
  justify the ceremony.
- `src/poll.js`: polls each node's Netdata API through the Access-gated
  tunnel routes; `fetch` injectable so tests never hit the network. Owns
  `POLL_TTL_MS` (30s) and `isFresh`. Does **not** poll Dokploy, removed
  2026-08-20, see the blast-radius entry.
- `src/index.js`: returns `page.html` for every path except `/status.json`
  and `/debug`, with no KV read and no poll (the shell needs no data). Those
  two read the KV snapshot, re-poll only if stale, write back via
  `ctx.waitUntil`. `/status.json` is the page's contract: 3 nodes ordered
  from `NODE_HOSTS`, never from `Object.entries(snapshot.nodes)`, which
  `pollAll` fills from concurrent promises so insertion order isn't
  guaranteed to match. `/debug` is the raw snapshot, key-gated.
- `src/debug-auth.js`: `isDebugAuthorized`, kept out of `index.js` so
  `node --test` can import it (`index.js` pulls `page.html` through the Text
  rule, which plain Node can't resolve). `npm test` is `node --test`, no
  framework; `deploy-worker.yml` runs it before `wrangler deploy`.
- No dokploy anywhere: `page.html` hardcodes exactly 3 status-dot slots, one
  per VPS node, and the poll behind it is gone. Check Dokploy by loading
  `dokploy.maybeit.work`.

## Public exposure

The apex is deliberately **public**, no Cloudflare Access in front of it,
unlike the `*-metrics` and `dokploy` hostnames. Two things bound what a
visitor can cost. `POLL_TTL_MS` (30s, `poll.js`) caps upstream polling, so
traffic volume can't become load on the nodes: a snapshot inside the TTL is
served from KV without touching Netdata. `cache-control` caps Worker
invocations: `/status.json` carries `max-age` equal to the poll TTL and the
page `max-age=300`, so ordinary refreshes come from the browser instead of
burning free-tier requests and KV reads, while `/debug` is `no-store`
because it is key-gated and a cached copy could outlive a rotated key.
Neither stops an attacker who bypasses caches; that needs a zone-level
Cloudflare Rate Limiting rule, which is dashboard config, not code, and the
nodes stay protected by the poll TTL regardless. Do not add a `setInterval`
to `page.html` without revisiting both numbers.

## Local dev

`npm install`, `npx wrangler dev`, hit `http://localhost:8787/`. The page
fetches `/status.json` itself, which polls live unless a snapshot inside the
30s TTL already sits in KV.

## Secrets and deploy

`CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`: the Cloudflare Access
service token from the design's dashboard step, set via `wrangler secret
put`, never in this directory. Since 2026-08-20 it opens the `*-metrics`
applications only — its `status-worker service auth` policy was detached
from the `dokploy.maybeit.work` application, so leaking this Worker's
secrets no longer reaches the deploy control plane.

`DEBUG_KEY`: shared header value gating `/debug`, sent as `x-debug-key`, and
pushed by `deploy-worker.yml` from the GitHub secret of the same name. Unset
means the route 404s for everyone — it fails closed, so a missing or
rolled-back secret can never leave `/debug` public; a wrong key gets 404 too,
never confirming the route exists. Ex's copy is at `~/.maybeit-debug-key`.

Worker deploys are gated: `deploy-worker.yml` carries `environment:
production` on its single deploy job (rail 7), so a run sitting at "Waiting"
is Ex's approval pending, not a stuck job. And `wrangler-action` **fails the
whole deploy** if a name under `secrets:` has no value in `env:` ("Value for
secret X not found in environment") — create the repo secret first, then add
the workflow reference.

## Failure log

- Verify Netdata chart ids against the live node; two of `poll.js`'s were
  wrong guesses at first deploy, caught against vps00's `/api/v1/charts`
  (2026-08-16). `system.cpu` has no `idle` dimension in this deployment, so
  `queryCpuBusyPercent` sums the busy-state dimensions, falling back to
  `100 - idle` where a config does report one. The root filesystem chart id
  keeps the literal `/` (`disk_space./`), not `_` as guessed.
  `system.ram`/`used` was right.
- `system.load`'s dimensions (load1/load5/load15) are each an absolute load
  average and don't sum to a whole, unlike `system.ram`/`mem.swap`, so
  `options=percentage` is meaningless there — hence `queryRaw` vs
  `queryPercent`, confirmed against a live node before wiring. load1 becomes
  a 0-100 score by dividing by `NODE_VCPUS` (2, this homelab's fixed spec)
  and clamping.
- Cloudflare Cron Triggers can't reliably poll this account's own
  Access-protected Netdata apps. With a confirmed-working
  `CF_ACCESS_CLIENT_ID`/`SECRET`, `scheduled()` calling `pollAll` got a 403
  from Access on every Netdata call, every tick, while the identical call
  from a real HTTP-triggered `fetch()` worked every time. Making
  `scheduled()` self-fetch `/__poll`, so the poll ran inside a nested
  `fetch()`, **didn't work either**: still 403 next tick, though plain curl
  to `/__poll` from outside Cloudflare always worked. So it isn't handler
  type — anything in a request chain rooted at a Cron Trigger gets hit,
  however many hops deep. Root cause unconfirmed (Cloudflare-side, nothing
  in this repo to dig with). Fix: no Cron Trigger, no `[triggers]` in
  `wrangler.toml`, no `scheduled()`. Trade-off accepted: the first
  `/status.json` after the TTL expires waits on live Netdata calls. The KV
  write has two jobs now, backing the `POLL_TTL_MS` freshness cache and
  carrying `lastSeen` forward so a node that's down right now still shows
  when it was last up. (Pre-TTL wording "polls fresh on every page load"
  archived 2026-08-20 in `docs/superpowers/failure-log-archive.md`; false
  once the TTL landed.)
- vps02's tunnel showed `Inactive` / 0 replicas: cloudflared there had never
  once connected, and Netdata calls returned 530 — Cloudflare-level, not an
  Access 403, and the status code is what tells you which layer failed.
  Fixed by rotating the token (dashboard → Tunnels → vps02-metrics → Rotate
  token), updating `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, re-running
  `deploy.yml`; healthy at 1 replica after. The bad token is unexplained,
  likely a bad paste when a human first set it.
- Grep for order-sensitive output from a concurrently-filled object whenever
  one shows up. `page.html` matches status dots to nodes by **array index**,
  not name (`SERVICES.forEach((s, i) => ...d${i}/v${i}...)`), and the first
  `toStatusJson` built its array from `Object.entries(snapshot.nodes)` —
  fine locally, but `pollAll` fills that object from concurrent per-node
  promises, so a slow vps00 poll landing after a fast vps01 one would have
  silently mislabeled a node's stats under real network jitter. Fixed by
  building from `NODE_HOSTS.split(',')`.
- Weigh a credential's blast radius against what the call buys, not against
  whether the call is correct. `pollDokploy` was correct by the end (service
  token, `redirect: 'manual'`, explicit 2xx test) and still wrong to keep: a
  public internet Worker holding a credential to the **deploy control plane**
  for an up/down boolean `toStatusJson`'s allowlist kept off the public page
  entirely, surfacing only in `/debug`, which only Ex can open. Leaking the
  Worker's secrets meant full infra access, not a CPU graph. Removed
  2026-08-20 with `DOKPLOY_HOST`, token dropped from the Dokploy Access
  policy, and `test/poll.test.js` guards it: `pollAll` must request no host
  outside `NODE_HOSTS`, with `DOKPLOY_HOST` still set in that test's env so a
  stale var can't revive it. Its earlier shape's lesson is worth keeping for
  any future poller: it did an unauthenticated `GET` with
  `up = res.status < 500`, and the runtime follows the Access `302` to a
  `200` login page, so the tile would have stayed green forever. When a
  polled origin gains an auth gate, re-check what the poller proves — "up"
  must mean the origin answered, not its login page. (Narrative archived 2026-08-20 in
  `docs/superpowers/failure-log-archive.md`.)
- `dokploy.maybeit.work` and each `*-metrics` host are **separate** Access
  applications, not one shared app: confirmed 2026-08-20 by their distinct
  `aud`/`kid` in the login redirect. A `poll.js` comment claimed they shared
  one, which is why a single token opening both read as unavoidable rather
  than as a policy that needed narrowing.
- The `wrangler login` OAuth token can't read or write Access config, and the
  Zero Trust API returns `success: true` with an **empty result set** rather
  than a 403. Never read that as "no Access apps configured" — curl the
  hostname and look for the `302` to `<team>.cloudflareaccess.com`. Access
  work is dashboard-only.
- A comment asserting a security invariant is worthless unless something
  checks it: `index.js`'s `PAGE_HEADERS` comment claimed `page.html` "writes
  data with textContent, never innerHTML" while the vendored page did use
  `innerHTML` for the metric readout. The site repo's
  `scripts/check-rails.sh` greps for markup sinks now. When you re-copy
  `page.html`, re-read every comment here that claims something about its
  contents — the copy can falsify them silently.
