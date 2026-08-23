# Handoff, SIEM-ish log centralisation on vps02 (OpenObserve + Vector)

**Written:** 2026-08-22, mid-rollout. **Updated 2026-08-23:** the fix wave
has been re-reviewed and the branch re-validated on vps02; the branch is
pushed and a PR is open. **Nothing is deployed or configured in Cloudflare
yet** — resume at Task 8 (the six GitHub secrets).

**Audience:** the next agent. Read `.claude/CLAUDE.md` (root),
`stacks/CLAUDE.md`, `scripts/CLAUDE.md` first; the hard rails there apply
on top of this document. No real IPs here (rail 5).

Commits are cited by **message, not SHA**.

Binding documents, in order of authority:
- Spec: `docs/superpowers/specs/2026-08-22-siem-openobserve-design.md`
- Plan: `docs/superpowers/plans/2026-08-22-siem-openobserve.md` (12 tasks)
- Ledger with every ruling: `.superpowers/sdd/2026-08-22-siem-openobserve/progress.md`
  (git-ignored scratch; survives only on Ex's laptop)

---

## What is on the branch (12 commits after the spec/plan)

| Area | State |
|---|---|
| `stacks/vps02/` | `openobserve` (`openobserve/openobserve:v0.92.2`, `127.0.0.1:5080`, 384m/192m, 30d retention) + `vector` shipper |
| `stacks/vps00/`, `stacks/vps01/` | `vector` (`timberio/vector:0.57.0-debian`, 128m/64m) posting to `https://siem-ingest.maybeit.work` with CF-Access service-token headers |
| `stacks/*/vector.yaml` | byte-identical on all nodes (check-rails enforces); journald source, `_timestamp` remap, excludes its own container, http sink to `/api/default/journal/_json` |
| `.github/workflows/deploy.yml` | six new secrets into `.env` (one write per node, one `printf` per key); verify asserts `vector` running on all nodes and `openobserve /healthz` on vps02 |
| `scripts/setup-maintenance.sh` | `daemon.json` → `{"ip":"127.0.0.1","log-driver":"journald"}` (rewrite, never merge); journald `Storage=persistent`, `SystemMaxUse=1G` |
| `scripts/install-aide.sh` | new: AIDE install, baseline, daily `/usr/sbin/aide.wrapper --update` piped to `logger -t aide` |
| `scripts/check-rails.sh` | asserts the three `vector.yaml` identical; asserts journald driver string in `setup-maintenance.sh`; sweep list gains 5080 |
| Docs | `stacks/CLAUDE.md` Logs section + hostnames, `scripts/CLAUDE.md`, root rail 1 sweep list, README |

Validated 2026-08-23, post-fix-wave, on vps02 (laptop has no Docker):
`vector validate` on the current `vector.yaml` says `Validated`, and
`docker compose config --quiet` passes for all three stacks with `x`
placeholders. The three `vector.yaml` are byte-identical (`md5`), so one
Vector run covers all three. `pre-commit run --all-files` and
`check-rails` green; every `CLAUDE.md` under budget.

To re-run it, copy with `tar`, not `rsync` — **macOS's bundled `rsync`
stalls and dies with `poll: timeout` against these nodes** (2026-08-23);
CI is unaffected, `deploy.yml` runs rsync on Linux.

```sh
T=/root/.siem-validate
ssh vps02-root "mkdir -p $T"
tar cz -C stacks vps00 vps01 vps02 | ssh vps02-root "tar xz -C $T"
ssh vps02-root "docker run --rm -v $T/vps02/vector.yaml:/etc/vector/vector.yaml:ro \
  -e NODE_NAME=x -e OPENOBSERVE_INGEST_URL=http://127.0.0.1:5080 \
  -e OPENOBSERVE_INGEST_USER=x -e OPENOBSERVE_INGEST_PASSWORD=x \
  timberio/vector:0.57.0-debian validate --no-environment /etc/vector/vector.yaml"
# then a .env of NAME=x per stack, docker compose config --quiet each; then rm -rf $T
```

## Where the process stopped, and what closed it

The commit "fix(siem): final-review fix wave ..." applied all seven
findings plus three minors from the whole-branch review, but its scoped
re-review never ran (the implementer was stopped before writing its
report). **Re-reviewed 2026-08-23 against the ledger's "Final review: With
fixes" list — all ten present and correct, no new findings:**

| Finding | State |
|---|---|
| #1 `journal_directory` unpinned | done; both `/var/log/journal` and `/run/log/journal` bind-mounted read-only on all three nodes, plus `/etc/machine-id` |
| #2 `_timestamp` | `to_unix_timestamp(timestamp!(.timestamp), unit: "microseconds")`, VRL accepted by `vector validate` |
| #3 Vector self-loop | `exclude_matches: {CONTAINER_NAME: ["vector"]}` |
| #4 merge-order wording | README + root say "ships once its secrets and Cloudflare objects exist" |
| #5 verify is liveness-only | called out in `stacks/CLAUDE.md` with the `logger -t siem-test` procedure |
| #6 `install-aide.sh` under `set -e` | keys on the printed `enabled`, not the exit status |
| #7 wire-format check | named as a first-deploy check on vps02 |
| minor: `depends_on` | `depends_on: [openobserve]` on vps02's vector |
| minor: check-rails guard | `[ -f ]`-guarded and moved out of the rail-1 echo block |
| minor: "Eight hostnames" | now "Eight routes documented; six live … two pending" |

Then the operational tasks, in this order (merge == deploy, do not merge
early):

| Plan task | Who | What |
|---|---|---|
| 8 | Ex | six GitHub secrets: `OPENOBSERVE_ROOT_EMAIL`, `OPENOBSERVE_ROOT_PASSWORD`, `OPENOBSERVE_INGEST_USER`, `OPENOBSERVE_INGEST_PASSWORD` (same as root until Task 12), `CF_ACCESS_SIEM_CLIENT_ID`, `CF_ACCESS_SIEM_CLIENT_SECRET` (from Task 10 step 1). None exist yet (`gh secret list` checked 2026-08-22). |
| 9 | agent, as root via `vps0N-root` aliases | `setup-maintenance.sh` twice per node, `install-aide.sh` twice per node, then `systemctl restart docker` per node (tell Ex first: vps00 restarts Dokploy, vps01 blips booking/budget). Measured before any change: all three nodes have `/var/log/journal` (persistent in effect), log driver `json-file`. |
| 10 | agent drives the browser, Ex acts where needed | service token `siem-ingest` → Access app `siem-ingest` (service-auth policy only) → Access app `siem` (owner email) → two Public Hostnames on tunnel `vps02-metrics` (`bba6cb3b-…`) → geo rule `da4def36…` gains `and http.host ne "siem-ingest.maybeit.work"` (Ex confirms before Deploy). Verify after via `cloudflare-api` read calls. Ex said: "lead the browser until it needs my input." |
| 11 | Ex merges + approves; agent verifies | Redeploy booking/ezbookkeeping in Dokploy for the driver switch; `logger -t siem-test` on each node; container lines visible; off-node sweep incl. 5080; Access probes; `docker logs vector` on vps02 empty of errors/400 (wire-format check); `docker stats` after an hour and record in `stacks/CLAUDE.md`; then bump README + root to plain "three workloads". |
| 12 | Ex + agent | dedicated OpenObserve ingest user, rotate the two ingest secrets, re-run deploy, re-test. |

## Cloudflare baseline (read-only, 2026-08-22)

Tunnels: `homelab-but-the-home-is-silent` (vps00), `vps01-booking`,
`vps02-metrics` — one connector each. Access apps: `budget`, `dokploy`
(+ `/api/deploy` bypass), `vps00/01/02-metrics`. Service tokens:
`status-worker` only. Custom rules: "Dokploy autodeploy webhook" (skip),
"Block non-local traffic" (block, `(ip.src.country ne "PH" and http.host ne
"maybeit.work")`). Nothing SIEM-related exists yet.

**Resolved 2026-08-23:** the `budget` Access app's second policy
`partner email allow` is intended — Ex's partner uses ezBookkeeping.
`stacks/CLAUDE.md` now records both policies and the rule behind them
(one policy per person per app, ops surfaces stay owner-only), plus a
failure-log line about counting policies by reading them back.

## Deferred (recorded, not done)

- `check-rails.sh` compares three hardcoded `vector.yaml` paths; a vps03
  would be unchecked. Glob `stacks/*/vector.yaml` when a fourth node exists.
- `worker/status/CLAUDE.md` "the one `status-worker` service token" goes
  stale once `siem-ingest` exists — dated observation, add "at the time".
- `stacks/CLAUDE.md` is at 252 lines, past the ~250 split heuristic; needs
  asking before splitting.
- Cloudflare edge events, alert rules, rootkit/CIS scanners: spec non-goals.
- Netdata Cloud MCP: rejected, needs a paid plan.

## Rulings made on Ex's behalf this session

All in the ledger with cost-if-wrong; the ones that matter:
- Branch in the main checkout, no worktree.
- `---` document start added to `vector.yaml` (yamllint); `printf` split
  per key (120-col yamllint) — both deviations from the plan's literal text.
- Push/PR withheld from subagents; controller does it after re-review.
- Fix wave committed unreviewed rather than left uncommitted when Ex
  stopped the session — reversible; the commit message says so.
- Memory files corrected: the zone's one free rate-limit rule is spent on
  `/api/deploy` (#48), not unused.
