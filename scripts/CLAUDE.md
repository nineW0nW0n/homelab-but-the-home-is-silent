Parent: ../.claude/CLAUDE.md

# scripts/: provisioning & bootstrap

Idempotent POSIX `sh`, one-time-per-node unless noted — except
`check-rails.sh` (touches no node at all) and `verify-node.sh` (CI-only,
runs on a node every deploy; see below). `shellcheck -s sh` clean is
the bar (pre-commit enforces it). Run twice, confirm the second run is a
no-op, before calling a script change done.

**`ssh-add` first.** The usage examples take a bare IP, which matches no
`Host` block in `~/.ssh/config`, so `IdentityFile`/`IdentitiesOnly` never
apply. Six of the seven node scripts pass no `-i` either and silently
depend on the right key already being agent-loaded: run `ssh-add
~/.ssh/id_ed25519_vps`, or pass the `vps0N-root` alias instead of a bare IP.
Symptom when you forget: `Permission denied (publickey)`.
None honours an `SSH_KEY` env var yet (the one script that did was the
Dokploy cap script, deleted 2026-08-23); worth the one-line treatment when
someone next touches them.

## Scripts

- `provision-deploy-user.sh <node> <host>`: `deploy` CI user, key-only, no
  sudo (rail 6); installs rsync; owns `/opt/stacks/<node>`.
