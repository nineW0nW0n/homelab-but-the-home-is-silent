# CLAUDE.md: root

> Audience: Claude Code, first. Ex, second. Every rule exists because it
> makes the agent more reliable, not because it reads nicely. If a rule
> helps the agent but confuses Ex, keep it and add one clarifying line.

Map, not manual. ~500 lines each for this root and every directory
`CLAUDE.md`, because they are always in context. Skills are exempt — they
load on demand, so keep them scannable, not short. Anything longer than a
couple of lines of install commands, config, or multi-step workflow belongs
in `.claude/skills/`.

## What / where / when / why / how

- **What**: `homelab-but-the-home-is-silent`, GitOps infra for a 3-node
  Debian 12 VPS homelab. Dokploy deploys, Cloudflare Tunnel is the only
  public ingress, GitHub Actions is the only path to production.
- **Where**: `vps00` (primary, Dokploy control plane), `vps01`, `vps02`
  (Dokploy Remote Servers). 2 vCPU / 2GB RAM each, no swap by default. Each
  node runs its **own independent single-node Swarm** — three swarms, not
  one cluster, so nothing needs 2377/7946 open between them (verified
  2026-08-16). All three run `cloudflared`, Netdata, `dokploy-traefik`.
- **When**: work in progress. Provisioning/hardening done and
  CI-deployable; first workload live. A GitHub ruleset protects `main`
  against deletion and force-pushes (verified by attempting a rewind and
  being rejected), so a rewrite is deliberate: disable the ruleset,
  rewrite, re-enable. Don't assume you can force-push.
- **Why**: learn GitOps end to end on real, cheap, constrained hardware.
  The constraints are the point, not accidents to design around.
- **How**: infra under `infra/`, workloads under `stacks/`, push to `main`,
  `validate.yml` gates `deploy.yml`, one approval gates production and all
  three nodes then deploy in parallel.

## Directory map

| Directory | Role | CLAUDE.md status |
|---|---|---|
| `infra/` | Inventory: real IPs (gitignored) + redacted template | exists → `infra/CLAUDE.md` |
| `stacks/` | Per-node `docker-compose.yml`: cloudflared connector + compose workloads | exists → `stacks/CLAUDE.md` |
| `stacks/vps01/` | Backups (booking + ezBookkeeping), R2 retention, drills, staleness alerting | exists → `stacks/vps01/CLAUDE.md` |
| `scripts/` | Idempotent POSIX `sh` provisioning/bootstrap scripts | exists → `scripts/CLAUDE.md` |
| `.github/workflows/` | `validate.yml` (lint gate), `deploy.yml` (one approval, then all three nodes in parallel), `deploy-worker.yml` (status Worker) | exists → `.github/workflows/CLAUDE.md` |
| `dokploy/` | Compose apps Dokploy pulls from git (not `deploy.yml`) | exists → `dokploy/CLAUDE.md` |
| `worker/status/` | Cloudflare Worker: status page + health poller | exists → `worker/status/CLAUDE.md` |
| `docs/` | Handoffs, plans and specs from past sessions (`superpowers/`); read-only history, nothing deploys from here | none: no rails of its own |

Keep this column current the same commit you add or remove a directory
file.

## Reading protocol: use the distributed context, don't just write it

**Before working in any directory:** read its `CLAUDE.md` if one exists.
Check, don't assume it's in context. Its rails apply on top of root's.

**After a compaction, or whenever you're unsure what's still in context:**
re-read this file and the active directory's `CLAUDE.md`, and say in one
line that you did. Losing these rules mid-session is the most likely way a
long session goes bad.

**If a directory file contradicts root:** root wins. Stop, name the two
conflicting lines, ask, then fix the loser in the same turn and log it.
Never silently pick one.

## Hard rails: never break these

1. **No open inbound ports except SSH (22).** Public traffic goes through
   Cloudflare Tunnel, never a direct port. UFW alone does not enforce this:
   Docker's published ports bypass it. Enforced by `harden-node.sh`
   (`DOCKER-USER` drops + `daemon.json` loopback bind). Neither covers
   ingress-mode Swarm publishes, which traverse `DOCKER-INGRESS` --
   see `scripts/CLAUDE.md`. Checked by sweeping
   from off-node after any provisioning run — `nc -z -G 3 -w 3 <ip> <port>`
   over 22/80/443/2377/3000/19999 must answer on 22 and nothing else.
2. **One tunnel token per node, never shared.** A shared token means
   requests can land on the wrong node and 502.
3. **`network_mode: host` on every `cloudflared` service.** Bridge mode
   breaks `localhost:PORT` origin URLs.
4. **Explicit `mem_limit`/`mem_reservation` on every app service.** Classic
   Compose key: `deploy.resources` isn't honored by `docker compose up`.
