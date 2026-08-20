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

- No `rsyslog` on these images, so Fail2Ban's default sshd backend has
  nothing to tail and exits with "Have not found any log file for sshd
  jail." Use `backend = systemd`. `fail2ban-client` also races the daemon's
  socket for a second or two after a restart: retry for 10s and warn once,
  rather than printing a meaningless ERROR every run.
- `UsePAM no` makes sshd check `/etc/shadow` itself, and that check rejects
  pubkey auth on a **locked** account even with a valid key.
  `provision-deploy-user.sh`'s `passwd -l` worked under `UsePAM yes` and
  broke every CI deploy (`Permission denied (publickey)`) the instant
  `UsePAM no` landed. Use `passwd -d` (empty password field), which the
  check does not veto; `PasswordAuthentication no` plus the default
  `PermitEmptyPasswords no` block password login anyway. Re-run
  `provision-deploy-user.sh` after `harden-node.sh` on any node hardened
  after it was provisioned.
- sshd keeps the **first** value per keyword, and `/etc/ssh/sshd_config`
  line 12 is `Include /etc/ssh/sshd_config.d/*.conf`, globbed lexically, so
  the provider's `50-cloud-init.conf` (`PasswordAuthentication yes`) beat
  the old `99-hardening.conf` outright. `sshd -t` cannot catch that: it
  checks syntax, not which drop-in won. Fixed by renaming to
  `00-hardening.conf` and asserting the *effective* config with `sshd -T`.
  Fifth check-that-never-ran instance, and the first where the check ran
  and answered a different question than the one asked. On a node not yet
  re-run, capture `sshd -T | grep -E '^(passwordauthentication|usepam) '`
  first: the rename destroys the evidence, and `passwordauthentication yes`
  means password login really was open on 22.
- `00-` sorting first has two consequences. No later drop-in can override
  it, so a `10-emergency.conf` re-enabling password auth does nothing;
  recover from the provider console by editing `00-hardening.conf` itself.
  And write a replacement **before** `rm`-ing an old name: an interrupted
  run must leave both files (identical, `00-` wins), never neither, because
  neither means no hardening drop-in and Debian's compiled-in default is
  `PasswordAuthentication yes`.
- The drop-in owns `PermitRootLogin` too: these are not stock Debian
  images, the provider ships `PermitRootLogin yes` uncommented at line 33
  (measured on all three, 2026-08-20), so the `prohibit-password` default
  this repo assumed never applied. Line 12's `Include` sorts ahead of it,
  so the drop-in wins. `prohibit-password` keeps key-based root, needed by
  these scripts and Dokploy's Remote Server, and drops only passwords.
- Assert `permitrootlogin` against **both** spellings: `sshd -T` normalises
  `prohibit-password` to legacy `without-password` (OpenSSH 9.2, Debian
  12), so asserting the literal the drop-in writes fails on a node that
  applied it perfectly. Caught 2026-08-20 on the first real run: fired
  correctly, for the wrong reason, and cost nothing because assertions run
  last. Assert effective values, not the strings you wrote.
- Order `harden-node.sh` by what it costs to skip: UFW, sshd,
  `DOCKER-USER` (rail 1), Fail2Ban, assertions. Under `set -eu` every step
  aborts everything below it, so whatever can fail on node state the script
  does not control belongs *after* rail 1. Fail2Ban's own start is exactly
  that (see above) and used to sit two blocks ahead of the `DOCKER-USER`
  rules, where a failed jail silently left published ports unfiltered; the
  `sshd -T` assertion is last for the same reason. sshd stays early as the
  one accepted exception, gated by `sshd -t` on static content.
- UFW does not govern Docker-published ports: Docker's `nat`/`DOCKER` rules
  are evaluated before ufw's chains, so `ufw status` showing only 22 while
  80/443/3000 answer from the internet is the expected symptom, not a
  contradiction. Filter in `DOCKER-USER`, plus `DOCKER-INGRESS` for
  ingress-mode Swarm publishes, which `harden-node.sh` does **not** cover
  (check new Swarm workloads with
  `docker service inspect <svc> --format '{{json .Endpoint.Ports}}'`).
  Never read `ufw status` as real exposure; sweep the ports from off-node.
- Do not persist `DOCKER-USER` rules with `iptables-persistent`: its boot
  restore races Docker creating the chain. `harden-node.sh` uses a systemd
  oneshot ordered `After=docker.service` (`docker-wan-drop.service`), which
  cannot lose that race. Verified across a real vps02 reboot, not assumed.