- `install-docker.sh <host>`: Docker Engine from Docker's apt repo. That
  is the whole runtime: no control plane, Swarm inactive (Dokploy and its
  Swarm left all three nodes 2026-08-23).
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
- `setup-maintenance.sh <host>`: switches Docker's log driver to
  `journald` in `daemon.json` (container stdout lands in the systemd
  journal, which `stacks/<node>/vector.yaml` reads -- no `docker.sock`
  needed), makes the journal persistent (`Storage=persistent` +
  `mkdir -p /var/log/journal`) and caps it (`SystemMaxUse=1G`, restarted
  immediately -- 1G, not 200M, now that container logs land there too;
  `SystemMaxUse` only governs `/var/log/journal`, so the cap is only real
  once storage is persistent), drops a weekly
  `/etc/cron.d/docker-prune` (Sunday 03:00, `docker system prune -af
  --filter until=168h`, never volumes), enables `unattended-upgrades`
  (Debian's shipped security-only origins, never overridden). No
  RAM-freeing cron: dropping page cache frees nothing real, and swap plus
  rail 4's caps cover memory pressure.
- `install-aide.sh <host>`: installs AIDE, builds the file-integrity
  baseline once (`aideinit`, a few minutes of CPU), and disables Debian's
  `dailyaidecheck.timer` (mails root, no mail here). A daily cron.d entry
  runs `/usr/sbin/aide.wrapper --update`, pipes the report into the
  journal as `SYSLOG_IDENTIFIER=aide`, then adopts the new database as
  tomorrow's baseline -- a change log, not a tamper lock.
- `verify-node.sh`: **not a provisioning script** and never run from this
  machine -- `deploy.yml`'s Verify step pipes it over the SSH connection it
  already holds (`ssh ... "sh -s -- <args>" < scripts/verify-node.sh`), so
  it executes on the node. Args (per-node, from the deploy matrix):
  OpenObserve `/healthz` port or `-`, comma-separated
  `label:port` app probes or `-`, then the containers whose restart
  counters are sampled across a 75s window. The incident comments behind
  its checks (restart race, restart-counter aliveness, country-rule
  403s) live in the script itself.
- `check-rails.sh`: **not a provisioning script** — no node, no ssh, no
  arguments; a repo-wide check that runs on every commit via
  `.pre-commit-config.yaml` and again under `pre-commit run --all-files` in
  `validate.yml`. It enforces rails 2, 3, 4, 7 and 8 mechanically, rails 1
  and 6 partially (source-level only — for rail 1 that the `DOCKER-USER`
  drop, the `daemon.json` loopback bind and the `docker-wan-drop.service`
  unit plus its `enable`/`restart` still exist in `harden-node.sh`; for
  rail 6 that `provision-deploy-user.sh` keeps `passwd -d` and grants no
  sudo. Only an off-node sweep proves the nodes, and only `sudo -n true`
  over SSH proves the account), plus a markup-sink grep over the public
  status page, that `vector.yaml` is byte-identical across all three
  nodes and free of three settings that fail silently
  (`current_boot_only: false`, a pinned `journal_directory`, and `${...}`
  on a node that never sets `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION`),
  and that `setup-maintenance.sh` still sets Docker's journald log
  driver (Vector reads container logs from the journal). It is listed
  here because this repo's most-repeated failure
  is a rail with no enforcement point, and an enforcement point missing from
  its own directory file is the next best way to lose one.

## Failure log

- **A Docker log-driver change needs the containers *recreated*, not just
  the daemon restarted.** `daemon.json` + `systemctl restart docker` makes
  `docker info` report `journald` while every existing container is still
  on `json-file` -- the driver is fixed at creation. Assert
  `docker inspect -f '{{.HostConfig.LogConfig.Type}}' <name>` per
  container, and run `docker compose up -d --force-recreate` on each node.
  Every container is in a stack since 2026-08-23, so `--force-recreate`
  covers the fleet. `docker info` is the daemon default, never proof
  about a running container.
- **A long remote command can finish while the local ssh hangs forever.**
  `install-aide.sh`'s `aide --init` runs for many minutes with no output;
  on vps00 and vps01 the connection died during it, so the local log froze
  on "Running aide --init..." and never printed "Done." -- while the
  baseline, the runner and the cron entry had all been written correctly.
  The local transcript is not evidence of remote state: check the artefacts
  the script was supposed to leave (`/var/lib/aide/aide.db`,
  `/usr/local/sbin/aide-daily`, `/etc/cron.d/aide-daily`) before concluding
  anything, and re-run -- it is idempotent.

- **A grep can match text inside the very heredoc it is meant to guard.**
  `check-rails.sh`'s rail 1 check looked for `-I DOCKER-USER .*-j DROP` in
  `harden-node.sh`, but that line lives *inside* the `WANDROP` payload
  heredoc -- so deleting the `docker-wan-drop.service` unit block and its
  `systemctl enable`/`restart` left the grep satisfied and the check green
  with rail 1's boot-persistence layer gone. Found 2026-08-28 by tracing
  the graph edge claiming the service implements the network model; the
  unit and its enablement are asserted separately now, and the deletion
  was watched failing before the fix was trusted. Assert the thing that
  *runs* the payload, never only the payload -- a heredoc is data, not
  behaviour.

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
  `harden-node.sh` does **not** cover. Sweep the ports from off-node. That
  gap is latent, not live: Swarm is inactive on all three nodes since
  2026-08-23 (it existed only for Dokploy), so `DOCKER-INGRESS` does not
  exist and nothing can publish through it — re-enabling Swarm is what springs
  it. Note `iptables -S DOCKER-INGRESS` errors with "chain is incompatible,
  use 'nft' tool" on all three, so that chain is not inspectable with the
  legacy tool.
- **Never parse `ufw status` by column position** — with a source address
  plain `ufw status` prints `45876/tcp  ALLOW  <ip>  # comment`, while
  `ufw status verbose` prints `ALLOW IN` as two words. So a field index is
  the address in one mode and `#` in the other, and `$NF` is the trailing
  word of the comment in both. A column parse reported a false MISMATCH on
  all three nodes (2026-09-02) and nearly sent someone re-applying rules
  that were already correct. Match the address itself, never a field index.
- **Never persist `DOCKER-USER` rules with `iptables-persistent`** — its
  boot restore races Docker creating the chain; use the
  `docker-wan-drop.service` oneshot, `After=docker.service`. Three things
  in it are load-bearing: `-w 5` on every call, exit 1 on a missing IPv4
  chain, and install with `enable` + `restart`, never `enable --now`.
- **The `daemon.json` loopback bind is inactive until Docker restarts,**
  which `harden-node.sh` deliberately never does; the `DOCKER-USER` drops
  close the node meanwhile. It is **active on all three as of 2026-08-20** —
  dockerd has restarted since, plausibly via `unattended-upgrades`:
  `iptables -t nat -S DOCKER` shows `-d 127.0.0.1/32` scoping on 80/443 and
  `ss` shows `127.0.0.1:80`/`127.0.0.1:443`. Don't re-derive that from
  scratch; do re-check it after a reinstall.
- **`"ip"` misses Swarm host-mode publishes** — while Dokploy ran, vps00's
  3000 rested on the `DOCKER-USER` rule alone, proven, not inferred: 3000's
  DNAT was unscoped (`-A DOCKER ! -i docker_gwbridge -p tcp --dport 3000 -j
  DNAT`, no `-d`), and the DROP counter moved 25 → 34 under three external
  SYNs to it. UFW never sees those packets — DNAT'd in PREROUTING, routed
  via FORWARD. That listener was retired with Dokploy 2026-08-23 and the
  daily port sweep asserts 3000 closed, but the lesson stands: check
  `systemctl is-active docker-wan-drop` before trusting a sweep taken from
  inside the node.
- **Rewrite `daemon.json` whole when changing the log driver, never
  merge a driver change into the existing opts** — journald rejects
  `json-file`'s `max-size`/`max-file`, and dockerd refuses to start on
  unknown log-opts, so a merge takes Docker down on the next restart.
  `setup-maintenance.sh` matches the whole file and writes the whole
  file for exactly that reason.
- **Two scripts write `daemon.json`** — `setup-maintenance.sh` recognises
  harden's by an exact match on `{"ip":"127.0.0.1"}`; change what either
  writes, fix the other's match in the same commit.
- **A `docker-ce` upgrade does not flush `DOCKER-USER`** — Docker creates
  that chain when absent and never rewrites it, so rail 1 survives and
  `unattended-upgrades` is safe here.
- **Imperative resource caps do not survive a reinstall** — Dokploy's had
  to be reapplied by hand after every upgrade. Archived 2026-08-23 with
  Dokploy's removal; the lesson that stays is rail 4: caps live in the
  compose file or they do not exist.
- **A script targeting "every node" must skip a missing target, not die**
  under `set -eu` — the Dokploy cap script once exited on vps00's
  control-plane service and left both secondaries uncapped (archived
  2026-08-23, script deleted).
- **On a no-swap node a transient memory spike is a hard OOM kill,** not
  a slowdown, and it does not announce itself as one. `add-swap.sh`, plus
  real headroom in rail 4's limits.
- **Never put a real node IP in a usage example** — five scripts did, in
  a public repo. Use RFC 5737 (`203.0.113.10/.11/.12`) and point at
  `infra/inventory.yaml`; enforced by the `no-real-ips` hook.
- **`install-docker.sh` uses Docker's apt repo, not `get.docker.com | sh`**
  — GPG-verified packages, upgrades via apt. Untested on a fresh node.
- **A printed sha256 is a record, not a verification** unless the vendor
  publishes one to compare against (Dokploy's bootstrap did not; archived
  2026-08-23, script deleted).
