Parent: ../.claude/CLAUDE.md

# scripts/ — provisioning & bootstrap

Idempotent POSIX `sh`, one-time-per-node unless noted. `shellcheck -s sh`
clean is the bar (pre-commit enforces it). Run twice, confirm the second
run is a no-op, before calling a script change done.

## Scripts

- `provision-deploy-user.sh` — creates the `deploy` CI user + rsync,
  no sudo, key-only (rail 6).
- `install-docker.sh` — Docker Engine only, no Dokploy.
- `bootstrap-dokploy.sh` — one-time, vps00 only: installs the Dokploy
  control plane. Needs `VPS00_HOST` in `.env` or the environment.
  vps01/vps02 join later via the Dokploy dashboard (Settings > Servers >
  Add Server), a different flow, not this script. Dokploy's Remote
  Servers connects as **root** (its own keypair, added to
  `authorized_keys` manually during dashboard setup) — not `deploy`,
  which has no sudo.
- `harden-node.sh <host>` — UFW (deny-all-incoming except 22), sshd
  (`PasswordAuthentication no`, `UsePAM no`), Fail2Ban (aggressive sshd
  jail). Already applied to all 3 nodes.
- `add-swap.sh <host>` — 2GB swapfile, `vm.swappiness=10`. Nodes have no
  swap by default. Already applied to all 3.
- `cap-dokploy-resources.sh <host>` — memory-caps Dokploy's own control
  plane (not app workloads — those get `mem_limit` in their own compose,
  rail 4).

## Failure log

- These node images ship without `rsyslog` — Fail2Ban's default sshd jail
  backend has nothing to tail, exits immediately with "Have not found any
  log file for sshd jail." Set `backend = systemd` in `harden-node.sh`'s
  jail config.
- `UsePAM no` makes sshd check `/etc/shadow` itself instead of delegating
  to PAM, and that check rejects pubkey auth on a **locked** account even
  with a valid key. `provision-deploy-user.sh` used `passwd -l` (locked
  marker), which worked under `UsePAM yes` and broke every CI deploy the
  instant `UsePAM no` landed (`Permission denied (publickey)`). Fixed:
  `passwd -d` (empty password field) — not vetoed by the shadow check,
  and `PasswordAuthentication no` already blocks password login either
  way. Always run `provision-deploy-user.sh` after `harden-node.sh` (or
  re-run it) if a node was provisioned before hardening.
- Dokploy's control plane was uncapped by default: `dokploy` alone
  observed at ~913MiB on a 1.9GiB node before capping. Two different cap
  mechanisms, don't mix up — `dokploy`/`dokploy-postgres` are Swarm
  services (`docker service update --limit-memory`; plain `docker update`
  gets silently reconciled away); `dokploy-traefik` is a plain container
  (`docker update --memory`; `docker service update` 404s on it). None of
  this is declarative — installed by `bootstrap-dokploy.sh`'s upstream
  installer, so caps must be reapplied after any Dokploy reinstall or
  upgrade.
- A transient memory spike (app startup, migrations) on a no-swap node is
  a hard OOM-kill, not a slowdown — misdiagnosed once as a Calcom "build
  process" failure on vps01 when it was actually an OOM kill under a
  too-tight `mem_limit`. `add-swap.sh` fixes the swap side; the app's own
  `mem_limit`/`mem_reservation` (rail 4) still needs headroom.
- Never put a real node IP in a script's usage example — five scripts here
  did, publishing two nodes' addresses in a public repo next to a full
  description of what runs on them. Use RFC 5737 documentation addresses
  (`203.0.113.10` vps00-shaped, `.11` vps01-shaped, `.12` vps02-shaped) and
  point at `infra/inventory.yaml` for the real ones. Enforced by the
  `no-real-ips` local pre-commit hook — rail 5 was a sentence with
  nothing checking it, same drift class as rail 9.
- UFW does not govern Docker-published ports. Docker's `nat`/`DOCKER`
  rules are evaluated before ufw's chains, so `ufw status` showing only
  22 while 80/443/3000 answer from the internet is the expected
  symptom, not a contradiction. Filter in `DOCKER-USER` (and
  `DOCKER-INGRESS` for ingress-mode Swarm publishes, which
  `harden-node.sh` does **not** cover). Never treat `ufw status` as a
  statement about real exposure — sweep the ports from off-node.
- Do not persist `DOCKER-USER` rules with `iptables-persistent`: its
  boot-time restore races Docker creating the chain. `harden-node.sh`
  installs a systemd oneshot ordered `After=docker.service`
  (`docker-wan-drop.service`) instead, which cannot lose that race.
  Verified across a real vps02 reboot, not assumed.
- `harden-node.sh` writes `/etc/docker/daemon.json` but deliberately
  never restarts Docker — on vps00 that restarts the Swarm control
  plane and every container. The loopback-bind layer is therefore
  inactive until the next Docker restart or reboot; the `DOCKER-USER`
  drops are active immediately, so the node is closed either way.
- `daemon.json`'s `"ip": "127.0.0.1"` does **not** apply to a Swarm
  service's host-mode publish. Measured on vps00 after a reboot with
  the setting active: `dokploy-traefik` (plain container) moved to
  `127.0.0.1:80`/`127.0.0.1:443`, but the `dokploy` service's port 3000
  still binds `0.0.0.0` **and** `[::]`. So on vps00, port 3000 is
  closed by the `DOCKER-USER` rule *alone* — the second layer does not
  back it up there. If `docker-wan-drop.service` ever fails to start,
  3000 is open to the internet with only the Dokploy admin password in
  front of it. Check `systemctl is-active docker-wan-drop` before
  trusting a port sweep taken from inside the node.
- `install-docker.sh` no longer pipes `get.docker.com` into a root
  shell; it configures Docker's apt repo and keyring directly. That is
  the same end state the convenience script produced — verified against
  a node it had already provisioned — but packages are GPG-verified and
  upgrades come through apt. Untested on a fresh node (all three were
  already provisioned when it changed): if a new node is ever built,
  watch this step rather than assuming it.
- `bootstrap-dokploy.sh` still runs a vendor installer — Dokploy has no
  apt repo. It now downloads to a file and prints the sha256 before
  executing. That is a *record*, not a verification: there is no
  published checksum to compare a first run against. Don't upgrade the
  claim when describing it.