- Three load-bearing details in that oneshot. `-w 5` on every
  `iptables`/`ip6tables` call, because at boot it races Docker's own writes
  and without a lock wait the first "another app is currently holding the
  xtables lock" exits non-zero under `set -eu`, which a `Type=oneshot` +
  `RemainAfterExit=yes` unit never retries: the node comes up with rail 1's
  only active layer missing. A missing **IPv4** `DOCKER-USER` chain is
  fatal (exit 1), since exiting 0 leaves `systemctl is-active` green on a
  node whose published ports are wide open; a missing IPv6 chain is
  legitimate, so name the skipped family instead of skipping silently.
  Install with `enable` + `restart`, never `enable --now`, which does not
  re-run an already-active `RemainAfterExit` oneshot and so leaves an
  updated payload on disk unapplied while the run prints the *old* rule.
- `harden-node.sh` writes `/etc/docker/daemon.json` but deliberately never
  restarts Docker: on vps00 that restarts the Swarm control plane and every
  container. The loopback-bind layer is inactive until the next Docker
  restart or reboot; the `DOCKER-USER` drops apply immediately, so the node
  is closed either way.
- `daemon.json`'s `"ip": "127.0.0.1"` does **not** apply to a Swarm
  service's host-mode publish. Measured on vps00 after a reboot with the
  setting active: `dokploy-traefik` (plain container) moved to
  `127.0.0.1:80`/`:443`, but the `dokploy` service's 3000 still binds
  `0.0.0.0` **and** `[::]`. So on vps00 the `DOCKER-USER` rule closes 3000
  *alone*, unbacked: if `docker-wan-drop.service` ever fails to start, 3000
  faces the internet behind only the Dokploy admin password. Check
  `systemctl is-active docker-wan-drop` before trusting a port sweep taken
  from inside the node.
- Two scripts write `daemon.json`: `harden-node.sh` (`"ip"`) and
  `setup-maintenance.sh` (`log-driver`/`log-opts`). They avoid clobbering
  each other only because `setup-maintenance.sh` recognises harden's file
  by an exact whitespace-stripped match on `{"ip":"127.0.0.1"}`, warning on
  anything else. Change what either writes, fix the other's match in the
  same commit.
- An unattended `docker-ce` upgrade restarts dockerd, which does not flush
  `DOCKER-USER`: Docker creates that chain when absent and never rewrites
  its contents, the chain's whole purpose. Rail 1's iptables layer survives
  the restart, which is why `unattended-upgrades` is safe here.
- Dokploy's control plane was uncapped by default: `dokploy` alone observed
  at ~913MiB on a 1.9GiB node, `dokploy-postgres` ~67MiB. Two cap
  mechanisms, don't mix up: `dokploy`/`dokploy-postgres` are Swarm services
  (`docker service update --limit-memory`; plain `docker update` is
  silently reconciled away), `dokploy-traefik` is a plain container
  (`docker update --memory`; `docker service update` 404s on it). None of
  it is declarative and all of it comes from `bootstrap-dokploy.sh`'s
  upstream installer, so reapply caps after any reinstall or upgrade.
  Re-applying restarts the service's tasks, so the script compares first:
  that is what keeps a second run a no-op, not a control-plane bounce.
- `cap-dokploy-resources.sh` only ever worked on vps00: its payload runs
  under `set -eu` and opened with `docker service update ... dokploy`, but
  `dokploy` and `dokploy-postgres` are vps00-only, so on vps01/vps02 it
  aborted on line one and never reached the `dokploy-traefik` cap, which is
  why traefik was capped on vps00 and unbounded on both secondaries. Each
  cap now skips a missing target with a message instead of dying. When a
  script targets "every node", check what is actually on the secondaries.
- A transient memory spike (app startup, migrations) on a no-swap node is a
  hard OOM-kill, not a slowdown. Misdiagnosed once as a Calcom "build
  process" failure on vps01 when it was an OOM kill under a too-tight
  `mem_limit`. `add-swap.sh` fixes the swap side; the app's own
  `mem_limit`/`mem_reservation` (rail 4) still needs headroom.
- Never put a real node IP in a script's usage example. Five scripts here
  did, publishing two nodes' addresses in a public repo beside a full
  description of what runs on them. Use RFC 5737 addresses (`203.0.113.10`
  vps00-shaped, `.11` vps01, `.12` vps02) and point at
  `infra/inventory.yaml` for the real ones. Enforced by the `no-real-ips`
  local pre-commit hook; rail 5 was a sentence with nothing checking it,
  same drift class as rail 9.
- `install-docker.sh` no longer pipes `get.docker.com` into a root shell;
  it configures Docker's apt repo and keyring directly. Same end state
  (verified against a node the convenience script had already
  provisioned), but packages are GPG-verified and upgrades arrive through
  apt. Residual risk is the initial key fetch, still trust-on-first-use
  over TLS. Untested on a fresh node, since all three were provisioned
  before it changed: watch this step if a new node is ever built.
- `bootstrap-dokploy.sh` still runs a vendor installer; Dokploy has no apt
  repo. It downloads to a file and prints the sha256 before executing. That
  is a *record*, not a verification: no published checksum exists to
  compare a first run against. Don't upgrade the claim.
