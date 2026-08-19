Parent: ../../.claude/CLAUDE.md

# .github/workflows/: CI/CD

`validate.yml` (lint gate), `deploy.yml` (parallel deploy to
the three nodes), and `deploy-worker.yml` (the `maybeit.work` status
Worker: `npm test` then `wrangler deploy`, entirely separate from the
node deploy path; see `worker/status/CLAUDE.md`).

## Flow

1. `validate.yml` runs on every PR and push to `main`: `pre-commit
   run --all-files --show-diff-on-failure` (yamllint --strict,
   actionlint, gitleaks, shellcheck, trailing-whitespace,
   large-file/private-key checks, plus the `no-real-ips` and `biome ci`
   local hooks). Also callable via `workflow_call`; `deploy.yml` calls
   it first (rail 8).
2. `deploy.yml` runs on push to `main` (paths: `infra/**`, `stacks/**`,
   itself) or manual dispatch. `concurrency: deploy-production`,
   `cancel-in-progress: false`: a second push queues, doesn't abort a
   deploy in flight. A single `approve` job holds the `production`
   environment and the three deploy jobs `needs:` it, so one approval
   covers the run and all three nodes deploy in parallel (rail 7). Do not
   put `environment: production` back on the deploy jobs: GitHub prompts
   once per job, which is what made this three clicks. Each deploy job ends
   with a `Verify vps0N` step that checks the node's own origin over the
   SSH connection it already has: Netdata answers 200 on loopback,
   `cloudflared-vps0N` is running, and on vps01 both apps answer 200
   through Traefik with a `Host:` header. It reports and fails; it never
   reverts. Per node: SSH key via
   `webfactory/ssh-agent`, pinned `known_hosts`, `mkdir -p` the remote
   stack dir, `rsync --delete` the stack files, write that node's tunnel
   token into a remote `.env` (piped over SSH stdin, never a CLI arg,
   never committed), then `docker compose pull && up -d && image prune
   -f && restart netdata`, guarded: if the stack has no services, skip
   pull/up instead of erroring (see failure log). The trailing `restart
   netdata` is needed because bind-mounted `netdata.conf` /
   `health_alarm_notify.conf` content changes don't force a container
   recreate under `docker compose up -d` on their own.

## Required GitHub Secrets / Variables

Secrets: `SSH_PRIVATE_KEY_VPS00` / `_VPS01` / `_VPS02` (one CI key per
node, see the blast-radius note below), `SSH_KNOWN_HOSTS`, `VPS00_HOST`, `VPS01_HOST`,
`VPS02_HOST`, `DOKPLOY_API_TOKEN`, `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_TUNNEL_TOKEN` (vps00), `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`
(vps01), `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` (vps02),
`CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ACCOUNT_ID`, `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID` (Netdata alerts, all 3 nodes), `CF_ACCESS_CLIENT_ID`,
`CF_ACCESS_CLIENT_SECRET` (status Worker's Cloudflare Access service
token, `deploy-worker.yml`), `DEBUG_KEY` (gates `maybeit.work/debug`;
if unset the route 404s for everyone; it fails closed).

Variables (optional, default in workflow): `VPS0N_SSH_USER`,
`VPS0N_SSH_PORT`.

## Conventions

- New workflow → `actionlint` catches shell-injection from unquoted
  `${{ }}` in `run:` blocks; use intermediate `env:` vars for untrusted
  input (PR titles, branch names) rather than interpolating directly.
- New secret → add to `.env.example` (empty value) and this file's
  required-secrets list, add to GitHub repo secrets, never commit the
  value. Reference it under `env:` or `with:`, **never** inside a `run:`
  script body: `${{ }}` is substituted before bash parses the script,
  so a value containing a backtick or `$(` executes on the runner.
- New action → pin to a full commit SHA with the version in a trailing
  comment (`uses: owner/repo@<40-char-sha>  # v1.2.3`). Tags are
  mutable; a retagged upstream runs with `SSH_PRIVATE_KEY` and
  `CLOUDFLARE_API_TOKEN` in scope. Dependabot (`.github/dependabot.yml`)
  bumps the pins weekly so they don't rot.

## Blast radius of the CI credential

Each deploy job authenticates with **its own** node key
(`SSH_PRIVATE_KEY_VPS0N`), so one leaked secret reaches one node, not
three. That is the only thing per-node keys buy; read the next
paragraph before assuming they buy more.

`deploy` is in the `docker` group, which is root-equivalent, and it owns
`/opt/stacks/<node>/docker-compose.yml`, so it can write any compose file
it likes and have root run it. **Any path that lets CI deploy containers
is root-equivalent by construction.** Removing `deploy` from the `docker`
group and granting `sudo docker compose` instead is theatre. Do not
propose it as a fix. Rail 6's "no sudo" restricts the *shape* of the
access, not its power.

The real controls are: one key per node (blast radius), and required
reviewers on the `production` environment (a human approves before any
deploy runs, which is what stops an automated exfiltration path).

Both are in place as of 2026-08-16. **Every deploy now waits for Ex to
approve it** in the Actions tab. A run sitting at "Waiting" is the
protection working, not a stuck job. The setting lives in GitHub
(Settings → Environments → production), not in this repo, so it is the
one control here that a `git revert` cannot restore.

Same category: a repository **ruleset** on `main` blocks deletion and
force-pushes (rules `deletion` + `non_fast_forward`, no bypass actors).
Also GitHub-side, also not restorable by revert. A rejected push reading
"push declined due to repository rule violations" is that rule doing its
job. To rewrite history deliberately, disable the ruleset, rewrite,
re-enable, and expect every SHA in `docs/` to dangle afterwards.

Note all three workflow tokens are `permissions: contents: read`, so no
workflow can push to `main` at all. These rules guard against human
error, not against CI.

## Failure log

- A stack with `services: {}` (e.g. vps02, no workload yet) makes plain
  `docker compose pull` error out with nothing to pull. The pull/up step
  is guarded (`if [ -n "$(docker compose config --services)" ]`). Keep
  the guard, don't remove it as "dead code" without checking every node's
  stack first.
- deploy-vps02's "Write remote .env" step used to write
  `CLOUDFLARE_TUNNEL_TOKEN` (vps00's shared token) into vps02's `.env`,
  even though vps02 has no service to consume it. Removed at the time.
  vps02 now has its first workload (Netdata) and its own dedicated
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` secret + "Write remote .env"
  step, same pattern as vps01. Never wire in vps00's token (rail 2).
- The `gitleaks` hook here is `gitleaks protect --staged`: it scans
  staged changes only, so under `pre-commit run --all-files` in CI,
  where nothing is staged, it scans nothing. It is a commit-time
  secret check, not a CI one. Any repo-wide content rule needs a
  `local` hook that takes filenames instead (see `no-real-ips`).

- A post-deploy check that probed the **public hostnames from the runner**
  failed every probe with `403` while every service was healthy. First
  diagnosis (bot protection rejecting datacenter IPs) was **wrong**: the
  real cause is a zone-wide Cloudflare custom rule, `Block non-local
  traffic`, matching `ip.src.country ne "PH"`. Any non-PH source is blocked,
  which is every GitHub runner and both US-hosted nodes. Amended
  2026-08-19 after reading Security -> Events in the dashboard rather than
  inferring from response codes. `maybeit.work` is now exempt from that
  rule; the other hostnames are not, so CI still cannot probe them. Read the
  matched rule in Security Events before theorising about a 403.
