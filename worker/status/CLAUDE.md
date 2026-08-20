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
  `nineW0nW0n/maybeitwork-site`'s `index.html` (own repo, own README; since
  2026-08-21 its docs name this Worker as the deploy path). Self-contained, fonts inlined as `data:` URIs, no CDN, and it
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
  `ctx.waitUntil`. `/status.json` is the page's contract (`src/shape.js`, v2
  since 2026-08-21): `{ polledAt, nodes: [...] }`, nodes ordered from
  `NODE_HOSTS`, never from `Object.entries(snapshot.nodes)`, which
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

This Worker emits **no logs**: `wrangler.toml` has no `[observability]`
block and the deployed settings carry no `observability` key, so the
`cloudflare-observability` MCP returns an empty set for it — absence of
config, not absence of traffic. Debug via `/debug` and `curl`. Turning it
on is two lines plus a redeploy, and buys 7-day retention; it is a
deployed-Worker change, so ask first.

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

Incident histories behind these rules: `failure-log` skill
(`worker/status/`).

- **Verify Netdata chart ids and dimensions against a live node's
  `/api/v1/charts` before wiring them** — two of `poll.js`'s were wrong
  guesses. `system.cpu` has no `idle` dimension here, the root filesystem
  chart keeps the literal `/`, and `system.load`'s dimensions are
  absolute, so `options=percentage` is meaningless on it.
- **No Cron Trigger in this Worker** — no `[triggers]`, no `scheduled()`.
  Anything in a request chain rooted at a Cron Trigger gets 403'd by
  Access however many hops deep, with credentials that work fine from a
  real `fetch()`. Cost: the first `/status.json` after the TTL expires
  waits on live Netdata calls.
- **The status code tells you which layer failed** — vps02's 530s were
  Cloudflare-level (a tunnel that had never connected), not an Access
  403; fixed by rotating the tunnel token and re-running `deploy.yml`.
- **Grep for order-sensitive output from a concurrently-filled object** —
  `page.html` matches status dots to nodes by array index, so building
  that array from `Object.entries(snapshot.nodes)` would have mislabeled
  nodes under network jitter. Build from `NODE_HOSTS.split(',')`.
- **This public Worker holds no credential to the deploy control plane** —
  `pollDokploy` was correct code and still wrong to keep, for a boolean
  the public page never showed; `test/poll.test.js` guards that `pollAll`
  requests no host outside `NODE_HOSTS`. Weigh a credential's blast radius
  against what the call buys, not against whether the call is correct.
  And when a polled origin gains an auth gate, re-check what the poller
  proves: an unauthenticated `GET` follows Access's 302 to a 200 login
  page and stays green forever. (Narrative archived in
  `docs/superpowers/failure-log-archive.md`.)
- **`dokploy.maybeit.work` and each `*-metrics` host are separate Access
  applications,** not one shared app — so a token opening both is a policy
  to narrow, not a fact of life.
- **An empty Zero Trust result set is a credential-scope symptom, not a
  platform limit.** This entry read "Access work is dashboard-only" until
  2026-08-20. Still true: the `wrangler login` token can't read Access
  config, and the API answers an under-scoped token with `success: true`
  and an empty result set rather than a 403 — which is exactly what made
  it look like a platform limit. Now disproven: the `cloudflare-api` MCP's
  credential reads the same endpoints fine (5 apps, their policies, and
  the one `status-worker` service token), and independently confirms the
  detachment claimed above. Never read an empty list as "no Access apps
  configured" — suspect the token's scopes first; curling the hostname for
  the `302` stays a valid cross-check. Try a second credential before
  writing down "the platform can't do this".
- **Verify a named check exists before citing it, and re-read every
  comment about `page.html` when you re-copy it** — `index.js` claimed the
  page never used `innerHTML` and that `scripts/check-rails.sh` enforced
  it; both were false for months. The grep is real now and wired into
  `.pre-commit-config.yaml`. After deploying a re-copy, prove it landed
  rather than trusting the green run: the deployed page ships as its own
  module part named by its plain SHA-1, so
  `git cat-file blob <ref>:worker/status/src/page.html | shasum -a 1` must
  equal it. Pin an explicit ref; hashing the working tree measures shared
  mutable state and has already produced two disagreeing answers in one
  session. Mechanism in `tooling-setup`.
