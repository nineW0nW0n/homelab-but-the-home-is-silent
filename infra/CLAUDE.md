Parent: ../.claude/CLAUDE.md

# infra/ — inventory

Real IPs vs. redacted template. That's the whole directory now —
`common/base.yaml` and `nodes/*/node.yaml` (declarative OS/firewall/
resource config nothing ever read) were deleted; nothing in `scripts/` or
`.github/workflows/` parsed them, so they only drifted from what the
scripts actually do. Enforcement lives directly in
`scripts/harden-node.sh` (UFW, sshd, Fail2Ban, and the `DOCKER-USER`
drops + `daemon.json` loopback bind that make rail 1 true),
`scripts/cap-dokploy-resources.sh` (resource caps), and GitHub
Secrets/Variables (host/port/user, resolved at deploy time — see
`.github/workflows/CLAUDE.md`). If node config needs to change, change
the script; there's no yaml layer to edit first.

## Topology

| Node  | Hostname (label only) | Role      |
|-------|-----------------------|-----------|
| vps00 | vps00.maybeit.work    | primary   |
| vps01 | vps01.maybeit.work    | secondary |
| vps02 | vps02.maybeit.work    | secondary |

**These hostnames have no DNS records** (verified 2026-08-16). They are
inventory labels, not resolvable names — never substitute one for an IP
in a script or an ssh command, it will fail confusingly. Use
`inventory.yaml` locally, `VPS0N_HOST` in CI.

All three nodes run their own **independent single-node Swarm** — three
separate swarms, not one cluster. Nothing needs 2377/7946 reachable
between nodes, which is why UFW blocking them breaks nothing.

## Real IPs (rail 5)

`inventory.yaml` is gitignored, real IPs, local/CI use only.
`inventory.example.yaml` is the tracked, redacted template — never
hand-edit it with a real value. Tracked files reference the hostname or
`inventory_ref` key, never a bare IP. CI resolves the actual host from the
`VPS0N_HOST` GitHub secret, not from this directory.

## Failure log

- `common/base.yaml`/`nodes/*/node.yaml` existed as declarative config
  for OS/firewall/resources/dokploy but nothing ever read them — scripts
  hardcoded the same values independently. Deleted rather than wired up:
  3 static nodes don't justify a yaml-parsing layer in POSIX `sh`
  scripts. If node config needs to be data-driven again, that's a real
  design decision, not a resurrection of these files as-is.
