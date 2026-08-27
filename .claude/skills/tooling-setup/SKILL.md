---
name: tooling-setup
description: Install and configure Biome, yamllint, superpowers, rtk, or caveman for this repo. Pinned install commands, hard-railed config values, the skill-to-situation mapping, and what each Cloudflare MCP server can and cannot verify. Use when a tool check fails or returns not-found, when biome.json / .yamllint / rtk config.toml is missing or needs changing, when setting up tooling is the task, when choosing which skill fits the situation at hand, or before reaching for a Cloudflare MCP server.
---

# Tooling setup

Parent: ../../CLAUDE.md

Five tools, all install-if-missing and pre-approved. Load this skill when
you need it: a tool check fails, a config file is missing, or setup is
the task, not routinely at session start. When you do: check each tool,
install the missing ones with the pinned commands below, say what you
installed in your summary.

> **Sync note.** A near-identical copy of this skill ships with the
> `init-claude` scaffold. If you change a pinned version or a config value
> here, change it there too, or state that the two are now intentionally
> divergent and why. Silent drift between them is the failure mode.

## Biome: linter/formatter (`biomejs/biome`)

Check: `biome --version`. If missing, install it exactly like this:
never `latest`, always pin the exact version you resolve:

```sh
npm view @biomejs/biome version        # resolve current exact version
npm install -g --save-exact @biomejs/biome@<resolved-version>
```

If `biome.json` doesn't exist yet at repo root, create it with exactly
this content (this is the hard-railed config; don't improvise values):

```json
{
  "$schema": "https://biomejs.dev/schemas/2.5.8/schema.json",
  "vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
  "files": {
    "ignoreUnknown": false,
    "includes": ["**", "!**/node_modules", "!**/dist", "!**/build"]
  },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2, "lineWidth": 100 },
  "assist": { "actions": { "source": { "organizeImports": "on" } } },
  "linter": { "enabled": true, "rules": { "preset": "recommended" } },
  "javascript": {
    "formatter": { "quoteStyle": "single", "semicolons": "asNeeded", "trailingCommas": "all" }
  },
  "json": { "formatter": { "enabled": true } }
}
```

**Three keys here are the 2.x spellings and they are not interchangeable
with the 1.x ones**: root's failure log records this repo getting each
one wrong:

- `files.includes` with `!` negation, **not** `files.ignore`
- `assist.actions.source.organizeImports`, **not** top-level `organizeImports`
- `linter.rules.preset: "recommended"`, **not** `rules.recommended: true`.
  `biome migrate --write` mis-converts this one to `preset: "none"`, which
  silently disables every lint rule. Check the migrated `linter` block by
  hand; do not trust the tool's output.

Update `$schema` to match whatever exact version you actually installed,
and keep the pre-commit hook's `additional_dependencies` pin
(`@biomejs/biome@<version>`) in step with it: rail 9 is only enforced
because that local hook exists.

Verified 2026-08-20: `biome.json`'s `$schema`, the `biome-ci` hook's
`additional_dependencies` in `.pre-commit-config.yaml`, and the installed
binary are all **2.5.8**. Upstream's latest was 2.5.9 that day — that is
not drift, it is a pin. Bump all three in one commit or none.

This repo does have JS/JSON: `worker/status/`. Biome is already set up
and wired into `.pre-commit-config.yaml`; `biome ci .` finding nothing to
lint in a given run is a pass, not a skip.

## yamllint: linter for YAML / GitOps files (until Biome covers YAML)

This repo is mostly YAML, so this is the linter that actually matters day
to day. Check: `yamllint --version`. If missing, install it:

```sh
pip3 install --break-system-packages yamllint==1.38.0
```

Plain `pip` is not on `PATH` on this machine (Homebrew Python); `pip3` is.

Pinned, like everything else here: root's failure log says never `latest`
for Biome, rtk, caveman or yamllint. `apt-get install -y yamllint` and
`brew install yamllint` are fallbacks only when pip is unavailable — they
install whatever the distro happens to ship, so record the version you got
and expect lint results to differ from CI's. (Measured 2026-08-20: the
local `yamllint` is 1.38.0 from Homebrew, which happens to match the pin.)

