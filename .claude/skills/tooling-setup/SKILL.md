---
name: tooling-setup
description: Install and configure Biome, yamllint, superpowers, rtk, or caveman for this repo — pinned install commands, hard-railed config values, and the superpowers skill-to-situation mapping. Use when a tool check fails or returns not-found, when biome.json / .yamllint / rtk config.toml is missing or needs changing, when setting up tooling is the task, or when choosing which superpowers skill fits the situation at hand.
---

# Tooling setup

Parent: ../../CLAUDE.md

Five tools, all install-if-missing and pre-approved. Load this skill when
you need it — a tool check fails, a config file is missing, or setup is
the task — not routinely at session start. When you do: check each tool,
install the missing ones with the pinned commands below, say what you
installed in your summary.

> **Sync note.** A near-identical copy of this skill ships with the
> `init-claude` scaffold. If you change a pinned version or a config value
> here, change it there too — or state that the two are now intentionally
> divergent and why. Silent drift between them is the failure mode.

## Biome — linter/formatter (`biomejs/biome`)

Check: `biome --version`. If missing, install it exactly like this —
never `latest`, always pin the exact version you resolve:

```sh
npm view @biomejs/biome version        # resolve current exact version
npm install -g --save-exact @biomejs/biome@<resolved-version>
```

If `biome.json` doesn't exist yet at repo root, create it with exactly
this content (this is the hard-railed config — don't improvise values):

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
with the 1.x ones** — root's failure log records this repo getting each
one wrong:

- `files.includes` with `!` negation, **not** `files.ignore`
- `assist.actions.source.organizeImports`, **not** top-level `organizeImports`
- `linter.rules.preset: "recommended"`, **not** `rules.recommended: true`.
  `biome migrate --write` mis-converts this one to `preset: "none"`, which
  silently disables every lint rule. Check the migrated `linter` block by
  hand; do not trust the tool's output.

Update `$schema` to match whatever exact version you actually installed,
and keep the pre-commit hook's `additional_dependencies` pin
(`@biomejs/biome@<version>`) in step with it — rail 9 is only enforced
because that local hook exists.

This repo does have JS/JSON: `worker/status/`. Biome is already set up
and wired into `.pre-commit-config.yaml`; `biome ci .` finding nothing to
lint in a given run is a pass, not a skip.

## yamllint — linter for YAML / GitOps files (until Biome covers YAML)

This repo is mostly YAML, so this is the linter that actually matters day
to day. Check: `yamllint --version`. If missing, install it:

```sh
pip install --break-system-packages yamllint
# or, if pip is unavailable: apt-get install -y yamllint / brew install yamllint
```

If `.yamllint` doesn't exist yet at repo root, create it with exactly
this content:

```yaml
extends: default

rules:
  line-length:
    max: 120
    level: warning
  document-start: disable
  truthy:
    allowed-values: ["true", "false"]
    check-keys: false   # GitHub Actions' `on:` trigger key isn't a boolean — don't flag it
  indentation:
    spaces: 2
    indent-sequences: consistent
  comments:
    min-spaces-from-content: 1
  key-duplicates: enable
  braces:
    max-spaces-inside: 1
  brackets:
    max-spaces-inside: 1
```

`truthy.check-keys: false` is the one that matters most in this repo —
without it, yamllint misreads `on:` in every `.github/workflows/*.yml`
file as a boolean key and flags it. Don't "fix" this by renaming or
quoting `on:`; the config is what's wrong, not the workflow file.

Run via `pre-commit run --all-files` (already wired in) or standalone:
`yamllint --strict .`.

## Superpowers — workflow skills (`obra/superpowers`)

Check: is the `superpowers` plugin active? If not, install it:

```
/plugin marketplace add obra/superpowers-marketplace
/plugin install superpowers@superpowers-marketplace
```

(Use `/plugin install superpowers@claude-plugins-official` instead if the
official marketplace is already registered — don't register a second
marketplace for the same plugin.)

| Repo situation | Skill | When to invoke |
|---|---|---|
| Ambiguous ask, more than one reasonable approach | `brainstorming` | before writing anything |
| Any change touching `infra/`, `stacks/`, `.github/workflows/`, or a hard rail | `writing-plans` | before touching the file(s) |
| A plan already exists | `executing-plans` | carrying it out |
| A deploy, lint, or script run fails | `systematic-debugging` | root-cause it — never just retry |
| Independent per-node or per-script work | `subagent-driven-development`, `dispatching-parallel-agents` | work that doesn't share state across nodes/scripts |
| Before reporting a task done | `verification-before-completion` | every task, no exceptions — this is the gate |
| Any structural or hard-rail change | `using-git-worktrees`, `finishing-a-development-branch` | isolate risky infra changes from `main` |
| Opening or responding to a PR touching a hard rail | `requesting-code-review`, `receiving-code-review` | before merge |
| You keep repeating the same ad hoc instructions | `writing-skills` | propose a new skill instead of repeating yourself |

`test-driven-development` doesn't apply directly — there's no application
code here to unit test. Its spirit still applies: confirm `pre-commit` /
`shellcheck` actually fails for the right reason before you fix it, don't
assume.

## RTK — token budget on shell output (`rtk-ai/rtk`)

Check: `rtk --version`. If missing, install it:

```sh
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
rtk init -g          # wires the Claude Code PreToolUse hook; restart after this
```

Config is hard-railed at `~/.config/rtk/config.toml` — create it with
these values if it doesn't already have them:

```toml
[hooks]
exclude_commands = ["curl", "playwright"]

[tee]
enabled = true
mode = "failures"
```

`exclude_commands` stays as-is unless a command's *filtered* output has
actually caused you to miss something — if that happens, add the command
here, log why in root's failure log, and say so in your summary.
`tee.mode = "failures"` keeps unfiltered output on disk when a command
fails, so you can re-read the full result without re-running it.

Once set up, prefix bash commands whose full output you don't need
verbatim: `rtk git status`, `rtk git diff`, `rtk git log`, docker/compose
inspection. Read, Grep, and Glob tool calls bypass rtk by design — no
action needed there. Run `rtk gain` at the end of a long session to
report savings; not required per task.

## Caveman — terse output (`juliusbrussee/caveman`)

Check: is `/caveman` available? If not, install it:

```sh
curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash
```

Configured level, hard-railed: run `/caveman full` at the start of a
session, not `ultra` or `wenyan`. This repo's output often *is* the exact
flag or error that matters, and those two levels risk losing that
precision — `full` still preserves commands, flags, and error strings
byte-for-byte. Use `/caveman-commit` for commit messages.

Never run `/caveman-compress` on this file, root's `CLAUDE.md`, or any
directory `CLAUDE.md` without flagging it to Ex first. Compression of a
memory file changes its phrasing in a way that's hard to fully undo —
fine for throwaway output, not fine for the files that encode hard rails
without a human sign-off.
