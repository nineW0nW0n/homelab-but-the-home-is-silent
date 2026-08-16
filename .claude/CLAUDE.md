# CLAUDE.md — root

> Audience: Claude Code, first. Ex, second. Every rule exists because it
> makes the agent more reliable, not because it reads nicely. If a rule
> helps the agent but confuses Ex, keep it and add one clarifying line.

Map, not manual. Budgets apply to what is always in context: directory
`CLAUDE.md` files ~250 lines, this root ~500 (it carries the map, rails,
and protocol). Skills are exempt — they load on demand, so their cost is
paid only when used; keep them scannable, not short. Anything longer than
a couple of lines of install commands, config, or multi-step workflow
belongs in `.claude/skills/`, not here.

## What / where / when / why / how

- **What**: `homelab-but-the-home-is-silent` — GitOps infra for a 3-node
  Debian 12 VPS homelab. Dokploy deploys, Cloudflare Tunnel is the only
  public ingress, GitHub Actions is the only path to production.
- **Where**: `vps00` (primary, Dokploy control plane), `vps01` and
  `vps02` (Dokploy Remote Servers). 2 vCPU / 2GB RAM each, no swap by
  default. Each node runs its **own independent single-node Swarm** —
  three separate swarms, not one cluster, so nothing needs 2377/7946
  open between them (verified 2026-08-16). All three run `cloudflared`,
  Netdata, and a Dokploy-installed `dokploy-traefik`.
- **When**: work in progress. Provisioning/hardening done and CI-
  deployable; first workload still being shaken out. Expect force-pushes.
- **Why**: learn GitOps end to end on real, cheap, constrained hardware.
  The constraints are the point, not accidents to design around.
- **How**: infra under `infra/`, workloads under `stacks/`, push to
  `main`, `validate.yml` gates `deploy.yml`, deploy is sequential —
  `vps00 → vps01 → vps02`, never parallel.

## Directory map

| Directory | Role | CLAUDE.md status |
|---|---|---|
| `infra/` | Inventory: real IPs (gitignored) + redacted template | exists → `infra/CLAUDE.md` |
| `stacks/` | Per-node `docker-compose.yml` — cloudflared connector + compose workloads | exists → `stacks/CLAUDE.md` |
| `scripts/` | Idempotent POSIX `sh` provisioning/bootstrap scripts | exists → `scripts/CLAUDE.md` |
| `.github/workflows/` | `validate.yml` (lint gate), `deploy.yml` (sequential rolling deploy), `deploy-worker.yml` (status Worker) | exists → `.github/workflows/CLAUDE.md` |
| `worker/status/` | Cloudflare Worker: status page + health poller | exists → worker/status/CLAUDE.md |

Keep this column current the same commit you add or remove a directory
file.

## Reading protocol — use the distributed context, don't just write it

**Before working in any directory:** read its `CLAUDE.md` first if one
exists. Check — don't assume it's already in context. Its rails apply on
top of root's for everything you do there.

**After a context compaction, or any point where you're unsure what's
still in context:** re-read this file and the active directory's
`CLAUDE.md` before continuing, and say in one line that you did. Losing
these rules mid-session is the most likely way a long session goes bad.

**If a directory file contradicts root:** root wins. Stop, name the two
conflicting lines, ask. Then fix the loser in the same turn and log it.
Never silently pick one.

## Hard rails — never break these

1. **No open inbound ports except SSH (22).** Public traffic goes through
   Cloudflare Tunnel, never a direct port. UFW alone does not enforce
   this — Docker's published ports bypass it. Enforced by
   `harden-node.sh` (`DOCKER-USER` drops + `daemon.json` loopback bind);
   checked by sweeping ports from off-node after any provisioning run:
   `nc -z -G 3 -w 3 <ip> <port>` over 22/80/443/2377/3000/19999 must
   answer on 22 and nothing else.
2. **One tunnel token per node, never shared.** A shared token means
   requests can land on the wrong node and 502.
3. **`network_mode: host` on every `cloudflared` service.** Bridge mode
   breaks `localhost:PORT` origin URLs.
4. **Explicit `mem_limit`/`mem_reservation` on every app service.** Classic
   Compose key — `deploy.resources` isn't honored by `docker compose up`.
5. **Real IPs are never committed.** Use the inventory key/hostname;
   `infra/inventory.example.yaml` stays redacted.
6. **CI deploy user: key-only, no sudo, no password login.** Dokploy uses
   its own separate credential.