5. **Real IPs are never committed.** Use the inventory key/hostname;
   `infra/inventory.example.yaml` stays redacted.
6. **CI deploy user: key-only, no sudo, no password login.** Dokploy uses
   its own separate credential.
7. **One approval gates production, in every workflow that reaches it** —
   `deploy.yml` via a single `approve` job the three parallel node deploys
   hang off, `deploy-worker.yml` via `environment: production` on its lone
   deploy job (it had no gate at all until 2026-08-20). Mechanism and why:
   `.github/workflows/CLAUDE.md`. Node deploys were sequential until
   2026-08-19; dropping that lost a real protection, a bad stack file
   reaching one node before the others. What remains is `validate.yml`, the
   single approval, and `git revert` (rail 12). Never drop the gate too.
8. **`validate.yml` passes before `deploy.yml` runs.** Fix lint failures;
   never bypass them.
9. **Biome lints/formats all JS, TS, JSON, JSONC, CSS.** No ESLint, no
   Prettier. Config: `biome.json`, see the `tooling-setup` skill.
10. **`yamllint` lints every `.yml`/`.yaml`** until Biome ships YAML support
    ([tracked, not shipped](https://github.com/biomejs/biome/issues/2365)).
    Config: `.yamllint`, see the `tooling-setup` skill.
11. **Never print secret material in full** — tunnel tokens, key contents,
    `.env` values — in chat output, not just commits. Redact
    (`TUNNEL_TOKEN=***redacted***`). Do not lean on gitleaks for this; see
    the failure log for what it actually scans.
12. **Rollback is `git revert` + push, not manual node surgery.** Let
    `deploy.yml` redeploy the last-known-good stack.

## The loop

Every change runs through this before you report it done.

```sh
pre-commit run --all-files   # every hook in .pre-commit-config.yaml:
                             # yamllint --strict, actionlint, gitleaks,
                             # shellcheck -s sh, the pre-commit-hooks
                             # basics, and two local hooks --
                             # no-real-ips (rail 5), biome ci . (rail 9)
shellcheck scripts/*.sh      # every script stays shellcheck-clean
git ls-files '*CLAUDE.md' | xargs wc -l
```

- The `git ls-files` line prints but never fails; acting on it is on you.
  Any `CLAUDE.md` over ~500 lines gets fixed before you report done. It
  lists *tracked* files, so a new one counts once you `git add` it. Never
  swap it for a glob or `find` — both are wrong, see the failure log.
- `biome ci .` finding nothing to lint is a pass, not a skip.
- Scripts stay idempotent: trace or run twice, confirm the second is a
  no-op.
- Never report done on a red check. Never hand-edit
  `infra/inventory.example.yaml` with a real IP. Pin
  `.pre-commit-config.yaml` hook revs exactly, same as any tool.

**Definition of done:** stack/compose change → `docker compose config`
passes, plus `pre-commit`. Workflow change → `actionlint` passes, and you
can state what would've caught the bug you're fixing. Script change →
idempotency check above, done and stated. Anything else → `pre-commit run
--all-files` green is the floor. Unsure for an unlisted change type? Ask.

## Tooling

Tools: Biome and yamllint (linters), superpowers (workflow skills), rtk
(compresses bash output before it hits context), caveman (terse output +
commit messages). All install-if-missing and pre-approved; say what you
installed in your summary. No count here on purpose — a hardcoded one goes
stale the next time this list changes.

Cloudflare MCP servers read live account state — Access apps and policies,
per-tunnel ingress, DNS, WAF rules, Worker deploys and secret-binding
*names*. Verify those against the account instead of asserting them, and
never against rail 1: Cloudflare cannot see what listens on a node, only
the off-node port sweep can. `cloudflare-api`'s `execute` also writes, so
"ask before changing tunnel/token/SSH/auth setup" governs it.

Install commands, hard-railed configs, and the skill/MCP mapping tables
live in **`.claude/skills/tooling-setup/SKILL.md`**. Load it when you
need it — a tool check fails, a config is missing, or setup is the task —
not routinely at session start. It is a skill precisely so it stays out of
context until needed. Never inline it here or in a directory file.

## Failure log (cross-cutting only)

Directory-specific mistakes go in that directory's `CLAUDE.md`. The
incident history behind every one-line rule in every failure log here:
`.claude/skills/failure-log/SKILL.md`.

- **Assert effective values, never the strings you wrote.** A config you
  authored is no proof the tool read it, honored it, or won against another
  source. Three lost sessions: Biome's `preset: "none"`, an rtk config at a
  path rtk never reads, an sshd drop-in outranked by another file while
  `sshd -t` still passed (`scripts/`, `infra/`). Make the tool print what
  it resolved.
- **A rail with no enforcement point is undetectable drift.** Rail 9 had no
  pre-commit hook and no `validate.yml` step until a `local` hook was added
  (`language: node`, `additional_dependencies: ["@biomejs/biome@2.5.8"]`,
  matching `biome.json`'s `$schema`; bump both together). Same class as
  rail 5's hook, the uninstalled `pre-commit`, and the budget check. Give
  every new rail a check that runs.
- **`pre-commit` was configured but never installed as a git hook** (no
  `.git/hooks/pre-commit`), so `git commit` ran nothing locally; only
  `validate.yml` caught anything, after a push. Run `pre-commit install` in
  a fresh clone — a config file is not an installed hook.
- **`gitleaks` scans staged changes only.** Entry: `gitleaks protect
  --verbose --redact --staged`, `pass_filenames: false` — so under
  `--all-files` in `validate.yml` nothing is staged and it scans nothing
  (re-verified 2026-08-20). Never express a repo-wide content rule as a
  `.gitleaks.toml` rule and assume CI enforces it; use a `local` hook
  taking filenames. Keep gitleaks as a commit-time check, but don't credit
  it with coverage it lacks.
- **Budget check: `git ls-files '*CLAUDE.md' | xargs wc -l`, nothing else.**
  A `wc -l */CLAUDE.md` glob skips dot-directories (`.claude/`,
  `.github/`); under rtk a `find` either errors out or walks untracked
  worktrees and reports a wrong count with exit 0, looking correct.
  Silently wrong does more damage than loudly broken. **When a rule
  mandates a tool that rewrites commands, run the rule's own commands under
  that tool first.** Superseded `find` history archived in
  `docs/superpowers/failure-log-archive.md`.
- **A directory split is not finished until the parent's copy is deleted.**
  The 2026-08-20 `stacks/vps01/` split wrote the child and trimmed only part
  of the parent, leaving 195 duplicated lines that then drifted: the parent's
  `mysqldump` line lost `--databases` while the child and the script kept it,
  and the parent contradicted itself eight lines later. It also carried a
  passage already recorded as archived, and an "archived passages are
  pointed to below" banner whose every pointer sat in the duplicated block.
  Two copies do not stay equal — one gets fixed. Delete the parent's copy in
  the same commit, then grep the repo for pointers into what you deleted:
  `deploy.yml` cited a warning that only survived in the moved text.
- **Never size a dataset with `du` on its volume.** `du -sh` on
  `booking-ptpwn8_mysql-data` said 203M; that became "~200MB of real
  appointments" and reached five documents before anyone dumped the
  database. Real: 14 tables, ~126 rows, 0.4 MB — the rest is MySQL 8.0's
  ibdata1, redo/undo tablespaces, binlogs. Query
  `information_schema.tables`, or dump and size the dump. **An inferred
  number is said once, hedged, until measured — never copied into a second
  document.**
- **Pin `biome.json`'s `$schema` and syntax to the exact version
  installed**, never to an older doc or skill: Biome 2.x's schema moved
  fast, and `biome migrate --write` produced `linter.rules.preset: "none"`,
  silently disabling every rule — verify the migrated `linter` block by
  hand. The current spellings live in `tooling-setup`, which carried the
  1.x ones the whole time this entry called them wrong (fixed 2026-08-16):
  **when a log entry says a config shape is wrong, grep the skills for it
  the same turn.** Original entry in
  `docs/superpowers/failure-log-archive.md`.
- **Never hand-create a config at a path a doc asserts; make the tool say
  where it reads from.** `tooling-setup` called `~/.config/rtk/config.toml`
  rtk's path; macOS rtk reads `~/Library/Application Support/rtk/` instead,
  so the config never loaded and rtk ran on defaults —
  `display.max_width = 120` chopped output mid-path for a session
  (2026-08-19). `rtk config --create` writes a populated default at the
  platform's real path; edit that in place. It exits 1 even on success —
  judge it by its "Created:" line, not its status.
- **A `git filter-repo` rewrite invalidates every commit SHA already
  written down** — handoffs, plans, specs, and the rewrite's own commit
  message. Grep `docs/` for short SHAs before force-pushing one; cite
  commits by *message* in documents meant to outlive a rewrite.
- **`claude plugin disable --scope project` overwrites
  `.claude/settings.json`, it does not merge.** It dropped this repo's
  `permissions.allow` block on 2026-08-20; the entry was recoverable only
  because it was still in context. Read the file, run the command, diff it,
  restore what it dropped — and note an untracked settings file has no `git
  diff` to save you, which is how a silent overwrite becomes permanent.
- **Pin exact versions/commits** for Biome, rtk, caveman, yamllint. Never
  `latest`.
- **yamllint's `truthy` rule flags `on:`** in Actions workflows as a
  boolean. Fix `.yamllint` (`check-keys: false`), never the workflow file.
- **New control-plane-style services get an explicit memory cap from the
  start.** Dokploy's was uncapped and ate a disproportionate share of a 2GB
  node; fix is `cap-dokploy-resources.sh`, detail in `scripts/CLAUDE.md`.
- Fail2Ban and `docker compose pull`-on-empty-stack live in
  `scripts/CLAUDE.md` and `.github/workflows/CLAUDE.md`: one script, one
  workflow, not cross-cutting.

## Propagation protocol

Distributed context: this root file, one `CLAUDE.md` per working directory,
skills in `.claude/skills/` for anything longer. Root is the map; directory
files carry local rails, vocabulary, and failure logs.

**On first substantive work in a directory with no `CLAUDE.md`:**

1. Skip directories that only contain other directories; create the file
   where the files are (`.github/workflows/`, not `.github/`).
2. Create `<directory>/CLAUDE.md`, opening with `Parent: ../CLAUDE.md`.
3. Fill in only what's true there — purpose, local rails, vocabulary,
   directory-specific commands. Don't repeat root.
4. End with an empty `## Failure log` heading.
5. Sweep root's failure log: move any entry that is really about this
   directory into the new file, and say so in your summary.
6. Mark the row `exists → <directory>/CLAUDE.md` in the directory map.

**Whenever corrected, or you catch a mistake, or find something true that
wasn't written down:**

1. One line, imperative, in that directory's failure log: "Do not run X; it
   causes Y. Do Z instead." **Keep the reason** — a rule without one gets
   deleted by a future agent who thinks it is redundant. Repo-wide lesson →
   root's log instead; say so in your summary. The incident story goes in
   the `failure-log` skill, not inline: the rule is what must be seen while
   skimming, the story is what is needed once you are already there.
2. Log it in the same commit/turn as the fix. Never batch for later.
3. Never delete a superseded line. Replace it in place; or, only when its
   situation can no longer occur, move the **full original text** to
   `docs/superpowers/failure-log-archive.md` and leave a one-line pointer
   naming the lesson and saying it is archived. When in doubt, keep it
   inline. Compression is not supersession: a lesson that still applies
   gets shorter, not moved.

**A lesson becomes a hard rail only when it gains a check.** This is the
graduation criterion, and it exists because the most-repeated failure in
this repo is a rail that reads well and enforces nothing — rail 5, rail 9,
`pre-commit` itself, the budget check, the sshd drop-in, and a code comment
citing a `check-rails.sh` that did not exist for months. Promoting lessons
to rails without checks makes that worse, not better. Sort every lesson
three ways:

- **Checkable** → make it a rail, one line, and add the check to
  `scripts/check-rails.sh` or `.pre-commit-config.yaml` in the same commit.
  Watch the check fail on a deliberately broken copy before trusting it; a
  check nobody saw fail is the bug it was meant to prevent.
- **Judgement, not mechanizable** ("measure, don't infer") → a one-line
  heuristic in the directory file that needs it. Not a rail; rails inflate
  and stop being read.
- **Fixed one-off that cannot recur** → archive it.

Rails stay few and enforced. Twelve get followed; thirty get skimmed.

**Keeping this current:** a directory file past ~250 lines is worth
splitting by sub-topic (`stacks/` → `stacks/vps01/`, 2026-08-20) or moving
narrative to a skill; past ~500 signals splitting the directory itself, and
that needs asking first. Measure cost in words, not lines — rewrapping a
file to a narrower column changes the line count and nothing else. Anything
long and reusable → a skill, referenced by one line, never inlined. Never
create a directory's `CLAUDE.md` speculatively.

## Self-audit: on demand

Ex runs this manually. When asked: review every `CLAUDE.md` and skill,
**and `README.md`**, for stale map rows, superseded-but-unreplaced log
lines, rails that no longer match reality, and anything over budget. Report
drift, fix what's unambiguous, ask before restructuring.

`README.md` is in scope and easy to forget precisely because it isn't a
`CLAUDE.md` — and it's the only public document here, so a stale claim in
it is a claim made to strangers. It asserted "no open inbound port except
SSH, enforced by UFW" while three ports answered from the internet.

**Recommend one, unprompted, when:** the failure log gains 3+ entries in a
session, a hard rail needed double-checking against real behavior, or the
repo's structure no longer matches the directory map. One line.

## When you're unsure

Ask before: opening an inbound port, changing tunnel/token/SSH/auth setup,
changing deploy order or rollback behavior, or removing a guard that looks
redundant. State assumptions at the top of your summary.

Ex is not an engineer. Before a non-trivial infra decision, not after,
explain in plain terms what and why, in 1-3 sentences. Hard-rail-adjacent
and destructive changes always; a typo fix doesn't.
