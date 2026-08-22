# Handoff, SIEM-ish log centralisation on vps02 (OpenObserve + Vector)

**Written:** 2026-08-22, mid-rollout. Ex stopped the session during the
final-review fix wave; everything is committed on branch
`feat/siem-openobserve`, **nothing is pushed, deployed, or configured in
Cloudflare yet.**

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

Validated: `pre-commit run --all-files` green at HEAD, `check-rails` green,
every `CLAUDE.md` under budget. **`docker compose config` and `vector
validate` were run on vps02 only for the state before the fix wave**
(commit "feat(check-rails): assert vector.yaml is identical..."). The fix
wave changed `vector.yaml` (dropped `journal_directory`, added
`exclude_matches`, added the `_timestamp` remap) and has **not** been
validated with Vector since. Laptop has no Docker; validate on vps02:

```sh
T=/root/.siem-validate; for n in vps00 vps01 vps02; do ssh vps02-root "mkdir -p $T/$n"; rsync -az stacks/$n/ vps02-root:$T/$n/; done
ssh vps02-root "docker run --rm -v $T/vps02/vector.yaml:/etc/vector/vector.yaml:ro \
  -e NODE_NAME=x -e OPENOBSERVE_INGEST_URL=http://127.0.0.1:5080 \
  -e OPENOBSERVE_INGEST_USER=x -e OPENOBSERVE_INGEST_PASSWORD=x \
  timberio/vector:0.57.0-debian validate --no-environment /etc/vector/vector.yaml"
# then docker compose config --quiet per stack with x placeholders; then rm -rf $T
```

## Where the process stopped

The commit "fix(siem): final-review fix wave ..." applied all seven
findings plus three minors from the whole-branch review **but its scoped
re-review never ran** (the implementer was stopped before writing its
report). Resume here:

1. Re-review that one commit against the list in `.superpowers/sdd/.../progress.md`
   ("Final review: With fixes ...") or, failing the ledger, against this
   list: journal dir unpinned; `._timestamp = to_unix_timestamp(timestamp!(.timestamp), unit: "microseconds")`;
   `exclude_matches: {CONTAINER_NAME: ["vector"]}`; `Storage=persistent` +
   `mkdir -p /var/log/journal` idempotent; `install-aide.sh` keys on
   `is-enabled = enabled`; vps02 `vector` has `depends_on: [openobserve]`;
   check-rails journald grep guarded and moved below the rail-1 echoes;
   README/root say the third workload ships once secrets + Cloudflare objects
   exist; `stacks/CLAUDE.md` "Eight routes documented; six live, two pending",
   liveness-vs-ingestion note, first-deploy wire-format check, failure-log line.
2. Run the Vector validation above.
3. Push, open the PR (plan Task 7 Step 8 has the body), give Ex the link.

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

**Observation, not acted on:** the `budget` Access app carries a second
policy `partner email allow`; `stacks/CLAUDE.md` says it has one policy.
Ask Ex whether that is intended, then fix the doc or the policy.

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
