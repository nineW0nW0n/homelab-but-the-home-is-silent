# Failure log archive

Superseded `CLAUDE.md` failure-log entries and the narrative around compressed
ones, moved here 2026-08-20 by the repo-wide self-audit.

**Why this file exists.** The propagation protocol used to say "never delete a
superseded line; replace it in place", which meant every lesson ever learned
stayed in a file loaded into context on every session. This is the release
valve: the entry moves here in full, and a one-line pointer stays in the
directory's failure log. Nothing is lost, and the always-in-context cost stops
growing forever.

**Read this file when** a `CLAUDE.md` failure-log line points at it, or when you
want the full story behind a compressed entry. Nothing deploys from `docs/`.

**Compression is not supersession.** A lesson that still applies gets shorter,
not moved. An entry belongs here only when its situation can no longer occur, or
a later entry replaces it.


---

## From root

# Failure-log archive: `.claude/CLAUDE.md` (root)

Entries archived out of root's failure log during the 2026-08-20 self-audit
and compression pass. Each is the **full original text** as it stood before
compression. The live file keeps a one-line pointer naming the lesson.

Archived only when the entry's specific situation can no longer occur (the
config, skill, or command it warns about has been corrected in place). The
generalized lesson always stayed inline; only the narrative moved here.

(That parking note is resolved: this *is* the permanent home.)

---

## 1. Budget check: `find` superseded by `git ls-files`

Reason archived: the `wc -l */CLAUDE.md` glob form and the `find` form are
both gone from the file and from the loop. The live entry keeps the rule
(`git ls-files '*CLAUDE.md' | xargs wc -l`), the two reasons the alternatives
fail, and the class. Only the measurement narrative moved here.

Original text:

> - A `wc -l CLAUDE.md */CLAUDE.md */*/CLAUDE.md` budget check silently
>   skips `.github/`: shell globs don't match dot-directories. This entry
>   used to end "Use `find`" — **superseded** 2026-08-19. Under rtk, which
>   this same file mandates as tooling, the documented
>   `find . -name CLAUDE.md -not -path './node_modules/*' -exec wc -l {} +`
>   exits 1 with "rtk find does not support compound predicates or actions",
>   and the bare `find . -name CLAUDE.md` that rtk *does* accept returns a
>   silently wrong count instead: it walks untracked directories, so with
>   three agent worktrees present it reported 28 files, the 7 real ones plus
>   21 copies under `.claude/worktrees/` (measured 2026-08-19). Exit 0,
>   looking correct. A silently wrong answer beats a loud failure for
>   damage. Use
>   `git ls-files '*CLAUDE.md' | xargs wc -l`: it runs under rtk, includes
>   dot-directories, and skips `node_modules/` for free by only listing
>   tracked files. Fourth instance of the rail 9 / rail 5 / uninstalled
>   pre-commit hook class, a check that exists on paper and does not
>   reliably run — and the first where the check appeared to succeed. When a
>   rule mandates a tool that rewrites commands, run the rule's own commands
>   under that tool before writing them down.

---

## 2. `tooling-setup` skill carried the Biome 1.x spellings

Reason archived: fixed 2026-08-16. The skill's config block now shows the 2.x
spellings, so following the skill can no longer reintroduce the bug. The
generalized lesson — when a log entry says a config shape is wrong, grep the
skills for that shape in the same turn — stays inline, folded into the Biome
2.x schema entry it refers to (it was a standalone bullet before; merging it
removed a cross-reference without removing a fact).

Original text:

> - The `tooling-setup` skill's Biome config block sat at the 1.x
>   spellings (`files.ignore`, top-level `organizeImports`,
>   `rules.recommended: true`) for as long as the log entry above said
>   they were wrong, so following the skill would have reintroduced the
>   exact bug the log warns about. Fixed 2026-08-16. When a failure-log
>   entry says a config shape is wrong, grep the skills for that shape in
>   the same turn; a log entry and a skill that contradict each other is
>   worse than neither.

---

## Considered and deliberately NOT archived

