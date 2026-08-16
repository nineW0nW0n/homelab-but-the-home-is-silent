# Handoff — maybeit.work status dashboard, post-push

**State as of 2026-08-16 (later same day):** `main` pushed to origin
(`1da5dec`, was `e25dc68..1da5dec`, 27 commits). Netdata is **live on
all 3 nodes**. The Worker deploy **partially failed** — code is
uploaded but not routed to `maybeit.work` yet. See "Push results"
below.

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
- [ ] `Deploy Worker`: **failed**, but partially landed — read on.

### Deploy Worker failure — root cause and fix

The Worker code itself deployed fine: `wrangler deploy` uploaded
`maybeit-status`, bindings are live (`env.STATUS_KV`,
`env.NODE_HOSTS`, `env.DOKPLOY_HOST`), secrets
(`CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET`) were created. It
failed on the **next** step, attaching the route:

```
✘ A request to the Cloudflare API (/zones/9a13fac38c7078e576ed3260f9df9591/workers/routes) failed.
  Authentication error [code: 10000]
```

Cause: `CLOUDFLARE_API_TOKEN` has account-level Worker-deploy
permission but not `Zone > Workers Routes > Edit` scoped to the
`maybeit.work` zone. **This is why the site still won't route to the
Worker** — it exists at `maybeit-status.<subdomain>.workers.dev` but
`maybeit.work` itself isn't wired to it.

Fix (needs Ex, credential change, not done by the assistant): in the
Cloudflare dashboard, My Profile → API Tokens → edit the token used
for `CLOUDFLARE_API_TOKEN` → add `Zone > Workers Routes > Edit` scoped
to `maybeit.work` → Save. Then re-run just the Worker deploy:
```
gh run rerun 31919749732 --repo nineW0nW0n/homelab-but-the-home-is-silent
```
(or push a trivial change under `worker/status/` to retrigger
path-scoped). Confirm green before moving to step 2 below.

## Not yet done — next steps, in order

1. **Fix the `CLOUDFLARE_API_TOKEN` permission and get `Deploy Worker`
   green** (see above). Blocks everything else — `maybeit.work` has no
   Worker attached until this lands.

2. **Verify `poll.js`'s Netdata dimension names against a real node**
   (only once `deploy.yml` succeeded and Netdata containers are
   actually up):
   ```
   curl -H "CF-Access-Client-Id: <id>" \
        -H "CF-Access-Client-Secret: <secret>" \
        https://vps00-metrics.maybeit.work/api/v1/charts | jq
   ```
   Confirm chart/dimension ids for CPU idle %, RAM used, and root disk
   usage match what `worker/status/src/poll.js`'s `pollNode` hardcodes:
   `system.cpu`/`idle`, `system.ram`/`used`, `disk_space._`/`used`. If
   any differ, edit `poll.js`, re-run `node --test` in
   `worker/status/`, commit, push (path-scoped — only re-triggers
   `deploy-worker.yml`, not the full node deploy).

3. **Confirm the page renders live data.** Wait one cron tick (~5 min)
   after `Deploy Worker` succeeded, then load `https://maybeit.work` —
   expect the status table, not "no data yet."

4. **Sanity-check Telegram alerting end-to-end.** The bot
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
