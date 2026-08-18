Parent: ../.claude/CLAUDE.md

# infra/: inventory

Real IPs vs. redacted template. That's the whole directory now.
`common/base.yaml` and `nodes/*/node.yaml` (declarative OS/firewall/
resource config nothing ever read) were deleted; nothing in `scripts/` or
`.github/workflows/` parsed them, so they only drifted from what the
scripts actually do. Enforcement lives directly in
`scripts/harden-node.sh` (UFW, sshd, Fail2Ban, and the `DOCKER-USER`
drops + `daemon.json` loopback bind that make rail 1 true),
`scripts/cap-dokploy-resources.sh` (resource caps), and GitHub
Secrets/Variables (host/port/user, resolved at deploy time, see
`.github/workflows/CLAUDE.md`). If node config needs to change, change
the script; there's no yaml layer to edit first.

## Topology

| Node  | Hostname (label only) | Role      |
|-------|-----------------------|-----------|
| vps00 | vps00.maybeit.work    | primary   |
| vps01 | vps01.maybeit.work    | secondary |
| vps02 | vps02.maybeit.work    | secondary |

**These hostnames have no DNS records** (verified 2026-08-16). They are
inventory labels, not resolvable names. Never substitute one for an IP
in a script or an ssh command; it will fail confusingly. Use
`inventory.yaml` locally, `VPS0N_HOST` in CI.

All three nodes run their own **independent single-node Swarm**: three
separate swarms, not one cluster. Nothing needs 2377/7946 reachable
between nodes, which is why UFW blocking them breaks nothing.

## Real IPs (rail 5)

`inventory.yaml` is gitignored, real IPs, local/CI use only.
`inventory.example.yaml` is the tracked, redacted template. Never
hand-edit it with a real value. Tracked files reference the hostname or
`inventory_ref` key, never a bare IP. CI resolves the actual host from the
`VPS0N_HOST` GitHub secret, not from this directory.

## Failure log

- "Key X is rejected by all three nodes" was recorded on 2026-08-18 after
  testing `~/.ssh/id_ed25519_vps` as `deploy@` only. It is the root key and
  works as `root@` on every node. A key is rejected *for a user*, never in
  general: name the user in the finding, and test both before writing one
  down.
- `common/base.yaml`/`nodes/*/node.yaml` existed as declarative config
  for OS/firewall/resources/dokploy but nothing ever read them; scripts
  hardcoded the same values independently. Deleted rather than wired up:
  3 static nodes don't justify a yaml-parsing layer in POSIX `sh`
  scripts. If node config needs to be data-driven again, that's a real
  design decision, not a resurrection of these files as-is.

## Human SSH access

Each node accepts **one key, named after it**: `~/.ssh/id_ed25519_vps0N`
(public-key comment `ci-deploy`), user `deploy`. `~/.ssh/config` has a host
alias per node, so `ssh vps01` is the normal way in. The same keypair is what
`deploy.yml` uses from CI, so a key that works here works there.

`~/.ssh/id_ed25519_vps` (comment `vps-maybeit`) is the **root** key, not a
dead one: `root@` on all three nodes accepts it (verified 2026-08-18 on
`vps00`, `vps01` and `vps02`). It is rejected as `deploy@`, which is what an
earlier check tested, and why the ssh config pointing every deploy alias at it
made `ssh vps01` fail while `-i ~/.ssh/id_ed25519_vps01` worked. Use it only
for the provisioning scripts; the per-node keys are the day-to-day path.

`deploy` has **no sudo** (rail 6). Anything needing root has three paths, in
order of preference:

1. **Docker**, for app-level work: `deploy` is in the `docker` group, which is
   how the vps01 backup script reads volumes without root.
2. **`root@` with `~/.ssh/id_ed25519_vps`**, for the provisioning scripts.
   `scripts/*.sh` default to `SSH_USER=root` and that default is correct;
   `sshd` keeps Debian's `PermitRootLogin prohibit-password`, which
   `harden-node.sh` does not change, so root is key-only. Add a
   `Host vps0N-root` alias per node pointing at this key, since the plain
   `vps0N` aliases force the deploy key with `IdentitiesOnly yes`.
3. **Dokploy**, which connects as root with its own keypair generated during
   Remote Server setup, held on vps00 and not on any laptop. It is the second
   key in `/root/.ssh/authorized_keys` on vps01 and vps02; vps00 has only the
   `vps-maybeit` key.
