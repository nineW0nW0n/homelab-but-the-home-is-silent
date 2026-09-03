Parent: ../../.claude/CLAUDE.md

# worker/status/: maybeit.work status dashboard (Cloudflare Worker)

Serves three static files at the `maybeit.work` apex: the status page,
`/privacy` and `/terms`. **The poller retired 2026-09-03** (phoenixlab
step 17, section 0): monitoring moved to the private Beszel hub, so this
Worker polls nothing, reads no KV, and holds no secrets. `/status.json`
and `/debug` went with it. Deliberately **not** deployed to a VPS; the
design spec says why
(`docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`).

## Layout

- `src/page.html`: the designed front-end, a straight committed copy of
  `nineW0nW0n/maybeitwork-site`'s `index.html` (own repo, own README; since
  2026-08-21 its docs name this Worker as the deploy path). Self-contained,
  fonts inlined as `data:` URIs, no CDN. It still fires one
  `GET /status.json` on load (800ms abort, no auto-refresh); see below for
  what that renders now. Served byte-for-byte through a Wrangler `Text`
  module rule (`import page from './page.html'`), no server templating.
  Copy-paste, not a submodule: one static file doesn't justify the
  ceremony.
- `src/index.js`: returns `privacy.html` at `/privacy`, `terms.html` at
  `/terms`, and `page.html` for every other path — `/status.json`
  included, **deliberately**. The page's DATA CONTRACT (in `page.html`)
  swallows any bad `/status.json` response silently and renders its
  hardcoded `SERVICES` fallback, whose values all quantize into the green
  1-7 band — so with the poller gone, no node ever renders as down. The
  alternative (a JSON route serving zeros, or nothing) renders dead dots:
  the page has no "unknown" state, only dead (0), ok (1-7) and bad (8-10).
  Changing what the page shows means editing the vendored file in its own
  repo and re-copying, not templating here.
- `src/privacy.html`, `src/terms.html`: static legal pages at `/privacy`
  and `/terms`, served through the same Text module rule and the same
  `PAGE_HEADERS`. They exist because Google's OAuth consent screen refuses
  to leave Testing status without a reachable privacy policy and terms of
  service, and the zone-wide "Block non-local traffic" rule exempts only
  the apex -- so they cannot live on `gws.maybeit.work` (see
  `stacks/vps00/CLAUDE.md`). A later phoenixlab step rebuilds the Google
  Workspace MCP server with a fresh consent flow, so these routes are a
  precondition for that, not decoration. Keep them true: they describe
  gws-mcp as a single-user app whose Google data stays on the owner's own
  node, and Google reads them if verification is ever triggered.
- No tests and no `test/` directory: the only importable modules
  (`poll.js`, `status-json.js`, `debug-auth.js`) retired with the poller,
  and `index.js` can't be imported under plain Node (it pulls `page.html`
  through the Text rule). `deploy-worker.yml` runs `npm ci` only to pin
  wrangler to package-lock's version.

## Public exposure

The apex is deliberately **public**, no Cloudflare Access in front of it.
With the poller gone there is no upstream a visitor can generate load on;
what remains to bound is Worker invocations, and `cache-control` does
that: the page carries `max-age=300`, so ordinary refreshes come from the
browser instead of burning free-tier requests. A cache-bypassing attacker
needs a zone-level Cloudflare Rate Limiting rule, which is dashboard
config, not code.

## Local dev

`npm install`, `npx wrangler dev`, hit `http://localhost:8787/`. The page
fetches `/status.json`, receives the HTML shell, and falls back to its
hardcoded `SERVICES` values — that is the production behavior too, not a
dev artifact.

Workers Logs are **on** (7-day retention): `wrangler.toml` has had
`[observability] enabled = true` since 2026-08-20, so the
`cloudflare-observability` MCP can see this Worker's traffic.

## Deploy

No Worker secrets exist anymore. `deploy-worker.yml` is `npm ci` then
`wrangler deploy`, gated by `environment: production` on its single deploy
job (rail 7): a run sitting at "Waiting" is Ex's approval pending, not a
stuck job. If a `secrets:` block ever returns to that workflow, remember
`wrangler-action` **fails the whole deploy** when a name under it has no
value in `env:` — create the repo secret first, then add the reference.

## Failure log

Incident histories behind these rules: `failure-log` skill
(`worker/status/`). Four poller-era entries (Netdata chart ids, the
no-Cron-Trigger rule, which-layer-failed-by-status-code, and
order-sensitive output from a concurrently-filled object) are archived in
full in `docs/superpowers/failure-log-archive.md` — the poller they
governed no longer exists.

- **Weigh a credential's blast radius against what the call buys, not
  against whether the call is correct** — `pollDokploy` was correct code
  and still wrong to keep, for a boolean the public page never showed.
  As of 2026-09-03 this public Worker holds no credential at all.
  (Narrative archived in `docs/superpowers/failure-log-archive.md`.)
- **Each ops hostname (`siem`, each `*-metrics`; formerly `dokploy`) is
  its own Access application,** not one shared app — so a token opening
  both is a policy to narrow, not a fact of life.
- **An empty Zero Trust result set is a credential-scope symptom, not a
  platform limit.** This entry read "Access work is dashboard-only" until
  2026-08-20. Still true: the `wrangler login` token can't read Access
  config, and the API answers an under-scoped token with `success: true`
  and an empty result set rather than a 403 — which is exactly what made
  it look like a platform limit. Now disproven: the `cloudflare-api` MCP's
  credential reads the same endpoints fine. Never read an empty list as
  "no Access apps configured" — suspect the token's scopes first; curling
  the hostname for the `302` stays a valid cross-check. Try a second
  credential before writing down "the platform can't do this".
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
- **When a config value flips, grep this file for the old claim in the
  same commit.** The Local dev section said "this Worker emits no logs, no
  `[observability]` block" for two weeks after `wrangler.toml` gained
  exactly that block (2026-08-20; caught 2026-09-03). Same lesson as
  root's "assert effective values": a doc is not the config it describes.
