Parent: ../.claude/CLAUDE.md

# scripts/: provisioning & bootstrap

Idempotent POSIX `sh`, one-time-per-node unless noted. `shellcheck -s sh`
clean is the bar (pre-commit enforces it). Run twice, confirm the second
run is a no-op, before calling a script change done.

## Scripts

- `provision-deploy-user.sh`: creates the `deploy` CI user + rsync,
  no sudo, key-only (rail 6).
- `install-docker.sh`: Docker Engine only, no Dokploy.
- `bootstrap-dokploy.sh`: one-time, vps00 only, installs the Dokploy
  control plane. Needs `VPS00_HOST` in `.env` or the environment.
  vps01/vps02 join later via the Dokploy dashboard (Settings > Servers >
  Add Server), a different flow, not this script. Dokploy's Remote
  Servers connects as **root** (its own keypair, added to
  `authorized_keys` manually during dashboard setup), not `deploy`,
  which has no sudo.
- `harden-node.sh <host>`: UFW (deny-all-incoming except 22), sshd
  (`PasswordAuthentication no`, `UsePAM no`, in
  `sshd_config.d/00-hardening.conf`, asserted with `sshd -T` at the end of
  the run), Fail2Ban (aggressive sshd jail). Already applied to all 3 nodes,
  but the `00-` name and the assertion post-date that: re-run it.
- `add-swap.sh <host>`: 2GB swapfile, `vm.swappiness=10`. Nodes have no
  swap by default. Already applied to all 3.
- `cap-dokploy-resources.sh <host>`: memory-caps Dokploy's own control
  plane (not app workloads; those get `mem_limit` in their own compose,
  rail 4).
- `setup-maintenance.sh <host>` — caps docker container log growth
  (`daemon.json` log-opts, 10m x 3 files/container), caps journald disk
  use (`SystemMaxUse=200M`, restarted immediately), drops a weekly
  `/etc/cron.d/docker-prune` (Sunday 03:00, images/containers/build
  cache older than 7d, never touches volumes), and enables
  `unattended-upgrades` (Debian's shipped security-only origins, not
  overridden). No RAM-freeing cron —
  dropping page cache doesn't free anything real; swap
  (`add-swap.sh`) + Dokploy caps already cover memory pressure.

## Failure log

- These node images ship without `rsyslog`. Fail2Ban's default sshd jail
  backend has nothing to tail, exits immediately with "Have not found any
  log file for sshd jail." Set `backend = systemd` in `harden-node.sh`'s
  jail config.
- `UsePAM no` makes sshd check `/etc/shadow` itself instead of delegating
  to PAM, and that check rejects pubkey auth on a **locked** account even
  with a valid key. `provision-deploy-user.sh` used `passwd -l` (locked
  marker), which worked under `UsePAM yes` and broke every CI deploy the
  instant `UsePAM no` landed (`Permission denied (publickey)`). Fixed:
  `passwd -d` (empty password field), not vetoed by the shadow check,
  and `PasswordAuthentication no` already blocks password login either
  way. Always run `provision-deploy-user.sh` after `harden-node.sh` (or
  re-run it) if a node was provisioned before hardening.
- Dokploy's control plane was uncapped by default: `dokploy` alone
  observed at ~913MiB on a 1.9GiB node before capping. Two different cap
  mechanisms, don't mix up: `dokploy`/`dokploy-postgres` are Swarm
  services (`docker service update --limit-memory`; plain `docker update`
  gets silently reconciled away); `dokploy-traefik` is a plain container
  (`docker update --memory`; `docker service update` 404s on it). None of
  this is declarative. Installed by `bootstrap-dokploy.sh`'s upstream
  installer, so caps must be reapplied after any Dokploy reinstall or
  upgrade.
- `cap-dokploy-resources.sh` only ever worked on vps00. Its remote
  payload runs under `set -eu` and opened with
  `docker service update ... dokploy`, but `dokploy` and
  `dokploy-postgres` are vps00-only Swarm services, so on vps01/vps02 the
  script aborted on its first line and never reached the
  `dokploy-traefik` cap. That is why traefik was capped on vps00 and
  unbounded on both secondaries for as long as anyone had run it there.
  Each cap is now guarded: a missing target is skipped with a message,
  not fatal. When a provisioning script targets "every node", check what
  is actually present on the secondaries -- vps00 has the control plane,
  they do not.
- A transient memory spike (app startup, migrations) on a no-swap node is
  a hard OOM-kill, not a slowdown. Misdiagnosed once as a Calcom "build
  process" failure on vps01 when it was actually an OOM kill under a
  too-tight `mem_limit`. `add-swap.sh` fixes the swap side; the app's own
  `mem_limit`/`mem_reservation` (rail 4) still needs headroom.
- Never put a real node IP in a script's usage example. Five scripts here
  did, publishing two nodes' addresses in a public repo next to a full
  description of what runs on them. Use RFC 5737 documentation addresses
  (`203.0.113.10` vps00-shaped, `.11` vps01-shaped, `.12` vps02-shaped) and
  point at `infra/inventory.yaml` for the real ones. Enforced by the
  `no-real-ips` local pre-commit hook. Rail 5 was a sentence with
  nothing checking it, same drift class as rail 9.