**The version that actually gates is the pre-commit hook `rev`, not your
local install.** `.pre-commit-config.yaml` pins
`adrienverge/yamllint` at `v1.35.1` while this skill installs 1.38.0, so a
rule whose behaviour changed between those two releases can pass locally
and fail in `validate.yml`, or the reverse. Known divergence as of
2026-08-20, left as-is deliberately (bumping a gate rev is Ex's call); if
you bump one, bump both in the same commit.

If `.yamllint` doesn't exist yet at repo root, create it with exactly
this content (hard-railed, byte-for-byte from this repo's `.yamllint`;
don't improvise values):

```yaml
---
extends: default

yaml-files:
  - "*.yaml"
  - "*.yml"
  - ".yamllint"

ignore:
  - .git/
  - node_modules/

rules:
  line-length:
    max: 120
    level: error
  document-start:
    present: true
  comments:
    min-spaces-from-content: 1
  comments-indentation: enable
  indentation:
    spaces: 2
    indent-sequences: true
    check-multi-line-strings: false
  truthy:
    allowed-values: ["true", "false"]
    check-keys: false
  braces:
    max-spaces-inside: 1
    min-spaces-inside: 0
  brackets:
    max-spaces-inside: 1
    min-spaces-inside: 0
  empty-lines:
    max: 1
    max-start: 0
    max-end: 0
  trailing-spaces: enable
  new-line-at-end-of-file: enable
  key-duplicates: enable
```

Every value here is load-bearing and several differ from yamllint's
defaults on purpose: `document-start.present: true` and
`line-length.level: error` are enforced, not warnings, and
`indent-sequences: true` is stricter than `consistent`. An earlier version
of this skill listed the looser variants, which would have silently
weakened the gate on the next new YAML file — exactly the drift the Biome
section warns about one heading up.

`truthy.check-keys: false` is the one that matters most in this repo:
without it, yamllint misreads `on:` in every `.github/workflows/*.yml`
file as a boolean key and flags it. Don't "fix" this by renaming or
quoting `on:`; the config is what's wrong, not the workflow file.

Run via `pre-commit run --all-files` (already wired in) or standalone:
`yamllint --strict .`.

## Superpowers: workflow skills (`obra/superpowers`)

Check: is the `superpowers` plugin active? If not, install it:

```
/plugin install superpowers@claude-plugins-official
```

The official marketplace is the one already registered here, and
`superpowers@claude-plugins-official` **6.3.0** is what is installed
(verified 2026-08-20). Only if that marketplace is absent:

```
/plugin marketplace add obra/superpowers-marketplace
/plugin install superpowers@superpowers-marketplace
```

Never register a second marketplace for a plugin you already have.

| Repo situation | Skill | When to invoke |
|---|---|---|
| Ambiguous ask, more than one reasonable approach | `brainstorming` | before writing anything |
| Any change touching `infra/`, `stacks/`, `.github/workflows/`, or a hard rail | `writing-plans` | before touching the file(s) |
| A plan already exists | `executing-plans` | carrying it out |
| A deploy, lint, or script run fails | `systematic-debugging` | root-cause it, never just retry |
| Independent per-node or per-script work | `subagent-driven-development`, `dispatching-parallel-agents` | work that doesn't share state across nodes/scripts |
| Before reporting a task done | `verification-before-completion` | every task, no exceptions, this is the gate |
| Any structural or hard-rail change | `using-git-worktrees`, `finishing-a-development-branch` | isolate risky infra changes from `main` |
| Opening or responding to a PR touching a hard rail | `requesting-code-review`, `receiving-code-review` | before merge |
| You keep repeating the same ad hoc instructions | `writing-skills` | propose a new skill instead of repeating yourself |
| PR touches a hard rail or a `docs/superpowers/specs/` item | `code-review` | before merge; it reviews Standards and Spec, and this repo has both as literal artifacts — 12 rails, per-directory `CLAUDE.md`, the specs dir |
| PR touches `harden-node.sh`, a token/secret path, or an Access policy | `security-review` | before merge; rails 1, 2, 6, 11 |
| Editing any `CLAUDE.md` or any skill | `writing-for-agents` | before the edit — and root's propagation protocol wins on any conflict with it |
| A step only Ex can do in a dashboard: Access app, tunnel public hostname, GitHub repo secret, R2 lock rule | `wizard` | instead of writing those steps as prose in a handoff; Ex is not an engineer and wants direct links |
| Narrowing an Access policy, adding a public hostname, or telling a 530 (tunnel never connected) from a 403 (Access) | `cloudflare:cloudflare-one` | before changing Access or Tunnel config |
| You are about to run `wrangler secret put`, `r2 bucket lock add`, `kv`, or `dev` | `cloudflare:wrangler` | before the command; wrangler is pinned at 4.123.0 in `worker/status/package.json` |
| Reading logs: what a container logged, debugging an app error after the fact, checking log ingestion | `query-logs` | before querying OpenObserve; it has the payload shape and field-name gotchas |

`test-driven-development` doesn't apply directly: there's no application
code here to unit test. Its spirit still applies: confirm `pre-commit` /
`shellcheck` actually fails for the right reason before you fix it, don't
assume.

**Deliberately not used here, so don't re-litigate it:**
`cloudflare:cloudflare` (a superset of `wrangler` + `cloudflare-one` +
docs, at more context than the three of them); `durable-objects`,
`agents-sdk`, `cloudflare:turnstile-spin`,
`cloudflare:cloudflare-email-service`, `sandbox-*` (none of that
exists in this repo); the design skills `theme-factory`,
`ui-ux-pro-max`, `frontend-design`, `design`, `banner-design`, `dataviz`
(`page.html` is a verbatim copy from `nineW0nW0n/maybeitwork-site` —
designing here forks the design repo); and `diagnosing-bugs`, which
duplicates `superpowers:systematic-debugging`, already mapped above.
Two debugging skills means neither one is the rail.

## Cloudflare MCP servers

The connected servers are not equally useful here. Everything below was
measured against this account, not read off a doc page.

- **`cloudflare-api`** (`search` + `execute`) — the workhorse. Access
  apps, policies and service-token *names*; `cfd_tunnel` list plus
  per-tunnel ingress; DNS records; WAF custom rules; rulesets; Worker
  deployment history and settings. `accountId` is pre-set inside
  `execute` — use it directly, don't go looking for the account id.
- **`cloudflare-bindings`** — `workers_list`, `kv_namespaces_list`,
  `r2_buckets_list`, `workers_get_worker_code`. Keep it for
  `workers_get_worker_code` (see the proof below); the rest is covered
  by `cloudflare-api`.
- **`cloudflare-docs`** (`search_cloudflare_documentation`) — use it for
  exact config *spellings* pinned to current syntax. This repo's
  recurring failure is a config key pinned to the wrong major version —
  `biome.json`'s `preset: "none"` — and that is exactly what this kills.
  It is not a substitute for the real doc page when precision matters:
  it returns duplicated changelog chunks with no per-chunk version
  metadata.
- **`cloudflare-observability`** — works, as of 2026-08-20. Filter on
  `$metadata.service = maybeit-status`; retention is 7 days. Measured
  that day: 29 events over 24h. The empty result set before then was
  absent config, not absent traffic — `worker/status/wrangler.toml`'s
  `[observability]` block is what changed, and its own comment records
  it.
- **`cloudflare-builds`** — dead weight here. Workers Builds is
  Cloudflare-side git-connected CI; this repo deploys through
  `deploy-worker.yml` and `wrangler-action`. Measured `total_count: 0`,
  and all 10 deployments report `source: "wrangler"`. Its only working
  tools are duplicated in the other servers.

**Never call `GET /cfd_tunnel/{id}/token`.** It returns secret material,
which is rail 11. Worker settings is the rail-11-safe alternative: it
lists secret bindings by name and type only — `CF_ACCESS_CLIENT_ID`,
`CF_ACCESS_CLIENT_SECRET`, `DEBUG_KEY`, all `secret_text` — never values,
so you can assert the expected secrets exist without printing one.

**`execute` is write-capable**: arbitrary method, DELETE included,
against an account that holds the only off-site backup bucket and the
live tunnels. Root's "ask before changing tunnel/token/SSH/auth setup"
applies to it in full. Read with GET; anything that mutates gets asked
first.

### Now verifiable from Cloudflare, no dashboard needed

Access apps, policies and service-token names; per-tunnel ingress
(hostname → `localhost:PORT`) and catch-all; tunnel health, connector
count and identity, `cloudflared` version; DNS records with proxied
flags; WAF custom rules; the absence of a rate-limit ruleset; Worker
deploy history, settings, and secret-binding names; R2 buckets; KV
namespaces.

### What stays off-Cloudflare

**Rail 1 cannot be checked from Cloudflare at all** — agents get this
wrong. Cloudflare sees only egress-initiated tunnel connections and has
zero view of what listens on a VPS. The one Cloudflare-side signal is
negative: no DNS record routes to a node IP, which proves there is no
public DNS path, *not* that a port is closed. The off-node
`nc -z <ip> <port>` sweep stays the only real check -- `-G 3 -w 3` from
macOS, `-w 3` on Debian, never `-G` there (rail 1). Same
shape as the old `README.md` claim that UFW enforced zero inbound while
three ports answered.

Also off-Cloudflare: whether the tunnel token *files* on each node
actually differ (only live connector identity is visible); Worker **JS**
byte-equality, since it ships esbuild-bundled with comments stripped —
that needs a local `wrangler deploy --dry-run --outdir` and a diff; and
anything behind the tunnel — Netdata internals, container state, container
memory limits, so rail 4 too.

Untested this session, so don't claim these work: R2 object listing and
bucket lock rules, Logpush job config, GraphQL analytics.

### Proving the deployed Worker is a named git ref

Wrangler's `[[rules]] type = "Text"` ships `page.html` as its own module
part in `workers_get_worker_code`'s multipart body, named by the plain
SHA-1 of its content:

```
Content-Disposition: form-data; name="./26b5b1e4904044ab055a9a7c7316a13d2af05a65-page.html"
```

So `git cat-file blob <ref>:worker/status/src/page.html | shasum -a 1`
matching that hash is cryptographic proof that a named git ref is what is
deployed. Verified: `26b5b1e4…`, 162769 bytes, matching commit
`08ba0c90`, deployment stamped `2026-08-20T05:19:41Z`.

Two things to keep doing:

- The response is ~170KB and **blows the tool token limit**. Diff it with
  shell tooling; never read it into context.
- **Pin to an explicit ref** (`git cat-file blob <ref>:<path>`), never
  hash the working tree. Live agent worktrees under `.claude/worktrees/`
  and a concurrently-moving HEAD produced two disagreeing measurements in
  one session.

## RTK: token budget on shell output (`rtk-ai/rtk`)

Check: `rtk --version`. If missing, install it:

```sh
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/v0.45.0/install.sh | sh
rtk init -g          # wires the Claude Code PreToolUse hook; restart after this
```

Pinned to a tag, not `refs/heads/master`: a branch URL re-pipes whatever
upstream pushed that day into a shell. Bump it deliberately —
`gh api repos/rtk-ai/rtk/releases/latest --jq .tag_name` — and record the
new version here. Checked 2026-08-20: `v0.45.0` is both the installed
version and upstream's latest release.

Config lives where rtk itself puts it, which is **not** the same path on
every platform: on macOS it is
`~/Library/Application Support/rtk/config.toml`, on Linux
`~/.config/rtk/config.toml`. This skill claimed the Linux path
unconditionally until 2026-08-19; a config hand-written at
`~/.config/rtk/` on macOS is simply never read. Don't guess the path and
don't hand-create the file: run `rtk config --create`, which writes a
fully-populated default at the correct location and prints it, then edit
the values below in place. (It exits 1 even on success; the "Created:"
line is the real result.)

Hard-railed values, all of them departures from rtk's own defaults:

```toml
[display]
colors = false          # ANSI escapes are tokens that carry no meaning
emoji = false
max_width = 200         # default 120 truncated real paths and error text

[hooks]
exclude_commands = ["curl", "playwright"]

[tee]
enabled = true
mode = "failures"

[limits]
passthrough_max_chars = 4000   # default 2000; a re-run costs more than the chars
```

`display.max_width` is the one that bites: at rtk's default of 120 every
long line of command output is chopped mid-path, which reads as a
complete answer and is not one. Raise it, don't work around it.

`exclude_commands` stays as-is unless a command's *filtered* output has
actually caused you to miss something. If that happens, add the command
here, log why in root's failure log, and say so in your summary.
`tee.mode = "failures"` keeps unfiltered output on disk when a command
fails, so you can re-read the full result without re-running it.

Once set up, prefix bash commands whose full output you don't need
verbatim: `rtk git status`, `rtk git diff`, `rtk git log`, docker/compose
inspection. Read, Grep, and Glob tool calls bypass rtk by design, no
action needed there. Run `rtk gain` at the end of a long session to
report savings; not required per task.

## Caveman: terse output (`juliusbrussee/caveman`)

Check: is `/caveman` available? If not, install it:

```sh
curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/bin-v1.1.1/install.sh | bash
```

Pinned for the same reason as rtk above; bump with
`gh api repos/JuliusBrussee/caveman/releases/latest --jq .tag_name`.
Checked 2026-08-20: `bin-v1.1.1` is still upstream's latest. On this
machine caveman is present as a **plugin** from the `JuliusBrussee/caveman`
marketplace rather than via the installer above; either route gives you
`/caveman`, so check for the command, not for a binary.

Configured level, hard-railed: run `/caveman full` at the start of a
session, not `ultra` or `wenyan`. This repo's output often *is* the exact
flag or error that matters, and those two levels risk losing that
precision: `full` still preserves commands, flags, and error strings
byte-for-byte. Use `/caveman-commit` for commit messages.

Never run `/caveman-compress` on this file, root's `CLAUDE.md`, or any
directory `CLAUDE.md` without flagging it to Ex first. Compression of a
memory file changes its phrasing in a way that's hard to fully undo,
fine for throwaway output, not fine for the files that encode hard rails
without a human sign-off.
