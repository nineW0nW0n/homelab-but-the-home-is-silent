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
   checks, plus the `no-real-ips` and `biome ci` local hooks). Also
   callable via `workflow_call`; both deploy workflows call it first (rail
   8).
2. `deploy.yml` runs on push to `main` (paths: `stacks/**`, itself) or
   manual dispatch. `concurrency: deploy-production`, `cancel-in-progress:
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
   restart netdata`, guarded: no services in the stack, skip pull/up
   instead of erroring (failure log). The trailing `restart netdata` is
   needed because bind-mounted `netdata.conf` / `health_alarm_notify.conf`
   edits don't force a recreate on their own.
4. vps01 only: the rsync excludes `backup/`, `backup-booking/`, `.r2.env`,
   `.telegram.env` (failure log), two extra steps write those two
   credential files, and one heredoc installs all four cron entries at once
   because `crontab -` **replaces** the whole crontab. Those four (two
   backups, two staleness checks) fire hourly and self-gate on their own
   Asia/Manila hour, 03:00 and 04:00, because Debian's cron ignores
   `CRON_TZ`.
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
which is what stops an automated exfiltration path. Both in place since
2026-08-16. **Every deploy now waits for Ex to approve it** in the Actions
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

- A stack with `services: {}` makes plain `docker compose pull` error out
  with nothing to pull. The pull/up step is guarded (`if [ -n "$(docker
  compose config --services)" ]`). Keep the guard; don't cut it as dead
  code without checking every node's stack first.
- deploy-vps02's `.env` step used to write vps00's shared
  `CLOUDFLARE_TUNNEL_TOKEN`. vps02 now has its own
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, same pattern as vps01. Never
  wire in vps00's token (rail 2). Full original entry in
  `docs/superpowers/failure-log-archive.md`.
- `rsync --delete` wiped vps01's `backup/` on every deploy until
  2026-08-18: the run logs and the `.last-success` stamps the staleness
  check reads are **node** state, not repo state. `.r2.env` /
  `.telegram.env` are excluded for a subtler reason: `--delete` removes
  them and later steps write them back, so a deploy overlapping the `:30`
  staleness check made it exit 1 on "`.telegram.env` missing" and skip that
  hour silently. `.env` is deliberately not excluded; nothing reads it
  between the rsync and its rewrite.
- `deploy.yml`'s `paths:` listed `infra/` until 2026-08-19 although nothing
  under it is ever rsynced. A docs-only edit to `infra/CLAUDE.md` queued a
  full three-node production deploy that sat 13h at the approval gate and,
  once approved, shipped a by-then stale `deploy.yml` that wiped vps01's
  backup state. Trigger deploys only on paths that reach a node.
- A post-deploy check probing the **public hostnames from the runner**
  failed every probe with `403` while every service was healthy. The first
  diagnosis (bot protection rejecting datacenter IPs) was **wrong**: it is
  a zone-wide Cloudflare custom rule, `Block non-local traffic`, matching
  `ip.src.country ne "PH"`, so every GitHub runner and both US-hosted nodes
  are blocked. Amended 2026-08-19 after reading Security → Events instead
  of inferring from response codes. `maybeit.work` is exempt now, the other
  hostnames are not, so CI still cannot probe them. Read the matched rule
  in Security Events before theorising about a 403.
- The rewritten node-side check then failed on its first real run with
  `FAIL netdata: 503` on all three healthy nodes: the Deploy step ends with
  `docker compose restart netdata` and Netdata answers 503 for ~5s while it
  initialises, so one immediate request races the restart it just caused.
  Fixed by polling (30 tries, 2s apart); it had passed by hand only because
  the agents had been up for hours. A post-deploy check runs at the worst
  possible moment by definition: give every probe a retry budget, and test
  it right after a restart rather than on a warm node.
- The `gitleaks` hook scans staged changes only, so it contributes nothing
  under `pre-commit run --all-files` in `validate.yml`. Kept once, in
  root's failure log; don't duplicate it here.