- UFW does not govern Docker-published ports. Docker's `nat`/`DOCKER`
  rules are evaluated before ufw's chains, so `ufw status` showing only
  22 while 80/443/3000 answer from the internet is the expected
  symptom, not a contradiction. Filter in `DOCKER-USER` (and
  `DOCKER-INGRESS` for ingress-mode Swarm publishes, which
  `harden-node.sh` does **not** cover). Never treat `ufw status` as a
  statement about real exposure. Sweep the ports from off-node.
- Do not persist `DOCKER-USER` rules with `iptables-persistent`: its
  boot-time restore races Docker creating the chain. `harden-node.sh`
  installs a systemd oneshot ordered `After=docker.service`
  (`docker-wan-drop.service`) instead, which cannot lose that race.
  Verified across a real vps02 reboot, not assumed.
- sshd keeps the **first** value it obtains for each keyword, and Debian 12's
  `/etc/ssh/sshd_config` opens with `Include /etc/ssh/sshd_config.d/*.conf`,
  globbed in lexical order. A provider-shipped `50-cloud-init.conf` with
  `PasswordAuthentication yes` therefore beat the old `99-hardening.conf`
  outright, and `sshd -t` could never reveal it: it checks syntax, not which
  drop-in won. Renamed to `00-hardening.conf` and the *effective* config is
  now asserted with `sshd -T`. Before re-running the script on a node, run
  `sshd -T | grep -E '^(passwordauthentication|usepam) '` — after the rename
  the evidence is gone. `passwordauthentication yes` means password login was
  open on 22 for real, not just misconfigured. Fifth instance of the
  check-that-never-ran class; here the check ran and answered a different
  question than the one being asked.
- The `00-hardening.conf` drop-in owns `PermitRootLogin` too, and the `sshd -T`
  assertion requires `prohibit-password`. Measured 2026-08-20: the provider
  image sets `PermitRootLogin yes` at line 33 of `/etc/ssh/sshd_config`, so the
  Debian default this repo assumed never applied. `Include` sits at line 12,
  ahead of it, so the drop-in wins. `prohibit-password` keeps key-based root
  login, which these scripts and Dokploy's Remote Server connection both need.
- Write a replacement drop-in **before** `rm`-ing the old name, never after.
  The interrupted state must be "both files" (identical content, `00-` wins),
  never "neither" — neither means no hardening drop-in at all, and Debian's
  compiled-in default is `PasswordAuthentication yes`.
- Order `harden-node.sh` by what it costs to skip: UFW, sshd, `DOCKER-USER`
  (rail 1), then Fail2Ban, then assertions. Under `set -eu` every step is an
  abort point for everything below it, so anything that can fail on node state
  the script does not control belongs *after* rail 1, not before. Fail2Ban's
  own start is exactly that — see the `backend = systemd` entry above — and it
  used to sit two blocks ahead of the `DOCKER-USER` rules, where a failed jail
  would silently leave published ports unfiltered. The `sshd -T` assertion is
  last for the same reason. sshd itself stays early and is the one accepted
  exception: it is gated by `sshd -t` on static content.
- `systemctl enable --now` does not re-run a `RemainAfterExit=yes` oneshot
  that is already active, so an updated `docker-wan-drop.sh` payload lands on
  disk unapplied while the run prints the *old* rule and looks like it
  worked. Use `enable` + `restart` when the payload can change.
- Because `00-hardening.conf` sorts first, a later drop-in can no longer
  override it: dropping a `10-emergency.conf` to re-enable password auth does
  nothing. Recovery from the provider console is to edit
  `00-hardening.conf` itself.
- `harden-node.sh` writes `/etc/docker/daemon.json` but deliberately
  never restarts Docker: on vps00 that restarts the Swarm control
  plane and every container. The loopback-bind layer is therefore
  inactive until the next Docker restart or reboot; the `DOCKER-USER`
  drops are active immediately, so the node is closed either way.
- `daemon.json`'s `"ip": "127.0.0.1"` does **not** apply to a Swarm
  service's host-mode publish. Measured on vps00 after a reboot with
  the setting active: `dokploy-traefik` (plain container) moved to
  `127.0.0.1:80`/`127.0.0.1:443`, but the `dokploy` service's port 3000
  still binds `0.0.0.0` **and** `[::]`. So on vps00, port 3000 is
  closed by the `DOCKER-USER` rule *alone*: the second layer does not
  back it up there. If `docker-wan-drop.service` ever fails to start,
  3000 is open to the internet with only the Dokploy admin password in
  front of it. Check `systemctl is-active docker-wan-drop` before
  trusting a port sweep taken from inside the node.
- `install-docker.sh` no longer pipes `get.docker.com` into a root
  shell; it configures Docker's apt repo and keyring directly. That is
  the same end state the convenience script produced (verified against
  a node it had already provisioned), but packages are GPG-verified and
  upgrades come through apt. Untested on a fresh node (all three were
  already provisioned when it changed): if a new node is ever built,
  watch this step rather than assuming it.
- `bootstrap-dokploy.sh` still runs a vendor installer. Dokploy has no
  apt repo. It now downloads to a file and prints the sha256 before
  executing. That is a *record*, not a verification: there is no
  published checksum to compare a first run against. Don't upgrade the
  claim when describing it.
