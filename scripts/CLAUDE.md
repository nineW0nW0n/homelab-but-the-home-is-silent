Parent: ../.claude/CLAUDE.md

# scripts/: provisioning & bootstrap

Idempotent POSIX `sh`, one-time-per-node unless noted. `shellcheck -s sh`
clean is the bar (pre-commit enforces it). Run twice, confirm the second
run is a no-op, before calling a script change done.

## Scripts

- `provision-deploy-user.sh <node> <host>`: `deploy` CI user, key-only, no
  sudo (rail 6); installs rsync; owns `/opt/stacks/<node>`.
- `install-docker.sh <host>`: Docker Engine from Docker's apt repo, no
  Dokploy.
- `bootstrap-dokploy.sh`: one-time, vps00 only, installs the Dokploy
  control plane; needs `VPS00_HOST` in `.env` or the environment.
  vps01/vps02 instead join via the dashboard (Settings > Servers > Add
  Server), a different flow, not this script — and that connection is as
  **root** (Dokploy's own keypair, pasted into `authorized_keys` by hand
  during setup), not `deploy`, which has no sudo.
- `harden-node.sh <host>`, in this order: UFW (deny incoming except 22);
  sshd (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin prohibit-password`, `UsePAM no`, in
  `sshd_config.d/00-hardening.conf`); rail 1's `DOCKER-USER` drops
  (`docker-wan-drop.service`) plus `daemon.json`'s loopback bind; Fail2Ban
  (aggressive sshd jail); an `sshd -T` assertion on the effective config.
  Applied to all 3 nodes, but the `00-` name, `PermitRootLogin` and the
  assertion post-date that: re-run it.
- `add-swap.sh <host> [size_gb]`: swapfile, 2G default, `vm.swappiness=10`.
  Nodes have no swap by default. Applied to all 3.
- `cap-dokploy-resources.sh <host>`: memory-caps Dokploy's own control
  plane, not app workloads (those get `mem_limit` in their compose, rail
  4). `dokploy` 1024M/512M, `dokploy-postgres` 320M/128M,
  `dokploy-traefik` 128m with 256m memory+swap.
- `setup-maintenance.sh <host>`: caps container logs (`daemon.json`
  log-opts, 10m x 3 files each), caps journald (`SystemMaxUse=200M`,
  restarted immediately), drops a weekly `/etc/cron.d/docker-prune`
  (Sunday 03:00, `docker system prune -af --filter until=168h`, never
  volumes), enables `unattended-upgrades` (Debian's shipped security-only
  origins, never overridden). No RAM-freeing cron: dropping page cache
  frees nothing real, and swap plus the Dokploy caps cover memory pressure.

## Failure log

Incident histories behind these rules: `failure-log` skill (`scripts/`).

- **Fail2Ban needs `backend = systemd`** — no `rsyslog` here, so the
  default sshd backend finds no log and exits. Retry `fail2ban-client`
  for 10s: it races its own socket after a restart.
- **Use `passwd -d`, never `passwd -l`, on the deploy user** — under
  `UsePAM no` sshd's own `/etc/shadow` check rejects pubkey auth on a
  locked account, which broke every CI deploy. Re-run
  `provision-deploy-user.sh` after `harden-node.sh`.
- **The sshd drop-in is `00-hardening.conf`, asserted with `sshd -T`** —
  sshd keeps the *first* value per keyword, so a lexically earlier
  provider drop-in wins outright, and `sshd -t` checks syntax, not who
  won. It sets `PermitRootLogin prohibit-password` explicitly too: these
  provider images ship `yes` uncommented.
- **Nothing can override `00-`** — no later drop-in can re-open password
  auth, so recover by editing that file from the provider console. Write
  a replacement *before* `rm`-ing an old name: neither file means no
  hardening at all.
- **Assert `permitrootlogin` against both spellings** — `sshd -T`
  normalises `prohibit-password` to `without-password`.
- **`harden-node.sh` order is UFW, sshd, `DOCKER-USER`, Fail2Ban,
  assertions** — under `set -eu` anything that can fail on node state must
  sit *after* rail 1, or it leaves published ports unfiltered.
- **Never read `ufw status` as real exposure** — Docker's `nat`/`DOCKER`
  rules are evaluated before ufw's chains. Filter in `DOCKER-USER`, plus
  `DOCKER-INGRESS` for ingress-mode Swarm publishes, which
  `harden-node.sh` does **not** cover. Sweep the ports from off-node.
- **Never persist `DOCKER-USER` rules with `iptables-persistent`** — its
  boot restore races Docker creating the chain; use the
  `docker-wan-drop.service` oneshot, `After=docker.service`. Three things
  in it are load-bearing: `-w 5` on every call, exit 1 on a missing IPv4
  chain, and install with `enable` + `restart`, never `enable --now`.
- **The `daemon.json` loopback bind is inactive until Docker restarts,**
  which `harden-node.sh` deliberately never does; the `DOCKER-USER` drops
  close the node meanwhile. `"ip"` also misses Swarm host-mode publishes,
  so vps00's 3000 rests on that one rule — check `systemctl is-active
  docker-wan-drop` before trusting a sweep taken from inside the node.
- **Two scripts write `daemon.json`** — `setup-maintenance.sh` recognises
  harden's by an exact match on `{"ip":"127.0.0.1"}`; change what either
  writes, fix the other's match in the same commit.
- **A `docker-ce` upgrade does not flush `DOCKER-USER`** — Docker creates
  that chain when absent and never rewrites it, so rail 1 survives and
  `unattended-upgrades` is safe here.
- **Reapply Dokploy's memory caps after any reinstall or upgrade** — none
  of it is declarative — and by the right mechanism: Swarm services take
  `docker service update --limit-memory` (plain `docker update` is
  silently reconciled away), `dokploy-traefik` takes `docker update
  --memory`.
- **A script targeting "every node" must skip a missing target, not die**
  — `cap-dokploy-resources.sh` opened with a vps00-only service under
  `set -eu`, so traefik went uncapped on both secondaries.
- **On a no-swap node a transient memory spike is a hard OOM kill,** not
  a slowdown, and it does not announce itself as one. `add-swap.sh`, plus
  real headroom in rail 4's limits.
- **Never put a real node IP in a usage example** — five scripts did, in
  a public repo. Use RFC 5737 (`203.0.113.10/.11/.12`) and point at
  `infra/inventory.yaml`; enforced by the `no-real-ips` hook.
- **`install-docker.sh` uses Docker's apt repo, not `get.docker.com | sh`**
  — GPG-verified packages, upgrades via apt. Untested on a fresh node.
- **`bootstrap-dokploy.sh`'s printed sha256 is a record, not a
  verification** — Dokploy publishes no checksum to compare against, so
  don't upgrade the claim.
