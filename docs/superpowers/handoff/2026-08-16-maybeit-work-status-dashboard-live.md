# Handoff — maybeit.work status dashboard, post-push

**State as of 2026-08-16 (later same day):** `main` pushed to origin
(`1da5dec`, was `e25dc68..1da5dec`, 27 commits). Netdata is **live on
all 3 nodes**, and the Worker is **live and routed to `maybeit.work`**
— both blockers below were hit and fixed this session. See "Push
results" for what broke and how it was fixed.

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

Run IDs: `deploy` 31919749826, `Deploy Worker` 31919749732, `validate`
31919749606
(`gh run view <id> --repo nineW0nW0n/homelab-but-the-home-is-silent`).

- [x] `validate.yml`: **success**.
- [x] `deploy.yml`: **success**. Netdata containers are live on
      vps00-02, sequential rollout completed clean.
- [x] `Deploy Worker`: **success**, after 2 rounds of fixing
      infra gaps this session (see below). Worker is live and routed to
      `maybeit.work`.

### Deploy Worker — two blockers hit and fixed this session

**Blocker 1 — route attach failed.** First run: `wrangler deploy`
uploaded the Worker fine (bindings live: `env.STATUS_KV`,
`env.NODE_HOSTS`, `env.DOKPLOY_HOST`; secrets
`CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET` created), but failed
attaching the route:
```
✘ A request to the Cloudflare API (/zones/9a13fac38c7078e576ed3260f9df9591/workers/routes) failed.
  Authentication error [code: 10000]
```
Cause: `CLOUDFLARE_API_TOKEN` had account-level Worker-deploy
permission but not `Zone > Workers Routes > Edit` scoped to
`maybeit.work`. Fixed via Cloudflare dashboard (browser automation,
with Ex's go-ahead): added a policy to the token
(`falling-resonance-af51`) — Specified Domain `maybeit.work` →
Developer Platform → Workers Routes → Edit.

**Blocker 2 — no workers.dev subdomain.** Re-ran, route attach
succeeded this time, but the cron-trigger step then failed:
```
- A request to the Cloudflare API (/accounts/***/workers/scripts/maybeit-status/schedules) failed.
  - You need a workers.dev subdomain in order to proceed. [code: 10063]
```
Cause: the account had never opened the Workers dashboard, so no
`workers.dev` subdomain existed yet (first-visit auto-provisions one).
Fixed by visiting `dash.cloudflare.com/<account>/workers-and-pages`
once in browser — subdomain `abcollado-28.workers.dev` was created
automatically. Re-ran, **green**.

If this ever needs redoing on a fresh Cloudflare account: visit the
Workers & Pages dashboard page once before the first `wrangler deploy`
that includes a cron trigger, and make sure the deploy token has
`Zone > Workers Routes > Edit` for every zone it needs to route.

## Not yet done — next steps, in order

1. ~~Verify `poll.js`'s Netdata dimension names against a real
   node~~ — **done this session.** Checked vps00's live
   `/api/v1/charts` via browser (Cloudflare Access SSO, no service
   token needed). Two of three were wrong:
   - `system.cpu` has **no `idle` dimension** in this deployment's
     config — only busy-state ones (`user`, `system`, `nice`,
     `iowait`, `irq`, `softirq`, `steal`, `guest`, `guest_nice`), which
     already sum to the busy percentage.
   - Root disk chart id is `disk_space./` (literal `/`), not
     `disk_space._` as guessed.
   - `system.ram`/`used` was correct as guessed.

   Fixed in `poll.js` (`d8a8c39`): CPU now sums the busy-state
   dimensions, with a fallback to `100 - idle` if a Netdata config does
   report one. Disk chart id corrected. New test covers the no-`idle`
   shape. `node --test` in `worker/status/`: 10/10 pass. Pushed —
   watch `deploy-worker.yml` for this path-scoped run before trusting
   the live page's numbers.

2. **Confirm the page renders live data.** Wait one cron tick (~5 min)
   after `Deploy Worker` succeeded, then load `https://maybeit.work` —
   expect the status table, not "no data yet."

3. **Sanity-check Telegram alerting end-to-end.** The bot
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
