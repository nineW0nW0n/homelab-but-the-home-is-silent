Parent: ../../.claude/CLAUDE.md

# .github/workflows/ — CI/CD

`validate.yml` (lint gate), `deploy.yml` (sequential rolling deploy to
the three nodes), and `deploy-worker.yml` (the `maybeit.work` status
Worker — `npm test` then `wrangler deploy`, entirely separate from the
node deploy path; see `worker/status/CLAUDE.md`).

## Flow

1. `validate.yml` runs on every PR and push to `main`: `pre-commit
   run --all-files --show-diff-on-failure` (yamllint --strict,
   actionlint, gitleaks, shellcheck, trailing-whitespace,
   large-file/private-key checks, plus the `no-real-ips` and `biome ci`
   local hooks). Also callable via `workflow_call` — `deploy.yml` calls
   it first (rail 8).
2. `deploy.yml` runs on push to `main` (paths: `infra/**`, `stacks/**`,
   itself) or manual dispatch. `concurrency: deploy-production`,
   `cancel-in-progress: false` — a second push queues, doesn't abort a
   deploy in flight. Deploys sequentially — vps00, then vps01, then vps02
   (rail 7), each `needs:` the previous job. Per node: SSH key via
   `webfactory/ssh-agent`, pinned `known_hosts`, `mkdir -p` the remote
   stack dir, `rsync --delete` the stack files, write that node's tunnel
   token into a remote `.env` (piped over SSH stdin, never a CLI arg,
   never committed), then `docker compose pull && up -d && image prune
   -f && restart netdata` — guarded: if the stack has no services, skip
   pull/up instead of erroring (see failure log). The trailing `restart
   netdata` is needed because bind-mounted `netdata.conf` /
   `health_alarm_notify.conf` content changes don't force a container
   recreate under `docker compose up -d` on their own.

## Required GitHub Secrets / Variables

Secrets: `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `VPS00_HOST`, `VPS01_HOST`,
`VPS02_HOST`, `DOKPLOY_API_TOKEN`, `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_TUNNEL_TOKEN` (vps00), `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`
(vps01), `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` (vps02),
`CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ACCOUNT_ID`, `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID` (Netdata alerts, all 3 nodes), `CF_ACCESS_CLIENT_ID`,
`CF_ACCESS_CLIENT_SECRET` (status Worker's Cloudflare Access service
token, `deploy-worker.yml`), `DEBUG_KEY` (gates `maybeit.work/debug`;
if unset the route 404s for everyone — it fails closed).

Variables (optional, default in workflow): `VPS0N_SSH_USER`,
`VPS0N_SSH_PORT`.

## Conventions

- New workflow → `actionlint` catches shell-injection from unquoted
  `${{ }}` in `run:` blocks; use intermediate `env:` vars for untrusted
  input (PR titles, branch names) rather than interpolating directly.
- New secret → add to `.env.example` (empty value) and this file's
  required-secrets list, add to GitHub repo secrets, never commit the
  value. Reference it under `env:` or `with:`, **never** inside a `run:`
  script body — `${{ }}` is substituted before bash parses the script,
  so a value containing a backtick or `$(` executes on the runner.
- New action → pin to a full commit SHA with the version in a trailing
  comment (`uses: owner/repo@<40-char-sha>  # v1.2.3`). Tags are
  mutable; a retagged upstream runs with `SSH_PRIVATE_KEY` and
  `CLOUDFLARE_API_TOKEN` in scope. Dependabot (`.github/dependabot.yml`)
  bumps the pins weekly so they don't rot.

## Failure log

- A stack with `services: {}` (e.g. vps02, no workload yet) makes plain
  `docker compose pull` error out with nothing to pull. The pull/up step
  is guarded (`if [ -n "$(docker compose config --services)" ]`) — keep
  the guard, don't remove it as "dead code" without checking every node's
  stack first.
- deploy-vps02's "Write remote .env" step used to write
  `CLOUDFLARE_TUNNEL_TOKEN` — vps00's shared token — into vps02's `.env`,
  even though vps02 has no service to consume it. Removed at the time.
  vps02 now has its first workload (Netdata) and its own dedicated
  `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` secret + "Write remote .env"
  step, same pattern as vps01 — never wire in vps00's token (rail 2).
- The `gitleaks` hook here is `gitleaks protect --staged`: it scans
  staged changes only, so under `pre-commit run --all-files` in CI —
  where nothing is staged — it scans nothing. It is a commit-time
  secret check, not a CI one. Any repo-wide content rule needs a
  `local` hook that takes filenames instead (see `no-real-ips`).
