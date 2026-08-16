# Handoff — maybeit.work status dashboard, post-push

**State as of 2026-08-16 (later same day):** `main` pushed to origin
(`1da5dec`, was `e25dc68..1da5dec`, 27 commits, plus several more this
session fixing what the push surfaced). **The dashboard is fully live**
— `https://maybeit.work` shows all 3 nodes + dokploy green with real
cpu/mem/disk numbers. This took 5 separate bugs found and fixed after
the push; see "Push results" for the full chain.

This supersedes `2026-08-16-maybeit-work-status-dashboard.md` (the
pre-push handoff) for "what's next" purposes; keep that file too, it
has the full feature history and Cloudflare account references.

## What changed since the pre-push handoff

- Confirmed `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` were **missing**
  from GitHub secrets (step 1 of the prior handoff). Fixed by creating
  a new Telegram bot (`@maybeitwork_status_bot`, via BotFather, no
  pre-existing bot) and adding both secrets through the GitHub web UI
  via browser automation. `gh secret list` confirms both present.
- `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` were already present
  — no action needed.
- Pushed `main` → origin, triggering `deploy.yml`, `deploy-worker.yml`,
  and `validate.yml` together.

## Push results

Run IDs (first of several deploy-worker.yml runs that session, others
in git log): `deploy` 31919749826, `Deploy Worker` 31919749732,
`validate` 31919749606
(`gh run view <id> --repo nineW0nW0n/homelab-but-the-home-is-silent`).
All 3 workflows ended green — `validate.yml` and `deploy.yml` (Netdata
live on vps00-02) passed clean on the first try; `Deploy Worker` took
several rounds, detailed below.

If any of this ever needs redoing on a fresh Cloudflare account: visit
the Workers & Pages dashboard page once before the first `wrangler
deploy`, and make sure the deploy token has `Zone > Workers Routes >
Edit` for every zone it needs to route.

## Everything hit and fixed after the push, in order

1. **`poll.js`'s Netdata dimension names were wrong.** Checked vps00's
   live `/api/v1/charts` via browser (Cloudflare Access SSO). Two of
   three guesses were wrong: `system.cpu` has **no `idle` dimension**
   in this deployment's config (only busy-state ones, which already
   sum to the busy percentage), and the root disk chart id is
   `disk_space./` (literal `/`), not `disk_space._`. `system.ram`/`used`
   was correct as guessed. Fixed in `poll.js` (`d8a8c39`) — CPU now
   sums busy-state dimensions with a fallback to `100 - idle` for
   configs that do report it. New test covers the no-`idle` shape.

2. **`CLOUDFLARE_API_TOKEN` missing `Zone > Workers Routes > Edit`.**
   First `Deploy Worker` run uploaded the Worker fine but failed
   attaching the route to `maybeit.work` (`Authentication error [code:
   10000]`). Fixed via Cloudflare dashboard: added a policy to the
   token (`falling-resonance-af51`) scoped to `maybeit.work` →
   Developer Platform → Workers Routes → Edit.

3. **No `workers.dev` subdomain existed yet.** Route attach then
   succeeded, but the cron-trigger step failed (`[code: 10063]`) since
   the account had never opened the Workers dashboard once. Fixed by
   visiting `dash.cloudflare.com/<account>/workers-and-pages` once —
   auto-provisioned `abcollado-28.workers.dev`.

4. **`CF_ACCESS_CLIENT_ID`/`SECRET` never actually authenticated.**
   `status-worker` Access service token showed "Not Seen Yet" even
   after both blockers above were fixed. Rotated the token secret
   (kept the same Client ID) via Cloudflare dashboard, updated both
   GitHub secrets. Confirmed working via direct curl and via a
   `fetch()`-triggered request.

5. **Cloudflare Cron Triggers can't poll this account's own
   Access-protected apps — at all.** Even with the token from #4
   confirmed working, `scheduled()` calling the poll directly got a 403
   from Access on every tick. Tried routing it through a self-fetch (so
   the real poll ran inside a nested `fetch()` invocation) — still
   403'd at the next real tick, despite manually triggering that same
   route from outside Cloudflare working every time. Root cause is
   Cloudflare-side and unconfirmed; anything in a request chain rooted
   at a Cron Trigger gets hit, not just the top-level handler. **Fix:
   dropped Cron Triggers entirely.** No `[triggers]` in `wrangler.toml`,
   no `scheduled()` handler — `fetch()` polls fresh on every page load
   instead. Trade-off (page load waits on live Netdata + Dokploy calls)
   accepted deliberately, per Ex, for a low-traffic status page. Full
   writeup: `worker/status/CLAUDE.md` failure log.

6. **vps02's Cloudflare Tunnel had never connected once.** Dashboard
   showed `Inactive` / 0 replicas; Netdata calls to vps02 got a 530
   (Cloudflare-level, not Access — a different bug from #4). Root cause
   likely a bad token paste when it was first set. Fixed by rotating
   the tunnel token in the Cloudflare dashboard, updating
   `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, and re-running `deploy.yml`.
   Confirmed healthy (1 active replica) after.

**Verified live:** `https://maybeit.work` shows all 3 nodes 🟢 with real
cpu/mem/disk numbers, plus dokploy 🟢, confirmed after every fix above
landed.

## Not yet done

1. **Sanity-check Telegram alerting end-to-end.** The bot
   (`@maybeitwork_status_bot`) exists and the chat id is your personal
   account (`6637564124`, from `Ash Collado`'s Telegram). Default
   Netdata alert thresholds are still in effect (tightening was scoped
   out, see `stacks/CLAUDE.md`) — no easy way to trigger a real alert
   without stressing a node, so this may just mean waiting for an
   organic alert rather than manufacturing one.

## Useful references

- Cloudflare account id: `acb24619a369506235663e8cb25e7d1f`, Zero Trust
  team name `old-firefly-996b`.
- Telegram bot: `@maybeitwork_status_bot`, created this session via
  BotFather. Token is in the `TELEGRAM_BOT_TOKEN` GitHub secret only —
  not recorded here.
- Spec: `docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`.
- Plan: `docs/superpowers/plans/2026-08-15-maybeit-work-status-dashboard.md`.
- Worker code: `worker/status/` (own `CLAUDE.md` there).
- Prior handoff (full feature history, pre-push):
  `docs/superpowers/handoff/2026-08-16-maybeit-work-status-dashboard.md`.