7. **Deploys are sequential, never parallel** — `vps00 → vps01 → vps02`.
8. **`validate.yml` passes before `deploy.yml` runs.** Fix lint failures;
   never bypass them.
9. **Biome lints/formats all JS, TS, JSON, JSONC, CSS.** No ESLint, no
   Prettier. Config: `biome.json` — see the `tooling-setup` skill.
10. **`yamllint` lints every `.yml`/`.yaml` file** until Biome ships YAML
    support ([tracked, not shipped](https://github.com/biomejs/biome/issues/2365)).
    Config: `.yamllint` — see the `tooling-setup` skill.
11. **Never print secret material in full** — tunnel tokens, key
    contents, `.env` values — in your own chat output, not just commits.
    Redact (`TUNNEL_TOKEN=***redacted***`).
12. **Rollback is `git revert` + push, not manual node surgery.** Let
    `deploy.yml` redeploy the last-known-good stack.

## The loop

Every change runs through this before you report it done.

```sh
pre-commit run --all-files   # yamllint --strict, actionlint, gitleaks,
                             # shellcheck -s sh, trailing-whitespace,
                             # large-file/private-key checks, and two
                             # local hooks: no-real-ips (rail 5),
                             # biome ci . (rail 9)
shellcheck scripts/*.sh      # every script stays shellcheck-clean
find . -name CLAUDE.md -not -path './node_modules/*' -exec wc -l {} +
```

- The `find` line prints but never fails — acting on it is on you: root
  over ~500 or a directory file over ~250 gets fixed before you report
  done. Plain globs miss `.github/`; `find` doesn't.
- `biome ci .` finding nothing to lint is a pass, not a skip.
- Scripts stay idempotent — trace or run twice, confirm the second is a
  no-op.
- Never report done on a red check. Never hand-edit
  `infra/inventory.example.yaml` with a real IP. Pin
  `.pre-commit-config.yaml` hook revs exactly, same as any tool.

**Definition of done:**

- Stack/compose change → `docker compose config` passes, plus
  `pre-commit`.
- Workflow change → `actionlint` passes, and you can state what would've
  caught the bug you're fixing.
- Script change → idempotency check above, done and stated.
- Anything else → `pre-commit run --all-files` green is the floor. Unsure
  what "done" means for an unlisted change type? Ask.

## Tooling

Five tools: Biome and yamllint (linters), superpowers (workflow skills),
rtk (compresses bash output before it hits context), caveman (terse
output + commit messages). All install-if-missing and pre-approved — say
what you installed in your summary.

Install commands, hard-railed configs, and the superpowers skill-mapping
table live in **`.claude/skills/tooling-setup/SKILL.md`**. Load it when
you actually need it — a tool check fails, a config file is missing, or
setup is the task — not routinely at session start. It is a skill
precisely so it stays out of context until needed.

Never inline its contents into this file or a directory file.

## Failure log (cross-cutting only)

Directory-specific mistakes go in that directory's `CLAUDE.md`.

- Dokploy's control plane was uncapped by default and ate a
  disproportionate share of a 2GB node — new control-plane-style
  services get an explicit cap from the start. Detail moved to
  `scripts/CLAUDE.md` (the fix is `cap-dokploy-resources.sh`).
- Fail2Ban and the `docker compose pull`-on-empty-stack gotchas moved to
  `scripts/CLAUDE.md` and `.github/workflows/CLAUDE.md` respectively —
  each is specific to one script/workflow, not cross-cutting.
- Pin exact versions/commits for Biome, rtk, caveman, yamllint. Never
  `latest`.
- yamllint's default `truthy` rule flags `on:` in GitHub Actions
  workflows as a boolean. Fix `.yamllint` (`check-keys: false`), never
  the workflow file.
- A `wc -l CLAUDE.md */CLAUDE.md */*/CLAUDE.md` budget check silently
  skips `.github/` — shell globs don't match dot-directories. Use `find`.
- Biome 2.x's config schema moved fast: `files.ignore` → `files.includes`
  with `!` negation, top-level `organizeImports` → `assist.actions.source`,
  `linter.rules.recommended: true` → `linter.rules.preset: "recommended"`
  (not `"none"` — `biome migrate --write` mis-converted `recommended: true`
  to `preset: "none"`, which silently disables all lint rules; verify the
  migrated `linter` block by hand, don't trust the tool output blindly).
  Always resolve the exact Biome version being installed and pin
  `biome.json`'s `$schema` and syntax to that version, not to whatever an
  older doc/skill shows.
- Rail 9 (Biome lints everything) existed in this file but was never
  gate-enforced — no pre-commit hook, no validate.yml step. Fixed by
  adding a `local` pre-commit hook (`language: node`,
  `additional_dependencies: ["@biomejs/biome@2.5.8"]`, matching
  `biome.json`'s `$schema`) so `pre-commit run --all-files` actually
  runs it. A rail without a wired-in check is undetectable drift —
  double-check new rails have an enforcement point, not just a sentence.
- `pre-commit` was configured but never installed as a git hook (no
  `.git/hooks/pre-commit`), so `git commit` ran no checks locally — only
  `validate.yml` caught anything, after a push. Run `pre-commit install`
  in a fresh clone; a config file is not an installed hook. Third
  instance of the same class as rail 9 and rail 5: the check existed on
  paper and nothing invoked it.
- The `gitleaks` pre-commit hook's entry is `gitleaks protect --staged` —
  it scans *staged changes only*. Under `pre-commit run --all-files` in
  `validate.yml` nothing is staged, so it silently scans nothing. Never
  express a repo-wide content rule as a custom `.gitleaks.toml` rule and
  assume CI enforces it; use a `local` hook that takes filenames. gitleaks
  still earns its place as a commit-time secret check — just do not credit
  it with coverage it does not have.
- The `tooling-setup` skill's Biome config block sat at the 1.x
  spellings (`files.ignore`, top-level `organizeImports`,
  `rules.recommended: true`) for as long as the log entry above said
  they were wrong — so following the skill would have reintroduced the
  exact bug the log warns about. Fixed 2026-08-16. When a failure-log
  entry says a config shape is wrong, grep the skills for that shape in
  the same turn; a log entry and a skill that contradict each other is
  worse than neither.

## Propagation protocol

Distributed context: this root file, one `CLAUDE.md` per working
directory, skills in `.claude/skills/` for anything longer. Root is the
map; directory files carry local rails, vocabulary, and failure logs.

**On first substantive work in a directory with no `CLAUDE.md`:**

1. Skip directories that only contain other directories — create the file
   where the files actually are (`.github/workflows/`, not `.github/`).
2. Create `<directory>/CLAUDE.md`, opening with `Parent: ../CLAUDE.md`.
3. Fill in only what's true there — purpose, local rails, vocabulary,
   directory-specific commands. Don't repeat root.
4. End with an empty `## Failure log` heading.
5. Sweep root's failure log: move any entry that turns out to be about
   this directory down into the new file, and say so in your summary.
6. Mark the row `exists → <directory>/CLAUDE.md` in the directory map.

**Whenever corrected, or you catch a mistake, or find something true that
wasn't written down:**

1. One line, imperative, in that directory's failure log: "Do not run X —
   it causes Y. Do Z instead."
2. Repo-wide lesson → root's log instead; say so in your summary.
3. Log it in the same commit/turn as the fix. Never batch for later.
4. Never delete a superseded line — replace it in place.

**Keeping this current:**

- A directory file past ~250 lines signals splitting the directory, not
  trimming the file — ask before restructuring.
- Anything long and reusable → a skill, referenced by one line, never
  inlined. Never create a directory's `CLAUDE.md` speculatively.

## Self-audit — on demand

Ex runs this manually. When asked: review every `CLAUDE.md` and skill —
**and `README.md`** — for stale map rows, superseded-but-unreplaced log
lines, rails that no longer match reality, and anything over budget.
Report drift, fix what's unambiguous, ask before restructuring.

`README.md` is in scope and easy to forget precisely because it isn't a
`CLAUDE.md`. It is also the only public document here, so a stale claim
in it is a claim made to strangers — it asserted "no open inbound port
except SSH, enforced by UFW" while three ports answered from the
internet.

**Recommend one, unprompted, when:** the failure log gains 3+ entries in
a session, a hard rail needed double-checking against real behavior, or
the repo's structure no longer matches the directory map. One line.

## When you're unsure

Ask before: opening an inbound port, changing tunnel/token/SSH/auth
setup, changing deploy order or rollback behavior, or removing a guard
that looks redundant. State assumptions at the top of your summary.

Ex is not an engineer. Before a non-trivial infra decision — not after —
explain in plain terms what and why, in 1-3 sentences. Hard-rail-adjacent
and destructive changes always; a typo fix doesn't.
