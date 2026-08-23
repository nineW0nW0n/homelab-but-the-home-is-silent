Parent: ../../.claude/CLAUDE.md

# .github/workflows/: CI/CD

`validate.yml` (lint gate), `deploy.yml` (parallel deploy to the three
nodes), `deploy-worker.yml` (the `maybeit.work` status Worker: `npm test`
then `wrangler deploy`, entirely separate from the node deploy path; see
`worker/status/CLAUDE.md`).

## Flow

1. `validate.yml` runs on every PR and push to `main`: `pre-commit run
   --all-files --show-diff-on-failure` (yamllint --strict, actionlint,
   gitleaks, shellcheck, trailing-whitespace, large-file/private-key
   checks, plus three local hooks: `no-real-ips`, `check-rails` — which
   mechanically asserts rail 7, this directory's own rail, by requiring
   every deploying job to carry `environment: production` or `needs:` a job
   that does — and `biome ci`). Also
   callable via `workflow_call`; both deploy workflows call it first (rail
   8).
2. `deploy.yml` runs on push to `main` (paths: `stacks/**`, itself) or
   manual dispatch. The `approve` job carries one step beyond the gate:
   **Reject secrets a dotenv parser would mangle**, which reads every
   secret that lands in a `.env`, `.r2.env` or `.telegram.env` and fails
   the run before any node is touched if one contains `#`, `$`, a quote,
   a backslash, a backtick, or edge whitespace. It prints names, never
   values. The same step also checks the two OpenObserve passwords
   against OpenObserve's own startup policy (8-128 characters, lower,
   upper, digit, and one of `! @ % - _`), because it panics rather than
   complains and the symptom is a crashloop that never names the
   password. It lives here because all three deploys `needs:` this job,
   so one copy covers the run. `concurrency: deploy-production`, `cancel-in-progress:
   false`: a second push queues, doesn't abort a deploy in flight. A single
   `approve` job holds the `production` environment and the three deploy
   jobs `needs:` it, so one approval covers the run and all three nodes
   deploy in parallel (rail 7). Do not put `environment: production` back
   on the deploy jobs: GitHub prompts once per job, which is what made this
   three clicks.
3. Per node: SSH key via `webfactory/ssh-agent`, `known_hosts` pinned from
   the `SSH_KNOWN_HOSTS` secret (never `StrictHostKeyChecking no`), `mkdir
   -p` the remote stack dir, `rsync -az --delete` the stack files, write
   that node's tunnel token and Netdata claim values into a remote `.env`
   (piped over SSH stdin under `umask 077`, never a CLI arg, never
   committed), then `docker compose pull && up -d && image prune -f &&
   restart netdata vector`, guarded: no services in the stack, skip
   pull/up instead of erroring (failure log). The trailing `restart` is
   needed because a bind-mounted config file -- `netdata.conf`,
   `health_alarm_notify.conf`, `vector.yaml` -- is not part of the
   container spec, so changing it does not force a recreate and `up -d`
   leaves the old process running with the old file. `vector` joined that
   list after a deploy shipped a fixed `vector.yaml` and changed nothing:
   the only reason it took effect was that the container happened to be
   crashlooping and picked the new file up on its next restart.
4. vps01 only: the rsync excludes `backup/`, `backup-booking/`, `.r2.env`,
   `.telegram.env` (failure log), two extra steps write those two
   credential files, and one brace group piped to `crontab -` installs all
   four entries at once because `crontab -` **replaces** the whole crontab.
   All four fire hourly, because Debian's cron ignores `CRON_TZ` — but only
   the two *backups* self-gate on their own Asia/Manila hour (03:00, 04:00).
   The two staleness checks are **ungated** and run every hour, which is
   exactly why `.r2.env`/`.telegram.env` must be rsync-excluded: see the
   failure log below, where a deploy overlapping the `:30` check made it
   exit 1.
5. Each deploy job ends with `Verify vps0N`, checking the node's own origin
   over the SSH connection it already holds: Netdata answers 200 on
   loopback, `cloudflared-vps0N` is running, and on vps01 both apps answer
   200 through Traefik with a `Host:` header. Every HTTP probe polls, 30
   tries 2s apart. It reports and fails; it never reverts.
