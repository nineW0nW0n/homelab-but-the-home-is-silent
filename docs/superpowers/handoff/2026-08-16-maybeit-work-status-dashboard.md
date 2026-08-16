# Handoff — maybeit.work status dashboard

> **Commit SHAs in this document are dangling (2026-08-16).** History was
> rewritten with `git filter-repo` to remove real node IPs and
> force-pushed, so every SHA recorded before that rewrite no longer
> resolves. Search by commit *message* instead. The work itself is
> unaffected; only the identifiers moved.


**State as of 2026-08-16:** feature merged locally to `main` (commit
`29cbfb8`), **not pushed**. Nothing is live yet — no Netdata container
running anywhere, Worker not deployed, KV namespace exists but empty.

## What's done

- Netdata as a Docker service on all 3 nodes (`stacks/vps00,01,02/`),
  vps02 gained its first `cloudflared` tunnel.
- Telegram alerting config (`health_alarm_notify.conf.template` +
  `deploy.yml` render step), default Netdata thresholds still in
  effect — tightening was scoped out, documented as deferred
  (`stacks/CLAUDE.md`), not a blocker.
- Cloudflare Tunnel routes + Access apps — **live in the dashboard
  already**, done via browser automation this session, verified with
  unauthenticated curls (all 3 `<node>-metrics.maybeit.work` return
  302 to Access login): `vps00-metrics`, `vps01-metrics`,
  `vps02-metrics`, each with 2 policies (Service Auth for
  `status-worker` token, Allow for the account owner's email).
- Cloudflare Workers KV namespace `STATUS_KV` created live
  (`8fbd60e3276e4a40a63609f9ed56e1fd`), real id committed in
  `worker/status/wrangler.toml`.
- Worker code (`render.js`, `poll.js`, `index.js`) + `deploy-worker.yml`
  CI, all tests passing (9/9), Biome now gated in `.pre-commit-config.yaml`.
- GitHub secrets confirmed present (added this session via browser,
  values never seen by the assistant): `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`,
  `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`.

## Not yet done — next steps, in order

1. **Verify GitHub secrets before pushing.** Confirmed present this
   session: the 3 above. **Not confirmed this session:**
   `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` — check
   `github.com/nineW0nW0n/homelab-but-the-home-is-silent/settings/secrets/actions`;
   if missing, `deploy.yml`'s Telegram render step will silently write
   an empty token (Minor finding from the final review, still valid).
   Also sanity-check `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`
   exist (they're listed as required in `.github/workflows/CLAUDE.md`
   but `deploy-worker.yml` is their first real consumer).

2. **Push `main` to origin.** This is production-touching — fires
   `deploy.yml` (Netdata containers go live on vps00-02, sequential)
   and `deploy-worker.yml` (Worker deploys for the first time). Get
   explicit go-ahead before this, then watch both Action runs.

3. **Verify `poll.js`'s Netdata dimension names against a real node**
   (Important #5 from the final review — this is the "prep for next
   session" item). Can't be done until step 2 lands. Once Netdata is
   live:
   ```
   curl -H "CF-Access-Client-Id: <id>" \
        -H "CF-Access-Client-Secret: <secret>" \
        https://vps00-metrics.maybeit.work/api/v1/charts | jq
   ```
   Confirm chart/dimension ids for CPU idle %, RAM used, and root disk
   usage actually match what `worker/status/src/poll.js`'s `pollNode`
   hardcodes: `system.cpu`/`idle`, `system.ram`/`used`,
   `disk_space._`/`used`. If any differ, edit `poll.js`, re-run
   `node --test` in `worker/status/`, commit, push (path-scoped, only
   triggers `deploy-worker.yml`, not the full node deploy).

4. **Confirm the page renders live data.** Wait one cron tick (~5 min)
   after Worker deploy, then load `https://maybeit.work` — expect the
   status table, not "no data yet."

## Useful references

- Cloudflare account id: `acb24619a369506235663e8cb25e7d1f`, Zero
  Trust team name `old-firefly-996b` (from the Access login redirect
  hostname) — use these to jump straight to the right dashboard pages.
- Spec: `docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`
  (has an "Implementation update" note at the top — read that first).
- Plan: `docs/superpowers/plans/2026-08-15-maybeit-work-status-dashboard.md`.
- Worker code: `worker/status/` (own `CLAUDE.md` there).

## Note on process history

This feature was built via subagent-driven-development in a worktree;
the SDD execution ledger (`.superpowers/sdd/.../progress.md`, every
task's review verdict, the final whole-branch review's full findings
list, and the fix-wave verification) lived in that worktree's
gitignored scratch dir and was **not** preserved — the worktree was
removed as part of merging. The code state itself reflects every
finding that was addressed (see git log on `main` from
`e25dc68`..`29cbfb8`); only the meta-commentary is gone. If a detailed
post-mortem of that process is ever needed, it isn't recoverable from
disk — the conversation transcript is the only record.
