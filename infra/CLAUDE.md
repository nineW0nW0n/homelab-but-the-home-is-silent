Parent: ../.claude/CLAUDE.md

# infra/ — node & OS config

Docs-as-config for the 3 nodes: OS/resource/firewall/dokploy settings
(`common/base.yaml`, overridden per-node in `nodes/<name>/node.yaml`) and
the inventory (real IPs vs. redacted template).

## IMPORTANT: not machine-read

`common/base.yaml` and `nodes/*/node.yaml` are **documentation only** —
grepped the repo, nothing in `scripts/` or `.github/workflows/` parses
them. Real enforcement lives directly in `scripts/harden-node.sh` (UFW,
sshd, Fail2Ban), `scripts/cap-dokploy-resources.sh` (resource caps), and
GitHub Secrets/Variables (host/port/user, resolved at deploy time — see
`.github/workflows/CLAUDE.md`). If you change a value here, you must also
update the script or secret that actually implements it — the yaml won't
propagate on its own. Don't cite `base.yaml`/`node.yaml` as proof a
setting is live; check the script.

## Topology

| Node  | Hostname             | Role      |
|-------|----------------------|-----------|
| vps00 | vps00.maybeit.work   | primary   |
| vps01 | vps01.maybeit.work   | secondary |
| vps02 | vps02.maybeit.work   | secondary |

## Real IPs (rail 5)

`inventory.yaml` is gitignored, real IPs, local/CI use only.
`inventory.example.yaml` is the tracked, redacted template — never
hand-edit it with a real value. Tracked files reference the hostname or
`inventory_ref` key, never a bare IP. CI resolves the actual host from the
`VPS0N_HOST` GitHub secret, not from this directory.

## Conventions

- New per-node setting → edit `nodes/<name>/node.yaml`, not `base.yaml`,
  unless it applies to all 3 nodes. Never duplicate a common setting
  per-node — override only what differs.
- New YAML file → must pass `yamllint -c ../.yamllint <file>` before
  commit; pre-commit enforces this automatically.

## Failure log

