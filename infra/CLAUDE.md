Parent: ../.claude/CLAUDE.md

# infra/: inventory

Two files: `inventory.yaml` (gitignored, the only place real node IPs live,
local and CI use) and the tracked, redacted `inventory.example.yaml` — never
hand-edit a real value into it (rail 5). Tracked files reference the hostname
or `inventory_ref` key, never a bare IP; CI resolves the host from the
`SSH_HOST_VPS0N` secret, not from here.

The old declarative layer (`common/base.yaml`, `nodes/*/node.yaml`:
OS/firewall/resource/dokploy config) was deleted, not wired up — nothing in
`scripts/` or `.github/workflows/` ever parsed it, so it only drifted from
what the scripts do. Enforcement lives in `scripts/harden-node.sh` (UFW, sshd,
Fail2Ban, the `DOCKER-USER` drops and `daemon.json` loopback bind that make
rail 1 true), rail 4's `mem_limit` in every compose file, and GitHub
Secrets/Variables (host/port/user, resolved at deploy time, see
`.github/workflows/CLAUDE.md`). Change the script; there is no yaml to edit
first. Making node config data-driven again is a real design decision -- three
static nodes do not justify a yaml-parsing layer in POSIX `sh` -- not a
resurrection of those files. (Original wording of this and of the root-SSH
supersession below: `docs/superpowers/failure-log-archive.md`.)

## Topology

| Node  | Hostname (label only) | Role      |
|-------|-----------------------|-----------|
| vps00 | vps00.maybeit.work    | primary   |
| vps01 | vps01.maybeit.work    | secondary |
| vps02 | vps02.maybeit.work    | secondary |

**These hostnames have no DNS records** (verified 2026-08-16): inventory
labels, not resolvable names. Never substitute one for an IP in a script or an
ssh command; it fails confusingly. Use `inventory.yaml` locally,
`SSH_HOST_VPS0N` in CI. Swarm is inactive on all three nodes since
2026-08-23 (it existed only for Dokploy), so nothing needs 2377/7946 open
between them.

## Human SSH access

Each node accepts **one key named after it**, `~/.ssh/id_ed25519_vps0N`
(pubkey comment `ci-deploy`), as user `deploy`; `deploy.yml` uses the same
keypairs from CI, so a key that works here works there. By convention
`~/.ssh/config` carries a `vps0N` alias per node (forcing that key with
`IdentitiesOnly yes`) and a `vps0N-root` alias for root, so `ssh vps01` is the
normal way in.

**vps01 briefly had a second key and no longer does.** Its `deploy`
`authorized_keys` held `dokploy` alongside `ci-deploy` — the same key Dokploy
uses as `root@` there, added by hand (mtime 2026-08-16). Since `deploy` is in
the `docker` group, that was a second root-equivalent path onto vps01 that
nothing in the repo mentioned. **Removed 2026-08-20**, after confirming from
Dokploy's own database that it connects as `root` on port 22 — so the `deploy`
copy bought nothing. Backup kept on the node as
`authorized_keys.bak.20260820`; root's copy untouched at the time.

| Node  | `deploy` authorized_keys | `root` authorized_keys |
|-------|--------------------------|------------------------|
| vps00 | `ci-deploy`              | `vps-maybeit`          |
| vps01 | `ci-deploy`              | `vps-maybeit`          |
| vps02 | `ci-deploy`              | `vps-maybeit`          |

One key per user per node, read back 2026-08-23. The `dokploy` root key
that sat on vps01/vps02 was removed that day together with its private
half (Dokploy's `/etc/dokploy/ssh` and both `dokploy*` volumes on vps00),
in that order -- an orphaned public key is only harmless once the private
key is provably gone. Pre-removal copy:
`/root/.ssh/authorized_keys.bak.20260823` on each, root-only, public
material only.

**Check the tool's own record before reasoning about how it reaches a
node** -- Dokploy's `server` table on vps00 was the only authoritative
answer to how it connected, and it is what settled the `deploy`-key question.

`~/.ssh/id_ed25519_vps` (comment `vps-maybeit`) is the **root** key, not a
dead one: `root@` accepts it on all three nodes (verified 2026-08-18), and it
is rejected as `deploy@` — which is why ssh config pointing the deploy aliases
at it made `ssh vps01` fail while `-i ~/.ssh/id_ed25519_vps01` worked. Use it
for the provisioning scripts only, and note that
`provision-deploy-user.sh`'s `PUBKEY_FILE` defaults to it while the script
*overwrites* `deploy`'s `authorized_keys`: re-run it with
`PUBKEY_FILE=~/.ssh/id_ed25519_vps0N.pub` or it replaces that node's CI key —
and on vps01 it deletes the `dokploy` key either way (see the failure log).

`deploy` has **no sudo** (rail 6). Anything needing root, in order of
preference:

1. **Docker**, for app-level work: `deploy` is in the `docker` group, which is
   how the vps01 backup scripts read volumes without root.
2. **`root@`** via the `vps0N-root` alias and `~/.ssh/id_ed25519_vps`, for the
   provisioning scripts; `scripts/*.sh` connect as root — via `SSH_USER`,
   hardcoded `root@` in `provision-deploy-user.sh` — and root is the right
   user for them. Root is
   key-only because `harden-node.sh` writes
   `PermitRootLogin prohibit-password` in its drop-in and asserts it with
   `sshd -T` — not because of any Debian default (superseded 2026-08-20; see
   the failure log and the archive).
3. **Nothing else, since 2026-08-23.** Dokploy used to connect as root
   with its own keypair; both halves are deleted (see above).

## Failure log

Incident histories behind these rules: `failure-log` skill (`infra/`).

- **Never state a node's sshd setting from Debian's documented default;
  these are provider images.** `PermitRootLogin yes` sat uncommented on
  all three while this file, `README.md` and a security audit asserted
  `prohibit-password` — false for months, not exploitable, and revealed
  only by `sshd -T` on the box, because `sshd -t` checks syntax, not
  effective values.
- **`provision-deploy-user.sh:38` truncates, it does not append** —
  `printf '%s\n' "$pubkey" > /home/deploy/.ssh/authorized_keys`, so a re-run
  leaves exactly the one key it was handed. Both directions bite: without
  `PUBKEY_FILE` it wipes the node's CI key, and on vps01 it wipes the
  hand-added `dokploy` key regardless. Know the node's full intended key set
  before re-running it.
- **Name the user in an SSH finding, and test both.** A key is rejected
  *for a user*, never in general: "key X is rejected by all three nodes"
  came from testing `~/.ssh/id_ed25519_vps` as `deploy@` only; it is the
  root key and works as `root@` everywhere.