- **rtk config path on macOS.** The macOS path
  (`~/Library/Application Support/rtk/config.toml`) and the
  `rtk config --create` exits-1-on-success quirk are live operational facts
  an agent needs before touching rtk config. Compressed inline, not moved.
- **`du` on a volume mis-sizes a dataset.** Nothing prevents a repeat.
- **`pre-commit` configured but not installed as a git hook.** Recurs in every
  fresh clone.
- **`gitleaks protect --staged` scans nothing under `--all-files`.** Verified
  still true 2026-08-20: the upstream hook's entry is
  `gitleaks protect --verbose --redact --staged`, `pass_filenames: false`.
- **Rail 9 was never gate-enforced.** The fix (a `local` biome-ci hook) is in
  `.pre-commit-config.yaml`, but the lesson — a rail without an enforcement
  point is undetectable drift — governs every new rail.
- **Biome 2.x schema churn** (`preset: "none"` mis-migration). Still the live
  guidance for any Biome version bump.

---

## From scripts

# Archive: scripts/CLAUDE.md, pre-compression original (2026-08-20)

Full verbatim text of `scripts/CLAUDE.md` as it stood before the
self-audit compression pass, kept so no wording is lost.

**Nothing was deleted from the live file.** Every lesson in the text
below still exists inline in the rewritten `scripts/CLAUDE.md`, in
denser prose. No entry qualified as superseded under the agreed rule
(situation can no longer occur AND the lesson is dead): the entries
whose situation is fixed in code -- `iptables-persistent`, the
`99-`/`00-` rename, `passwd -l`, the unguarded
`cap-dokploy-resources.sh` -- are all still live "never reintroduce
this" rails, so they stay inline and no pointer line was added to the
repo file.

This path is session-scoped scratch, so it is deliberately NOT cited
from the repo file.

---

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
- Assert `permitrootlogin` against **both** spellings. `sshd -T` normalises
  `prohibit-password` to the legacy `without-password` (OpenSSH 9.2, Debian
  12), so asserting the literal the drop-in writes fails on a node that applied
  it perfectly. Caught 2026-08-20 on the first real run: the assertion fired,
  correctly and for the wrong reason. Note what its placement bought -- the
  failure landed after UFW, sshd, `DOCKER-USER` and Fail2Ban had all applied,
  so a bogus assertion cost nothing. Assert effective values, not the strings
  you wrote.
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

---

## From stacks

# Archive: passages removed from `stacks/CLAUDE.md`

Self-audit + compression pass, 2026-08-20. Each entry below is the **full
original text** as it stood in `stacks/CLAUDE.md` before the rewrite, with a
note on why it left the live file. A one-line pointer to this archive remains
inline wherever a superseded entry was removed.

Nothing here was deleted because it was wrong to record at the time. Entries
marked FALSE were wrong *as claims about the present*; the original wording is
kept here so the reasoning trail survives.

---

## 1. "booking backup is not yet scheduled" (FALSE as of 2026-08-20)

Original opening of the "booking MySQL backups (vps01)" section:

> Nightly at **04:00 Asia/Manila** once PR #31 merges and a deploy installs the
> cron -- not scheduled on vps01 yet; the forced runs and the restore drill below
> are all that have executed.

**Why removed:** false. `.github/workflows/deploy.yml`'s "Install backup cron"
step installs four entries in one heredoc, `backup-booking.sh` among them at
`10 * * * *`, and `check-backup-age.sh booking /opt/stacks/vps01/backup-booking`
at `40 * * * *`. Cron verified live on vps01 2026-08-20. Replaced inline with a
plain statement that the job is scheduled and live, with the crontab minutes
recorded.

---

## 2. `MYSQL_PWD` correction, long form

Original paragraph in the booking section:

> Unlike ezBookkeeping, **nothing is stopped**: a hot `mysqldump
> --single-transaction --routines --triggers` inside
> `booking-ptpwn8-mysql-1` gives a consistent InnoDB snapshot with no downtime
> on a live booking site. `MYSQL_ROOT_PASSWORD` is expanded *inside* the
> container, and passed via `MYSQL_PWD`, not `-p`. Superseded 2026-08-20: the
> old `-p"$MYSQL_ROOT_PASSWORD"` form was documented here as never reaching "a
> host process argument", which was wrong. A container's PID namespace is a
> child of the host's, so `ps -ef` on vps01 lists container argv in full and the
> password was readable by any local user for the length of the dump. `MYSQL_PWD`
> moves it to the process environment (`/proc/<pid>/environ`, root and same-uid
> only) — better, not gone; MySQL's own docs still call `MYSQL_PWD` insecure.
> The host script's argv and env stay clean either way, which is the part the
> single-quoting buys.

**Why removed:** narrative only. Every fact and the lesson (a container's PID
namespace is a child of the host's, so container argv is visible in host
`ps -ef`; `MYSQL_PWD` is better, not safe) is preserved inline in denser form,
including the note that MySQL's own docs call `MYSQL_PWD` insecure. Verified
against `stacks/vps01/backup-booking.sh`, which uses
`MYSQL_PWD=$MYSQL_ROOT_PASSWORD; export MYSQL_PWD; exec mysqldump -uroot …`,
and against the Restore recipe, which uses the same form.

---

## 3. Superseded clause inside the `ezbookkeeping_backup_age` failure-log entry

Original entry, in full:

> - `ezbookkeeping_backup_age` has executed no notification since 2026-08-18
>   07:31:50Z. Written up wrongly twice before the cause was found: first as
>   "never executed, while stock alarms always did", then as a node-wide
>   stoppage. **Root cause (2026-08-19):** netdata's `health_alarm_execute()`
>   suppresses a notification when the most recent entry for the same
>   `alarm_id` that carried `EXEC_RUN` has the **same status** as the new
>   transition — its "don't send the same notification twice" rule. That alarm
>   last executed at 07:31:50Z with status CRITICAL, so every CRITICAL since
>   is dropped as a duplicate. This entry used to read "The state persists
>   across netdata restarts, which is why restarting never helped" —
>   **superseded** 2026-08-19: it persists across a restart alone, but it also
>   resets when the alarm's `config_hash_id` changes, which a restart that picks
>   up an edited `.conf` does at the same time. The escape hatch would be a CLEAR
>   that executes and resets the chain, and `delay: down 1h multiplier 1.5 max
>   4h` in `health.d/backup.conf` blocks exactly that: every CLEAR is held an
>   hour, the alarm re-fires first, and the CLEAR is superseded (`UPDATED`)
>   before its delay expires. The two mechanisms interlock. **Not**
>   recipient-specific, contrary to the first two write-ups: a throwaway
>   `to: sysadmin` alarm on vps02 fired and carried `EXEC_RUN` with
>   `exec_code=0`. Script, config and token were never at fault — replaying
>   netdata's real-mode arguments by hand delivers, as `netdata` and as
>   `root`. The lesson: **an alarm can look armed on the dashboard while being
>   permanently silent for one status.** Verify with a real transition, never
>   an interactive `alarm-notify.sh test`, and never make a Netdata alarm the
>   only delivery path for something that matters.

**Why trimmed inline:** two pieces were archived rather than kept. (a) The
retracted wording *"The state persists across netdata restarts, which is why
restarting never helped"* — superseded by the measured `config_hash_id` finding,
which has its own live failure-log entry; the live entry now points here instead
of restating the retraction. (b) The two-sentence history of the write-up being
wrong twice ("first as never executed…, then as a node-wide stoppage"); the
*conclusions* those retractions produced (not recipient-specific; script, config
and token never at fault) stay inline, because they are the evidence, not the
narrative. Root cause, timestamps, the interlock with the `down 1h` delay, the
vps02 positive control, and the lesson all remain inline.

---

## 4. Superseded clause inside the vps01 clock-zone failure-log entry

Original entry, in full:

> - vps01's system clock is **UTC-4**, not UTC (seen in the backup log's
>   `-04:00` stamps while rclone logged UTC). Any cron entry written as plain
>   UTC would fire four hours off, so do not assume these nodes are UTC.
>   This entry used to end "the backup crontab pins `CRON_TZ` for this reason;
>   do the same for anything else scheduled here" — **superseded**: Debian's
>   cron ignores `CRON_TZ` entirely (see the entry below). Schedule hourly and
>   gate on `TZ=<zone> date +%H` inside the script instead.