6. `deploy-worker.yml`: push to `main` (paths: `worker/status/**`, itself)
   or dispatch, `concurrency: deploy-worker`. One deploy job, so it
   satisfies rail 7 with `environment: production` **on that job
   directly**; `deploy.yml` needs a separate `approve` job only because
   three parallel jobs would prompt three times. Worker deploys wait for
   the same human approval as node deploys (fixed 2026-08-20; before that
   rail 7 read repo-wide while this workflow had no gate).

## Required GitHub Secrets / Variables

Secrets: `SSH_PRIVATE_KEY_VPS00` / `_VPS01` / `_VPS02` (one CI key per
node, see blast radius below), `SSH_KNOWN_HOSTS`, `VPS00_HOST`,
`VPS01_HOST`, `VPS02_HOST`, `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_TUNNEL_TOKEN` (vps00), `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`
(vps01), `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` (vps02),
`CLOUDFLARE_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
(vps01's `.r2.env`; without them both nightly backups exit 1),
`NETDATA_CLAIM_TOKEN`, `NETDATA_CLAIM_ROOMS` (Netdata Cloud claim, the
**same** value on all three nodes, unlike a tunnel token),
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (Netdata alert config on all 3
nodes, and vps01's `.telegram.env` for `check-backup-age.sh`),
`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` (status Worker's
Cloudflare Access service token, `deploy-worker.yml`), `DEBUG_KEY` (gates
`maybeit.work/debug`; unset, the route 404s for everyone — it fails
closed).

Present as repo secrets but **consumed by no workflow**:
`DOKPLOY_API_TOKEN` and `CLOUDFLARE_TUNNEL_ID`, for manual dashboard/CLI
work. Don't delete them assuming they are load-bearing, and don't reference
them in a workflow assuming they are maintained.

Variables (optional, default in workflow): `VPS0N_SSH_USER`,
`VPS0N_SSH_PORT`.

## Conventions

- New workflow → `actionlint` catches shell-injection from unquoted `${{
  }}` in `run:` blocks; use intermediate `env:` vars for untrusted input
  (PR titles, branch names).
- New secret → add to `.env.example` (empty value) and the list above, add
  to GitHub repo secrets, never commit the value. Reference it under `env:`
  or `with:`, **never** inside a `run:` body: `${{ }}` is substituted
  before bash parses the script, so a value containing a backtick or `$(`
  executes on the runner.
- New action → pin to a full commit SHA with the version in a trailing
  comment (`uses: owner/repo@<40-char-sha>  # v1.2.3`). Tags are mutable; a
  retagged upstream runs with `SSH_PRIVATE_KEY` and `CLOUDFLARE_API_TOKEN`
  in scope. No longer only a convention: the repo has
  `sha_pinning_required: true` set GitHub-side, so an unpinned `uses:` is
  refused. Dependabot (`.github/dependabot.yml`) bumps the pins weekly so
  they don't rot.

## Blast radius of the CI credential

Each deploy job authenticates with **its own** node key
(`SSH_PRIVATE_KEY_VPS0N`), so one leaked secret reaches one node, not
three. That is the only thing per-node keys buy. `deploy` is in the
`docker` group, which is root-equivalent, and it owns
`/opt/stacks/<node>/docker-compose.yml`, so it can write any compose file
it likes and have root run it. **Any path that lets CI deploy containers is
root-equivalent by construction.** Removing `deploy` from the `docker`
group and granting `sudo docker compose` instead is theatre; do not propose
it as a fix. Rail 6's "no sudo" restricts the *shape* of the access, not
its power.

The real controls are per-node keys (blast radius) and required reviewers
on the `production` environment: a human approves before any deploy runs,
which is what stops an automated exfiltration path. The environment was
created 2026-08-12 and carries a `required_reviewers` rule naming
`nineW0nW0n` (verified 2026-08-20 against a live `waiting` run with an empty
approvals list — the gate observed holding, not inferred from config). Two
limits it does **not** impose: `can_admins_bypass: true` and
`prevent_self_review: false`, so it stops an automated path, not the sole
admin. **Every deploy now waits for Ex to approve it** in the Actions
tab; a run sitting at "Waiting" is the protection working, not a stuck job.

Three controls live in GitHub settings, not this repo, so `git revert`
restores none of them: `production`'s required reviewers (Settings →
Environments → production), `sha_pinning_required`, and a repository
**ruleset** on `main` blocking deletion and force-pushes (rules `deletion`
+ `non_fast_forward`, no bypass actors). A rejected push reading "push
declined due to repository rule violations" is that ruleset working; to
rewrite history deliberately, disable it, rewrite, re-enable, and expect
every SHA in `docs/` to dangle afterwards. All three workflow tokens are
`permissions: contents: read`, so no workflow can push to `main`: these
rules guard human error, not CI.