**Why trimmed inline:** the retracted advice ("the backup crontab pins
`CRON_TZ`…") describes a configuration that no longer exists anywhere in the
repo — no crontab entry in `deploy.yml` sets `CRON_TZ`, and both backup scripts
gate on `TZ=Asia/Manila date +%H`. The superseding entry (Debian's cron ignores
`CRON_TZ`, verified 2026-08-18) is a separate live failure-log entry. The UTC-4
fact and the "gate inside the script" instruction stay inline.

---

## 5. Standalone `delay: down 1h` failure-log entry

Original entry, in full:

> - `delay: down 1h multiplier 1.5 max 4h` in `health.d/backup.conf` holds
>   every CLEAR for an hour and cancels it outright if the alarm re-fires
>   first, so a flapping alarm never sends a recovery (`delay: 3600` on every
>   CLEAR in the transition records). Fine for a dashboard, useless as
>   notification.

**Why removed as a standalone entry:** `health.d/backup.conf` now carries
`delay: down 5m multiplier 1.5 max 1h`, so this exact configuration no longer
exists on any node, and the mechanism it describes is stated in full inside the
`ezbookkeeping_backup_age` entry ("every CLEAR is held an hour, the alarm
re-fires first, and the CLEAR is superseded (`UPDATED`) before its delay
expires") and again in the alarm-drill paragraph. The transferable rule — a long
`down` delay on an alarm you rely on for notification suppresses recovery — is
kept inline as one clause on the `config_hash_id` entry.

---

## 6. "Install backup cron" failure-log entry, original forward-looking wording

Original entry, in full:

> - `deploy.yml`'s "Install backup cron" step pipes into `crontab -`, which
>   **replaces the deploy user's entire crontab**, it does not append. That is
>   fine while the backup is its only entry; the moment a second scheduled job
>   exists on vps01, this step will silently delete it. Add the second entry to
>   the same step rather than installing it by hand.

**Why rewritten inline:** the predicted situation has arrived and was handled
correctly — the step now emits **four** entries from a single heredoc
(`backup-ezbookkeeping.sh` at `:00`, `check-backup-age.sh` at `:30`,
`backup-booking.sh` at `:10`, `check-backup-age.sh booking …` at `:40`). The
rail is unchanged and stays inline in the present tense; only the
"fine while the backup is its only entry" framing is obsolete.

---

## From worker

# Archived from `worker/status/CLAUDE.md`

Entries removed from the live file during the 2026-08-20 self-audit +
compression pass. Nothing here is deleted history: each entry is kept in
full, with the reason it left the live file. The live file carries a
one-line pointer to this file for each.

---

## 1. The `pollDokploy` reachability-check narrative (archived 2026-08-20)

**Why archived:** the code it describes (`pollDokploy` in `src/poll.js`)
no longer exists, and neither does `DOKPLOY_HOST`, so the specific bug
can no longer occur. The *general* lesson it teaches survives in the live
file as a compressed one-liner under the blast-radius entry: a
reachability check that accepts any non-5xx proves the login page
answered, not the origin, once the target sits behind Access.

**Original text, verbatim** (it was the second half of the blast-radius
entry, introduced by "Superseded, kept for the lesson:"):

> Superseded, kept for the lesson: a reachability check that accepts any
> non-5xx is not a reachability check once the target sits behind Access.
> `pollDokploy` originally did a plain `GET` with no token and
> `up = res.status < 500`; the runtime follows the Access `302` to a `200`
> login page, so the tile would have stayed green forever. Whenever a
> polled origin gains an auth gate, re-check what the poller proves: "up"
> must mean the origin answered, not that its login page did.

**Full context for anyone digging this up later:** `pollDokploy` went
through two shapes. The first was the plain unauthenticated `GET` above,
which was wrong for the reason described. The second was correct — it
sent the Cloudflare Access service token, used `redirect: 'manual'`, and
tested for an explicit 2xx rather than "not 5xx", so it could not be
fooled by the Access login page. The correct version is the one that was
deleted, and it was deleted for blast radius, not correctness. That
distinction is the point of the live entry that replaced this one.

---

## 2. "Polls fresh on every page load" (corrected in place 2026-08-20, original kept here)

**Why archived:** it was FALSE by the time of the audit. The live file's
header and Cron Trigger entry both said the Worker polls the nodes on
every page load. Two later changes falsified it: `POLL_TTL_MS` (30s) plus
`isFresh` in `src/poll.js` mean a snapshot inside the TTL is served
straight from KV without touching Netdata, and `src/index.js` returns
`page.html` for every path except `/status.json` and `/debug` *before*
any KV read or poll happens at all. The live file now describes the real
behaviour. Kept here because the original wording explains the intent at
the time the Cron Trigger was dropped.

**Original text, verbatim:**

> Serves the status page at the `maybeit.work` apex. Polls node health
> fresh on every page load, no Cron Trigger, see failure log for why.

and, from the Cron Trigger failure-log entry:

> Current fix: no Cron Trigger at all. `wrangler.toml` has no
> `[triggers]` block, `index.js` has no `scheduled()` handler, and the
> `fetch()` handler polls fresh on every page load instead of reading a
> cached KV snapshot. Trade-off accepted deliberately: page load is
> slower (waits on live Netdata calls) in exchange for
> actually working. KV write stays, only to carry `lastSeen` forward
> across visits when a node's down at the current one.

and, from Local dev:

> `npm install`, `npx wrangler dev`, then hit `http://localhost:8787/`,
> every load polls live, no separate step needed.

**What is true now:** no Cron Trigger and no `scheduled()` handler, both
still deliberate and both still verified against `wrangler.toml` and
`src/index.js`. The poll now runs inside the `fetch()` invocation that
serves `/status.json`, and only when the KV snapshot is stale. The KV
write carries `lastSeen` forward *and* backs the freshness cache — it has
two jobs now, not one.

---

## From infra

# Archived entries: infra/CLAUDE.md and dokploy/CLAUDE.md

Full original text of entries removed from those two files during the
2026-08-20 self-audit + compression pass. Nothing here was deleted for being
wrong about the past; each is archived because the situation it describes can
no longer occur, or because a later, shorter entry in the live file replaces
it. Each has a one-line pointer left inline.

## infra/CLAUDE.md — the "root is key-only, but not for the reason this file
## used to give" supersession paragraph (from "Human SSH access", path 2)

Original text, as of commit aa6ebc6:

> 2. **`root@` with `~/.ssh/id_ed25519_vps`**, for the provisioning scripts.
>    `scripts/*.sh` default to `SSH_USER=root` and that default is correct.
>    Root is key-only, but **not** for the reason this file used to give.
>    Superseded 2026-08-20: it said `sshd` keeps Debian's
>    `PermitRootLogin prohibit-password` default and `harden-node.sh` does not
>    change it. Measured on all three nodes, the provider image ships
>    `PermitRootLogin yes`, uncommented, at line 33 of `/etc/ssh/sshd_config` --
>    root was key-only only because `PasswordAuthentication no` removed every
>    other method. `harden-node.sh` now sets `PermitRootLogin prohibit-password`
>    in its drop-in and asserts it, so the property no longer rides on a second
>    setting staying correct. Use the `vps0N-root` ssh aliases; the plain
>    `vps0N` aliases force the deploy key with `IdentitiesOnly yes`.

Why archived: the false claim it corrects is no longer anywhere in the repo,
and `harden-node.sh` now writes *and* asserts `PermitRootLogin
prohibit-password` (see its `sshd -T` block), so the state it warns about
cannot recur on a hardened node. The durable lesson — never state a node's
sshd setting from Debian's documented default, these are provider images —
is kept in full in `infra/CLAUDE.md`'s failure log, and the mechanics of the
drop-in are in `scripts/CLAUDE.md`.

## infra/CLAUDE.md — the deleted declarative-config yaml layer

Original failure-log entry:

> - `common/base.yaml`/`nodes/*/node.yaml` existed as declarative config
>   for OS/firewall/resources/dokploy but nothing ever read them; scripts
>   hardcoded the same values independently. Deleted rather than wired up:
>   3 static nodes don't justify a yaml-parsing layer in POSIX `sh`
>   scripts. If node config needs to be data-driven again, that's a real
>   design decision, not a resurrection of these files as-is.

Original opening-paragraph text covering the same deletion:

> Real IPs vs. redacted template. That's the whole directory now.
> `common/base.yaml` and `nodes/*/node.yaml` (declarative OS/firewall/
> resource config nothing ever read) were deleted; nothing in `scripts/` or
> `.github/workflows/` parsed them, so they only drifted from what the
> scripts actually do. Enforcement lives directly in
> `scripts/harden-node.sh` (UFW, sshd, Fail2Ban, and the `DOCKER-USER`
> drops + `daemon.json` loopback bind that make rail 1 true),
> `scripts/cap-dokploy-resources.sh` (resource caps), and GitHub
> Secrets/Variables (host/port/user, resolved at deploy time, see
> `.github/workflows/CLAUDE.md`). If node config needs to change, change
> the script; there's no yaml layer to edit first.

Why archived: the two said the same thing twice. The live file keeps one
compressed statement carrying both the fact (deleted, nothing read them,
enforcement is in the scripts) and the lesson (don't resurrect them; making
node config data-driven is a real design decision). The files were deleted
before commit `ff4227b`'s successors; `git log -- infra/common infra/nodes`
still has them if the text is ever wanted.

---

## From workflows-readme

# Archive: text removed from `.github/workflows/CLAUDE.md` and `README.md`

Self-audit, 2026-08-20, branch `docs/claude-md-self-audit`. Nothing here was
deleted for being wrong unless the entry says so. Each item records the full
original text, why it left, and where the surviving pointer lives.

---

## 1. `.github/workflows/CLAUDE.md` — gitleaks failure-log entry (moved, duplicate of root)

Reason: verbatim duplicate of an entry already in the root `CLAUDE.md` failure
log. The fact is still true (upstream hook entry for gitleaks v8.18.4 is
`gitleaks protect --verbose --redact --staged`, `pass_filenames: false`).
Replaced inline by a one-line pointer to root.

Original text:

> - The `gitleaks` hook here is `gitleaks protect --staged`: it scans
>   staged changes only, so under `pre-commit run --all-files` in CI,
>   where nothing is staged, it scans nothing. It is a commit-time
>   secret check, not a CI one. Any repo-wide content rule needs a
>   `local` hook that takes filenames instead (see `no-real-ips`).

---

## 2. `.github/workflows/CLAUDE.md` — vps02 tunnel-token entry (superseded half compressed)

Reason: the first two sentences describe a state that no longer exists (vps02
with no workload and no token of its own). The rail-2 lesson and the "never
wire in vps00's token" instruction are preserved inline in compressed form.

Original text:

> - deploy-vps02's "Write remote .env" step used to write
>   `CLOUDFLARE_TUNNEL_TOKEN` (vps00's shared token) into vps02's `.env`,
>   even though vps02 has no service to consume it. Removed at the time.
>   vps02 now has its first workload (Netdata) and its own dedicated
>   `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` secret + "Write remote .env"
>   step, same pattern as vps01. Never wire in vps00's token (rail 2).

---

## 3. `.github/workflows/CLAUDE.md` — the 403 entry (wrong first diagnosis, compressed)

Reason: prose tightened only. Every fact kept inline: the wrong first
diagnosis, the real rule name, the `ip.src.country ne "PH"` expression, the
apex exemption, the 2026-08-19 amendment date, and the instruction to read
Security Events first.

Original text:

> - A post-deploy check that probed the **public hostnames from the runner**
>   failed every probe with `403` while every service was healthy. First
>   diagnosis (bot protection rejecting datacenter IPs) was **wrong**: the
>   real cause is a zone-wide Cloudflare custom rule, `Block non-local
>   traffic`, matching `ip.src.country ne "PH"`. Any non-PH source is blocked,
>   which is every GitHub runner and both US-hosted nodes. Amended
>   2026-08-19 after reading Security -> Events in the dashboard rather than
>   inferring from response codes. `maybeit.work` is now exempt from that
>   rule; the other hostnames are not, so CI still cannot probe them. Read the
>   matched rule in Security Events before theorising about a 403.

---

## 4. `.github/workflows/CLAUDE.md` — the Netdata-503 entry (compressed)

Reason: prose tightened only. Facts kept inline: `FAIL netdata: 503` on all
three nodes, the `docker compose restart netdata` cause, ~5s init window, the
30-tries/2s-apart fix, and the "test right after a restart, not on a warm
node" lesson.

Original text:

> - The rewritten node-side check then failed on its first real run with
>   `FAIL netdata: 503` on all three nodes, while every node was healthy. The
>   Deploy step ends with `docker compose restart netdata`, and Netdata
>   answers 503 for ~5s while it initialises, so a single immediate request
>   races the restart it just caused. Fixed by polling (30 tries, 2s apart).
>   It passed by hand only because the agents had been up for hours. A
>   post-deploy check runs at the worst possible moment by definition: give
>   every probe a retry budget, and test it right after a restart rather than
>   on a warm node.

---

## 5. `.github/workflows/CLAUDE.md` — blast-radius section (compressed, nothing dropped)

Reason: five paragraphs merged into three. Every claim kept: per-node keys,
`docker`-group root-equivalence, "removing deploy from the docker group is
theatre, do not propose it", rail 6 restricting shape not power, required
reviewers on `production`, both in place since 2026-08-16, "Waiting is the
protection working", the GitHub-side settings not being revert-restorable, the
`main` ruleset (`deletion` + `non_fast_forward`, no bypass actors), the push
rejection message, the disable/rewrite/re-enable procedure, dangling SHAs in
`docs/`, and `permissions: contents: read` on all three workflows.

Original text:

> ## Blast radius of the CI credential
>
> Each deploy job authenticates with **its own** node key
> (`SSH_PRIVATE_KEY_VPS0N`), so one leaked secret reaches one node, not
> three. That is the only thing per-node keys buy; read the next
> paragraph before assuming they buy more.
>
> `deploy` is in the `docker` group, which is root-equivalent, and it owns
> `/opt/stacks/<node>/docker-compose.yml`, so it can write any compose file
> it likes and have root run it. **Any path that lets CI deploy containers
> is root-equivalent by construction.** Removing `deploy` from the `docker`
> group and granting `sudo docker compose` instead is theatre. Do not
> propose it as a fix. Rail 6's "no sudo" restricts the *shape* of the
> access, not its power.
>
> The real controls are: one key per node (blast radius), and required
> reviewers on the `production` environment (a human approves before any
> deploy runs, which is what stops an automated exfiltration path).
>
> Both are in place as of 2026-08-16. **Every deploy now waits for Ex to
> approve it** in the Actions tab. A run sitting at "Waiting" is the
> protection working, not a stuck job. The setting lives in GitHub
> (Settings → Environments → production), not in this repo, so it is the
> one control here that a `git revert` cannot restore.
>
> Same category: a repository **ruleset** on `main` blocks deletion and
> force-pushes (rules `deletion` + `non_fast_forward`, no bypass actors).
> Also GitHub-side, also not restorable by revert. A rejected push reading
> "push declined due to repository rule violations" is that rule doing its
> job. To rewrite history deliberately, disable the ruleset, rewrite,
> re-enable, and expect every SHA in `docs/` to dangle afterwards.
>
> Note all three workflow tokens are `permissions: contents: read`, so no
> workflow can push to `main` at all. These rules guard against human
> error, not against CI.

---

## 6. `README.md` — three false booking-backup claims (deleted, were FALSE)

Reason: `stacks/vps01/backup-booking.sh` is on `main` (verified:
`git ls-tree origin/main stacks/vps01/`), `deploy.yml` on `main` installs its
cron (`10 * * * * .../backup-booking.sh` plus a `40 * * * *` staleness check),
and the cron was verified present on vps01 on 2026-08-20. All three claims that
it was unscheduled were false at audit time.

Original text, NOTE block clause:

> ezBookkeeping is
> backed up nightly off-site to Cloudflare R2; the booking database's backup
> is written and restore-drilled but not yet scheduled on the node (PR #31
> installs the cron).

Original text, HTML maintenance comment (whole block, its instruction now
carried out):

> <!-- When PR #31 merges AND a deploy has been approved on main, three places
>      stop being true: the booking clause in the NOTE above, the "(PR #31, not
>      yet on main)" tag on vps01/backup-booking.sh in the file listing, and the
>      "not yet running" opening of the booking paragraph under ## Backups.
>      Update all three in the same commit. -->

Original text, repo-layout line:

>   vps01/backup-booking.sh            nightly MySQL dump to R2 (PR #31, not yet on main)

Original text, Backups section opening:

> `booking.maybeit.work`'s MySQL database has a backup written but **not yet
> running**: `backup-booking.sh` lives on PR #31, not on `main`, and no deploy
> run has installed its cron, so the only runs so far were forced by hand. Once
> that merges and a deploy is approved it runs at 04:00, an hour after
> ezBookkeeping so two backups never overlap on a 2GB node: a hot `mysqldump
> --single-transaction` taken inside the MySQL container, so the booking site
> never goes down for it, writing its own stamp file that the same staleness
> check watches, so the two backups can go stale independently. Until it lands,
> this is the only production data here without a scheduled off-site copy. It is not much data: 14 tables and about 126
> rows, 0.4 MB, dumping to a 6KB gzip; the volume's 203MB on disk is MySQL's
> own tablespaces and binlogs, not appointments. Real customer bookings all the
> same.

## 7. `scripts/CLAUDE.md` — three Dokploy-only entries (archived 2026-08-23, Dokploy removed)

Moved in full when `bootstrap-dokploy.sh` and `cap-dokploy-resources.sh` were
deleted. The situations cannot recur; each left a one-line generalised pointer.

- **Reapply Dokploy's memory caps after any reinstall or upgrade** — none
  of it is declarative — and by the right mechanism: Swarm services take
  `docker service update --limit-memory` (plain `docker update` is
  silently reconciled away), `dokploy-traefik` takes `docker update
  --memory`.
- **A script targeting "every node" must skip a missing target, not die**
  — `cap-dokploy-resources.sh` opened with a vps00-only service under
  `set -eu`, so traefik went uncapped on both secondaries.
- **`bootstrap-dokploy.sh`'s printed sha256 is a record, not a
  verification** — Dokploy publishes no checksum to compare against, so
  don't upgrade the claim.

## 8. `worker/status/CLAUDE.md` — four poller-only entries (archived 2026-09-03, poller retired)

Moved in full when the status Worker's poller retired (phoenixlab step 17,
section 0: `poll.js`, `status-json.js`, `debug-auth.js`, the KV snapshot,
`NODE_HOSTS` and the Worker's Access service token wiring all deleted; the
Beszel hub replaced Netdata monitoring). The situations cannot recur in
this Worker; the live file keeps one pointer line naming all four.

- **Verify Netdata chart ids and dimensions against a live node's
  `/api/v1/charts` before wiring them** — two of `poll.js`'s were wrong
  guesses. `system.cpu` has no `idle` dimension here, the root filesystem
  chart keeps the literal `/`, and `system.load`'s dimensions are
  absolute, so `options=percentage` is meaningless on it.
- **No Cron Trigger in this Worker** — no `[triggers]`, no `scheduled()`.
  Anything in a request chain rooted at a Cron Trigger gets 403'd by
  Access however many hops deep, with credentials that work fine from a
  real `fetch()`. Cost: the first `/status.json` after the TTL expires
  waits on live Netdata calls.
- **The status code tells you which layer failed** — vps02's 530s were
  Cloudflare-level (a tunnel that had never connected), not an Access
  403; fixed by rotating the tunnel token and re-running `deploy.yml`.
- **Grep for order-sensitive output from a concurrently-filled object** —
  `page.html` matches status dots to nodes by array index, so building
  that array from `Object.entries(snapshot.nodes)` would have mislabeled
  nodes under network jitter. Build from `NODE_HOSTS.split(',')`.