## Failure log

Incident histories behind these rules: `failure-log` skill
(`.github/workflows/`).

- **Keep the `docker compose config --services` guard on the pull/up
  step.** A stack with `services: {}` makes plain `docker compose pull`
  error out with nothing to pull; don't cut the guard as dead code without
  checking every node's stack first.
- **Never wire vps00's token into another node** (rail 2). deploy-vps02's
  `.env` step once wrote the shared `CLOUDFLARE_TUNNEL_TOKEN`; vps02 now
  has its own `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, same pattern as
  vps01. Full original entry in
  `docs/superpowers/failure-log-archive.md`.
- **`rsync --delete` needs an exclude for every piece of node state.**
  It wiped vps01's `backup/` — run logs and the `.last-success` stamps the
  staleness check reads — on every deploy until 2026-08-18. `.r2.env` /
  `.telegram.env` are excluded for a subtler reason: `--delete` removes
  them and later steps write them back, so a deploy overlapping the `:30`
  staleness check made it exit 1 and skip that hour silently. `.env` is
  deliberately not excluded; nothing reads it between rsync and rewrite.
- **Trigger deploys only on paths that reach a node.** `deploy.yml`'s
  `paths:` listed `infra/`, which nothing rsyncs, so a docs-only edit to
  `infra/CLAUDE.md` queued a full three-node production deploy that sat
  13h at the approval gate and then shipped a by-then stale `deploy.yml`
  that wiped vps01's backup state. The same lesson recurred one directory
  in on 2026-08-23: `stacks/**` matches `stacks/CLAUDE.md`, so editing
  documentation deployed to production. Negated patterns now exclude both
  `stacks/CLAUDE.md` and `stacks/**/CLAUDE.md` -- **both forms, because
  `**` matches across slashes and does not reliably match the top-level
  file.** `paths` and `paths-ignore` cannot both be set for one event, so
  the exclusion has to live inside `paths`, below what it narrows.
- **Read the matched rule in Security → Events before theorising about a
  403.** Post-deploy probes of the public hostnames from the runner fail
  on a zone-wide Cloudflare custom rule, `Block non-local traffic`
  (`ip.src.country ne "PH"`), not on bot protection rejecting datacenter
  IPs — that first diagnosis was wrong, amended 2026-08-19. `maybeit.work`
  is exempt; the other hostnames are not, so CI still cannot probe them.
- **Give every post-deploy probe a retry budget, and test it right after a
  restart.** The rewritten node-side check ran immediately after the
  Deploy step's `docker compose restart netdata`, which answers 503 for
  ~5s, and so failed on all three healthy nodes; it polls now, 30 tries 2s
  apart. A post-deploy check runs at the worst possible moment by
  definition.
- **`.State.Running` is not aliveness for anything with a restart
  policy.** Under `restart: unless-stopped` a container that crashes on
  startup is Running for a moment out of every minute, and the verify step
  sampled all three nodes inside that moment and printed `ok vector` for a
  Vector that had never once completed startup. Snapshot `.RestartCount`,
  wait, and require Running plus an unchanged count. The wait must exceed
  60s -- the Docker restart backoff caps there, so a mature crashloop ticks
  its counter only once a minute and a 20s window passed the same broken
  container. A polling HTTP probe has the identical hole: it can catch a
  looping container in its up window, which is why vps02 checks openobserve
  both ways.
- **A secret containing `#` is silently truncated on its way into a
  container.** Compose's `.env` parser treats an unquoted `#` as a comment
  start, so a 32-character `OPENOBSERVE_ROOT_PASSWORD` arrived as 21
  characters, created the OpenObserve root user with the truncation, and
  reported nothing. Every later authentication failed, and the mismatch
  read like wrong credentials rather than a parser. `$`, quotes,
  backslashes, backticks and edge whitespace are the same class. The
  `approve` job now refuses to deploy on any of them -- watched failing on
  the exact password that caused this before being trusted. **Never
  diagnose a 401 by assuming the value the container holds is the value
  you set; compare lengths first** -- lengths are safe to print, values
  are not.
- **The `gitleaks` hook scans staged changes only,** so it contributes
  nothing under `pre-commit run --all-files` in `validate.yml`. Kept once,
  in root's failure log; don't duplicate it here.
