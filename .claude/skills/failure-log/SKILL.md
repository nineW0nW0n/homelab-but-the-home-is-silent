---
name: failure-log
description: Incident histories behind the one-line rules in this repo's CLAUDE.md failure logs — what was believed, what was true, how it was found, what it cost. Load before changing node hardening (sshd, UFW, DOCKER-USER, Docker daemon.json), the backups on vps01 (R2, rclone, restore drills, cron), Netdata alarms or alert delivery, a deploy workflow (rsync excludes, cron install, post-deploy probes, tunnel tokens), the status Worker or its poller, Dokploy compose apps or resource caps, or tooling config (Biome, yamllint, rtk, pre-commit, gitleaks) — and when a rule in a failure log looks redundant and you are tempted to drop it.
---

# Failure log: the incidents

Parent: ../../CLAUDE.md

Each `CLAUDE.md` failure log carries the **rule** — imperative, one or two
lines, always in context. This skill carries the **story** behind each
rule: what was believed, what was true, how it was found, what it cost,
what changed. Sections here mirror the directories those rules live in.

Read the section for the directory you are about to touch. If a rule
looks redundant or over-cautious, find it here before you drop it: most
of these were written after the redundant-looking guard turned out to be
the only thing standing.

This is **not** `docs/superpowers/failure-log-archive.md`. That file holds
*superseded* entries — lessons whose situation can no longer occur. These
all still apply. Pointers into the archive are preserved as written.

## Root (`.claude/CLAUDE.md`): cross-cutting

### Assert effective values, never the strings you wrote

**Assert effective values, never the strings you wrote.** A config you
authored is no proof the tool read it, honored it, or won against another
source. Three lost sessions: Biome's `preset: "none"`, an rtk config at a
path rtk never reads, an sshd drop-in outranked by another file while
`sshd -t` still passed (`scripts/`, `infra/`). Make the tool print what
it resolved.

### A rail with no enforcement point

**A rail with no enforcement point is undetectable drift.** Rail 9 had no
pre-commit hook and no `validate.yml` step until a `local` hook was added
(`language: node`, `additional_dependencies: ["@biomejs/biome@2.5.8"]`,
matching `biome.json`'s `$schema`; bump both together). Same class as
rail 5's hook, the uninstalled `pre-commit`, and the budget check. Give
every new rail a check that runs.

### `pre-commit` configured but never installed

**`pre-commit` was configured but never installed as a git hook** (no
`.git/hooks/pre-commit`), so `git commit` ran nothing locally; only
`validate.yml` caught anything, after a push. Run `pre-commit install` in
a fresh clone — a config file is not an installed hook.

### gitleaks scans staged changes only

**`gitleaks` scans staged changes only.** Entry: `gitleaks protect
--verbose --redact --staged`, `pass_filenames: false` — so under
`--all-files` in `validate.yml` nothing is staged and it scans nothing
(re-verified 2026-08-20). Never express a repo-wide content rule as a
`.gitleaks.toml` rule and assume CI enforces it; use a `local` hook
taking filenames. Keep gitleaks as a commit-time check, but don't credit
it with coverage it lacks.

### The budget check, and everything that breaks it

**Budget check: `git ls-files '*CLAUDE.md' | xargs wc -l`, nothing else.**
A `wc -l */CLAUDE.md` glob skips dot-directories (`.claude/`,
`.github/`). Under rtk, `find … -exec` exits 1 ("rtk find does not
support compound predicates or actions"), and the bare `find . -name
CLAUDE.md` rtk accepts walks untracked dirs — with three agent worktrees
it reported 28 files, the 7 real plus 21 under `.claude/worktrees/`, exit
0, looking correct (2026-08-19); silently wrong does more damage than
loudly broken. `git ls-files` runs under rtk, covers dot-directories,
skips `node_modules/` free. **When a rule mandates a tool that rewrites
commands, run the rule's own commands under that tool first.** Superseded
`find` history archived in `docs/superpowers/failure-log-archive.md`.

### A split that left the parent's copy behind

**A directory split is not finished until the parent's copy is deleted.**
The 2026-08-20 `stacks/` → `stacks/vps01/` split wrote the child and
trimmed only part of the parent, leaving 195 duplicated lines. Nothing
looked stale, because every *dated* claim still agreed between the two
copies; the damage was confined to the places one copy had been fixed and
the other had not. The parent's `mysqldump` line had lost `--databases
easyappointments` while the child and `backup-booking.sh` kept it — and
eight lines later the parent contradicted itself, saying "the dump is
`--databases`, so it recreates `easyappointments` itself". The parent also
still carried a passage already recorded as archived, and an "archived
passages are pointed to below" banner whose every pointer sat inside the
duplicated block. Two copies do not stay equal: one gets fixed. Delete the
parent's copy in the same commit as the split, then grep the repo for
pointers into what you deleted — `.github/workflows/deploy.yml` cited a
warning three times that survived only in the moved text.

### The 203M that wasn't

**Never size a dataset with `du` on its volume.** `du -sh` on
`booking-ptpwn8_mysql-data` said 203M; that became "~200MB of real
appointments" and reached `README.md`, `stacks/CLAUDE.md`,
`dokploy/CLAUDE.md`, the booking compose header and a commit message
before anyone dumped the database. Real: 14 tables, **128 rows**, 0.4 MB —
the rest is MySQL 8.0's ibdata1, redo/undo tablespaces, binlogs.

**The fix this entry prescribed was itself wrong, and lasted longer than
the bug.** It said to query `information_schema.tables`. That was done, it
returned 126, and "~126 rows" was copied into `README.md`, root's failure
log, this skill, `stacks/vps01/CLAUDE.md`, and
`dokploy/booking/docker-compose.yml`'s header comment. But InnoDB's
`TABLE_ROWS` is
an **estimate**: measured 2026-08-20 with `COUNT(*)` across all 14 tables,
the real total is 128 — `information_schema` undercounted `ea_migrations`
(0 vs 1) and `ea_users` (3 vs 4). The restore drill's "128 rows total",
which came from real per-table counts, had been sitting sixteen lines
below the wrong figure in the same file, disagreeing with it, since the
day both were written.

So: **count rows with `COUNT(*)`; use `information_schema` for byte sizes
only.** And the wider lesson, which is why this entry gets a second
paragraph instead of a corrected number — **when a remedy tells you to
measure, check that the tool it names counts rather than estimates.** A
prescribed fix inherits none of the scrutiny the original mistake got, so
a wrong remedy propagates further than the bug it replaced: this one
reached five files, one of them public. The correction pass proved that
thesis a second time — it enumerated four of the five sites and missed the
compose header, which was still wrong in the repo when the 2026-08-20
audit found it. **An inferred number is said once, hedged, until measured —
never copied into a second document.**

### Biome 2.x's schema moved fast

**Biome 2.x's schema moved fast**: `files.ignore` → `files.includes` with
`!` negation, top-level `organizeImports` → `assist.actions.source`,
`linter.rules.recommended: true` → `linter.rules.preset: "recommended"` —
*not* `"none"`, which `biome migrate --write` produced, silently
disabling every rule. Verify the migrated `linter` block by hand; pin
`biome.json`'s `$schema` and syntax to the exact version installed, never
to an older doc or skill. `tooling-setup` carried the 1.x spellings the
whole time this entry called them wrong (fixed 2026-08-16): **when a log
entry says a config shape is wrong, grep the skills for it the same
turn.** Original entry in `docs/superpowers/failure-log-archive.md`.

### rtk's config path is not what the doc said

**Never hand-create a config at a path a doc asserts; make the tool say
where it reads from.** `tooling-setup` called `~/.config/rtk/config.toml`
rtk's path; macOS rtk reads `~/Library/Application Support/rtk/` instead,
so the config never loaded and rtk ran on defaults —
`display.max_width = 120` chopped output mid-path for a session
(2026-08-19). `rtk config --create` writes a populated default at the
platform's real path; edit that in place. It exits 1 even on success —
judge it by its "Created:" line, not its status.

### A rewrite invalidates every SHA written down

**A `git filter-repo` rewrite invalidates every commit SHA already
written down** — handoffs, plans, specs, and the rewrite's own commit
message. Grep `docs/` for short SHAs before force-pushing one; cite
commits by *message* in documents meant to outlive a rewrite. The
security handoff cited `2e8e44d` for its own scrub commit, which the
rewrite had already turned into `87ff87b`.

### `claude plugin disable` overwrote `settings.json`

**`claude plugin disable --scope project` overwrites
`.claude/settings.json`, it does not merge.** Running it on 2026-08-20
dropped this repo's entire `permissions.allow` block. It was recoverable
only because the block was still in the agent's context — nothing else held
a copy. Read the file, run the command, diff it, restore what it dropped.
The nuance: `.claude/settings.json` is git-tracked here **now** (since
commit `59b8c1f`, the same day), so `git diff` would catch a repeat — but
it was untracked at the moment of the incident, which is exactly why
nothing caught it. A destructive write to an untracked file has no `git
diff` to save you, and that is how a silent overwrite becomes permanent.

### Pin exact versions

**Pin exact versions/commits** for Biome, rtk, caveman, yamllint. Never
`latest`.

### yamllint's `truthy` rule flags `on:`

**yamllint's `truthy` rule flags `on:`** in Actions workflows as a
boolean. Fix `.yamllint` (`check-keys: false`), never the workflow file.

### Cap control-plane services from the start

**New control-plane-style services get an explicit memory cap from the
start.** Dokploy's was uncapped and ate a disproportionate share of a 2GB
node; fix is `cap-dokploy-resources.sh`, detail in `scripts/CLAUDE.md`.

### Pointer: Fail2Ban and empty-stack pull

Fail2Ban and `docker compose pull`-on-empty-stack live in
`scripts/CLAUDE.md` and `.github/workflows/CLAUDE.md`: one script, one
workflow, not cross-cutting.

## `scripts/`: node hardening, provisioning, Dokploy caps

### Fail2Ban has no rsyslog to tail, and races its own socket

No `rsyslog` on these images, so Fail2Ban's default sshd backend has
nothing to tail and exits with "Have not found any log file for sshd
jail." Use `backend = systemd`. `fail2ban-client` also races the daemon's
socket for a second or two after a restart: retry for 10s and warn once,
rather than printing a meaningless ERROR every run.

### `passwd -l` breaks pubkey auth under `UsePAM no`

`UsePAM no` makes sshd check `/etc/shadow` itself, and that check rejects
pubkey auth on a **locked** account even with a valid key.
`provision-deploy-user.sh`'s `passwd -l` worked under `UsePAM yes` and
broke every CI deploy (`Permission denied (publickey)`) the instant
`UsePAM no` landed. Use `passwd -d` (empty password field), which the
check does not veto; `PasswordAuthentication no` plus the default
`PermitEmptyPasswords no` block password login anyway. Re-run
`provision-deploy-user.sh` after `harden-node.sh` on any node hardened
after it was provisioned.

### The sshd drop-in that never won

sshd keeps the **first** value per keyword, and `/etc/ssh/sshd_config`
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

### Why `00-` sorts first, and write-before-`rm`

`00-` sorting first has two consequences. No later drop-in can override
it, so a `10-emergency.conf` re-enabling password auth does nothing;
recover from the provider console by editing `00-hardening.conf` itself.
And write a replacement **before** `rm`-ing an old name: an interrupted
run must leave both files (identical, `00-` wins), never neither, because
neither means no hardening drop-in and Debian's compiled-in default is
`PasswordAuthentication yes`.

### The provider images ship `PermitRootLogin yes`

The drop-in owns `PermitRootLogin` too: these are not stock Debian
images, the provider ships `PermitRootLogin yes` uncommented at line 33
(measured on all three, 2026-08-20), so the `prohibit-password` default
this repo assumed never applied. Line 12's `Include` sorts ahead of it,
so the drop-in wins. `prohibit-password` keeps key-based root, needed by
these scripts and Dokploy's Remote Server, and drops only passwords.

### `sshd -T` renames `prohibit-password`

Assert `permitrootlogin` against **both** spellings: `sshd -T` normalises
`prohibit-password` to legacy `without-password` (OpenSSH 9.2, Debian
12), so asserting the literal the drop-in writes fails on a node that
applied it perfectly. Caught 2026-08-20 on the first real run: fired
correctly, for the wrong reason, and cost nothing because assertions run
last. Assert effective values, not the strings you wrote.

### Step order in `harden-node.sh` is a rail, not style

Order `harden-node.sh` by what it costs to skip: UFW, sshd,
`DOCKER-USER` (rail 1), Fail2Ban, assertions. Under `set -eu` every step
aborts everything below it, so whatever can fail on node state the script
does not control belongs *after* rail 1. Fail2Ban's own start is exactly
that (see above) and used to sit two blocks ahead of the `DOCKER-USER`
rules, where a failed jail silently left published ports unfiltered; the
`sshd -T` assertion is last for the same reason. sshd stays early as the
one accepted exception, gated by `sshd -t` on static content.

### UFW does not govern Docker-published ports

UFW does not govern Docker-published ports: Docker's `nat`/`DOCKER` rules
are evaluated before ufw's chains, so `ufw status` showing only 22 while
80/443/3000 answer from the internet is the expected symptom, not a
contradiction. Filter in `DOCKER-USER`, plus `DOCKER-INGRESS` for
ingress-mode Swarm publishes, which `harden-node.sh` does **not** cover
(check new Swarm workloads with
`docker service inspect <svc> --format '{{json .Endpoint.Ports}}'`).
Never read `ufw status` as real exposure; sweep the ports from off-node.

### `iptables-persistent` races Docker at boot

Do not persist `DOCKER-USER` rules with `iptables-persistent`: its boot
restore races Docker creating the chain. `harden-node.sh` uses a systemd
oneshot ordered `After=docker.service` (`docker-wan-drop.service`), which
cannot lose that race. Verified across a real vps02 reboot, not assumed.

### Three load-bearing details in `docker-wan-drop.service`

Three load-bearing details in that oneshot. `-w 5` on every
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

### `harden-node.sh` never restarts Docker

`harden-node.sh` writes `/etc/docker/daemon.json` but deliberately never
restarts Docker: on vps00 that restarts the Swarm control plane and every
container. The loopback-bind layer is inactive until the next Docker
restart or reboot; the `DOCKER-USER` drops apply immediately, so the node
is closed either way.

### `daemon.json`'s `"ip"` misses Swarm host-mode publishes

`daemon.json`'s `"ip": "127.0.0.1"` does **not** apply to a Swarm
service's host-mode publish. Measured on vps00 after a reboot with the
setting active: `dokploy-traefik` (plain container) moved to
`127.0.0.1:80`/`:443`, but the `dokploy` service's 3000 still binds
`0.0.0.0` **and** `[::]`. So on vps00 the `DOCKER-USER` rule closes 3000
*alone*, unbacked: if `docker-wan-drop.service` ever fails to start, 3000
faces the internet behind only the Dokploy admin password. Check
`systemctl is-active docker-wan-drop` before trusting a port sweep taken
from inside the node.

### Two scripts write `daemon.json`

Two scripts write `daemon.json`: `harden-node.sh` (`"ip"`) and
`setup-maintenance.sh` (`log-driver`/`log-opts`). They avoid clobbering
each other only because `setup-maintenance.sh` recognises harden's file
by an exact whitespace-stripped match on `{"ip":"127.0.0.1"}`, warning on
anything else. Change what either writes, fix the other's match in the
same commit.

### A `docker-ce` upgrade does not flush `DOCKER-USER`

An unattended `docker-ce` upgrade restarts dockerd, which does not flush
`DOCKER-USER`: Docker creates that chain when absent and never rewrites
its contents, the chain's whole purpose. Rail 1's iptables layer survives
the restart, which is why `unattended-upgrades` is safe here.

### Dokploy's uncapped control plane, and two cap mechanisms

Dokploy's control plane was uncapped by default: `dokploy` alone observed
at ~913MiB on a 1.9GiB node, `dokploy-postgres` ~67MiB. Two cap
mechanisms, don't mix up: `dokploy`/`dokploy-postgres` are Swarm services
(`docker service update --limit-memory`; plain `docker update` is
silently reconciled away), `dokploy-traefik` is a plain container
(`docker update --memory`; `docker service update` 404s on it). None of
it is declarative and all of it comes from `bootstrap-dokploy.sh`'s
upstream installer, so reapply caps after any reinstall or upgrade.
Re-applying restarts the service's tasks, so the script compares first:
that is what keeps a second run a no-op, not a control-plane bounce.

### `cap-dokploy-resources.sh` only ever worked on vps00

`cap-dokploy-resources.sh` only ever worked on vps00: its payload runs
under `set -eu` and opened with `docker service update ... dokploy`, but
`dokploy` and `dokploy-postgres` are vps00-only, so on vps01/vps02 it
aborted on line one and never reached the `dokploy-traefik` cap, which is
why traefik was capped on vps00 and unbounded on both secondaries. Each
cap now skips a missing target with a message instead of dying. When a
script targets "every node", check what is actually on the secondaries.

### No swap means OOM kill, not slowdown

A transient memory spike (app startup, migrations) on a no-swap node is a
hard OOM-kill, not a slowdown. Misdiagnosed once as a Calcom "build
process" failure on vps01 when it was an OOM kill under a too-tight
`mem_limit`. `add-swap.sh` fixes the swap side; the app's own
`mem_limit`/`mem_reservation` (rail 4) still needs headroom.

### Real node IPs in usage examples

Never put a real node IP in a script's usage example. Five scripts here
did, publishing two nodes' addresses in a public repo beside a full
description of what runs on them. Use RFC 5737 addresses (`203.0.113.10`
vps00-shaped, `.11` vps01, `.12` vps02) and point at
`infra/inventory.yaml` for the real ones. Enforced by the `no-real-ips`
local pre-commit hook; rail 5 was a sentence with nothing checking it,
same drift class as rail 9.

### `install-docker.sh` no longer pipes into a root shell

`install-docker.sh` no longer pipes `get.docker.com` into a root shell;
it configures Docker's apt repo and keyring directly. Same end state
(verified against a node the convenience script had already
provisioned), but packages are GPG-verified and upgrades arrive through
apt. Residual risk is the initial key fetch, still trust-on-first-use
over TLS. Untested on a fresh node, since all three were provisioned
before it changed: watch this step if a new node is ever built.

### `bootstrap-dokploy.sh`'s sha256 is a record, not a check

`bootstrap-dokploy.sh` still runs a vendor installer; Dokploy has no apt
repo. It downloads to a file and prints the sha256 before executing. That
is a *record*, not a verification: no published checksum exists to
compare a first run against. Don't upgrade the claim.

## `stacks/`: Netdata, alert delivery, tunnel tokens

### Netdata notifications were dead on all three nodes

Netdata notifications were dead on **all three nodes** from setup until
2026-08-18 and nothing surfaced it: `deploy.yml` wrote
`health_alarm_notify.conf` with `umask 077`, giving `600 deploy:deploy` (uid
1000), unreadable by the container's netdata user (uid 201). Every alarm since
failed to deliver, including the tightened 80/90 RAM and disk alarms, and the
config looked present and correct on the host — which is why it went unnoticed
so long. Fixed by writing the file into the netdataconfig volume as uid 201
(Alert delivery above). When a container reads a secret file, check the
*in-container* uid and test as that user, not root.


### `alarm-notify.sh` enables email by default

`alarm-notify.sh` enables **email by default**, so with Telegram configured
and no MTA every alert also ran sendmail and logged `account default not
found` (error 78) — three errors per transition and a non-zero exit. Telegram
still delivered, so nothing was lost, but that steady error stream hid the
broken config above. `SEND_EMAIL="NO"` in the templates. The templates' claim
that every unlisted method "stays at its built-in default (disabled)" was
simply wrong about email; check a notifier's default before writing that.


### `sed -i` breaks bind-mounted single files

`sed -i` does **not** propagate into a bind-mounted single file: it writes a
new inode and the container keeps reading the old one. Use `cat new > file`
for in-place edits of mounted configs (`netdata.conf`, `health.d/*.conf`).


### Dokploy v0.29.14 has no 2FA and no audit log

Dokploy v0.29.14 has **no 2FA and no login/audit log** (absent or
license-gated). Verified empirically, not from docs: 30 days of `docker
service logs dokploy` is 38 lines with zero auth events. Don't plan a security
control around either existing. Authentication and the access log live in
Cloudflare Access instead (Zero Trust → Logs → Access), the better placement
anyway: it records attempts that never reach the origin.


### vps00 and vps01 once shared one tunnel token

vps00 and vps01 once shared one `CLOUDFLARE_TUNNEL_TOKEN`. Cloudflare
load-balanced `dokploy.maybeit.work` across both connectors; vps01 had nothing
on that origin port, so ~2/3 of requests 502'd. Fixed by giving vps01 its own
tunnel + token (rail 2). Never reuse another node's token when adding a
service here.

## `stacks/vps01/`: backups, R2, drills, staleness alarms

### A restore drill is a workload, not an inspection

A restore drill runs a *second* database on a node already running the first:
the capped 512m `mysql:8.0` drill container on 2026-08-19 took vps01 from 4M
to 61M of swap while production stayed up. Always cap a drill container
explicitly, and never drill during the 03:00/04:00 backup window; on a 2GB
node the drill is itself a workload, not an inspection.


### macOS `zcat` is not Debian's

macOS `zcat` is not Debian's: it appends `.Z` and fails on a `.gz`, so a
dump-integrity check written as `zcat` verified fine on the node and rejected
a *good* archive when dry-run on a laptop. Use `gzip -cd`; same meaning on
both.


### The alarm that was armed and silent for a day

`ezbookkeeping_backup_age` executed no notification from 2026-08-18 07:31:50Z
until the 2026-08-19 drill. **Root cause:** netdata's
`health_alarm_execute()` suppresses a notification when the most recent entry
for the same `alarm_id` carrying `EXEC_RUN` has the **same status** as the new
transition ("don't send the same notification twice"). That alarm last
executed 07:31:50Z as CRITICAL, so every CRITICAL after was dropped as a
duplicate. The escape hatch is a CLEAR that executes and resets the chain, and
the then-current `delay: down 1h multiplier 1.5 max 4h` in
`health.d/backup.conf` blocked exactly that: every CLEAR held an hour, the
alarm re-fired first, the CLEAR was superseded (`UPDATED`) before its delay
expired (`delay: 3600` on every CLEAR in the records). The two interlock; a
long `down` delay is fine for a dashboard, useless for notification. **Not**
recipient-specific: a throwaway `to: sysadmin` alarm on vps02 fired with
`EXEC_RUN` and `exec_code=0`, and replaying netdata's real-mode arguments by
hand delivers as both `netdata` and `root` — script, config and token were
never at fault. Lesson: **an alarm can look armed on the dashboard while being
permanently silent for one status.** Verify with a real transition, never an
interactive `alarm-notify.sh test`, and never make a Netdata alarm the only
delivery path for something that matters. (Two earlier wrong write-ups and a
superseded clause about restart persistence are archived; the correction is
the next entry.)


### Dedup state resets on `config_hash_id`, not on restart

Netdata's dedup state resets when an alarm's `config_hash_id` changes, not
merely on restart (measured 2026-08-19: `046da83b…` → `4686c70f…` at the
04:46:03Z restart, no transition recorded, wedge gone by the 10:01:03Z drill).
So when an alarm is stuck silent, edit its `.conf` and redeploy; do not just
restart netdata. Re-run the stale/recover/stale drill after any change to
`health.d/backup.conf`, to prove CRITICAL → CLEAR → CRITICAL all execute.


### rclone calls `CreateBucket` before uploading

rclone's S3 backend calls `CreateBucket` before uploading, to create the
bucket if missing. An R2 token scoped to Object Read & Write cannot, so every
upload died with `403 AccessDenied: CreateBucket` while the credentials were
fine. Fix is `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`, not a wider token. Read
the API call named in a 403 before assuming the key is wrong.


### vps01's clock is UTC-4

vps01's system clock is **UTC-4**, not UTC (backup log stamped `-04:00` while
rclone logged UTC). A cron entry written as plain UTC fires four hours off, so
do not assume these nodes are UTC: schedule hourly and gate on
`TZ=<zone> date +%H` inside the script. (Superseded `CRON_TZ` advice archived;
next entry says why.)


### Debian 12's cron ignores `CRON_TZ`

Debian 12's cron **ignores `CRON_TZ`** (verified on vps01 2026-08-18: a
`CRON_TZ=Asia/Manila` entry set to fire 3 minutes out in Manila time never
ran). The backup was therefore running 03:00 *node-local*, not Manila, and
`deploy.yml`'s comment claimed otherwise. Fixed by running the scripts hourly
and gating on `TZ=Asia/Manila date +%H` inside them. Never trust a
timezone-aware cron entry here without testing it with a near-term throwaway.


### `crontab -` replaces the whole crontab

`deploy.yml`'s "Install backup cron" step pipes into `crontab -`, which
**replaces the deploy user's entire crontab**, it does not append. All four
vps01 entries (`backup-ezbookkeeping.sh` `:00`, `check-backup-age.sh` `:30`,
`backup-booking.sh` `:10`, `check-backup-age.sh booking …` `:40`) therefore
live in one heredoc in that step. Add any new scheduled job to that heredoc;
installing one by hand or in a second step silently deletes the rest.


### `rsync --delete` deleted vps01's `backup/`

`deploy.yml`'s `rsync -az --delete stacks/vps01/` **deleted
`/opt/stacks/vps01/backup/`** on every deploy: the run log, the local archive,
and the `.last-success` stamp the Netdata age alarm reads. The alarm did its
job and sat CRIT ~13.7h unnoticed. Fixed with `--exclude 'backup/'`, now
alongside `--exclude 'backup-booking/'`, `--exclude '.r2.env'`,
`--exclude '.telegram.env'`. Any node-side state under a directory an rsync
`--delete` targets needs an exclude, added in the same commit as the state.

## `worker/status/`: the status Worker and its poller

### Never hash the working tree

**Any deployed-vs-repo comparison pins to an explicit ref — `git cat-file
blob <ref>:<path>` — and never hashes the working tree**, which is shared
mutable state under concurrent agents. An agent proving the Worker deployed
to Cloudflare matched the repo SHA-1'd `worker/status/src/page.html` and
compared it against the hash embedded in the deployed module's part name;
its first and second measurements **disagreed** (2026-08-20). The tool was
not lying and the deploy had not changed: a concurrent process moved `HEAD`
between two bash calls (`docs/claude-md-self-audit` →
`docs/mcp-and-skills-in-context`), and this repo additionally carries three
live agent worktrees under `.claude/worktrees/`. The disagreement is what
saved it — had the two measurements happened to agree, a wrong "deployed
matches repo" would have been recorded as verified. Same class as the
gitleaks `--staged` scan that scans nothing under `--all-files` and the
`find`-based budget check that returned a silently wrong count with exit 0:
a measurement that produces a confident number from the wrong input.

### Netdata chart ids were guesses

Verify Netdata chart ids against the live node; two of `poll.js`'s were
wrong guesses at first deploy, caught against vps00's `/api/v1/charts`
(2026-08-16). `system.cpu` has no `idle` dimension in this deployment, so
`queryCpuBusyPercent` sums the busy-state dimensions, falling back to
`100 - idle` where a config does report one. The root filesystem chart id
keeps the literal `/` (`disk_space./`), not `_` as guessed.
`system.ram`/`used` was right.

### `system.load` cannot use `options=percentage`

`system.load`'s dimensions (load1/load5/load15) are each an absolute load
average and don't sum to a whole, unlike `system.ram`/`mem.swap`, so
`options=percentage` is meaningless there — hence `queryRaw` vs
`queryPercent`, confirmed against a live node before wiring. load1 becomes
a 0-100 score by dividing by `NODE_VCPUS` (2, this homelab's fixed spec)
and clamping.

### Cron Triggers get 403'd by Access, at any depth

Cloudflare Cron Triggers can't reliably poll this account's own
Access-protected Netdata apps. With a confirmed-working
`CF_ACCESS_CLIENT_ID`/`SECRET`, `scheduled()` calling `pollAll` got a 403
from Access on every Netdata call, every tick, while the identical call
from a real HTTP-triggered `fetch()` worked every time. Making
`scheduled()` self-fetch `/__poll`, so the poll ran inside a nested
`fetch()`, **didn't work either**: still 403 next tick, though plain curl
to `/__poll` from outside Cloudflare always worked. So it isn't handler
type — anything in a request chain rooted at a Cron Trigger gets hit,
however many hops deep. Root cause unconfirmed (Cloudflare-side, nothing
in this repo to dig with). Fix: no Cron Trigger, no `[triggers]` in
`wrangler.toml`, no `scheduled()`. Trade-off accepted: the first
`/status.json` after the TTL expires waits on live Netdata calls. The KV
write has two jobs now, backing the `POLL_TTL_MS` freshness cache and
carrying `lastSeen` forward so a node that's down right now still shows
when it was last up. (Pre-TTL wording "polls fresh on every page load"
archived 2026-08-20 in `docs/superpowers/failure-log-archive.md`; false
once the TTL landed.)

### vps02's 530 was Cloudflare, not Access

vps02's tunnel showed `Inactive` / 0 replicas: cloudflared there had never
once connected, and Netdata calls returned 530 — Cloudflare-level, not an
Access 403, and the status code is what tells you which layer failed.
Fixed by rotating the token (dashboard → Tunnels → vps02-metrics → Rotate
token), updating `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, re-running
`deploy.yml`; healthy at 1 replica after. The bad token is unexplained,
likely a bad paste when a human first set it.

### Status dots were matched by array index

Grep for order-sensitive output from a concurrently-filled object whenever
one shows up. `page.html` matches status dots to nodes by **array index**,
not name (`SERVICES.forEach((s, i) => ...d${i}/v${i}...)`), and the first
`toStatusJson` built its array from `Object.entries(snapshot.nodes)` —
fine locally, but `pollAll` fills that object from concurrent per-node
promises, so a slow vps00 poll landing after a fast vps01 one would have
silently mislabeled a node's stats under real network jitter. Fixed by
building from `NODE_HOSTS.split(',')`.

### `pollDokploy`: correct code, wrong blast radius

Weigh a credential's blast radius against what the call buys, not against
whether the call is correct. `pollDokploy` was correct by the end (service
token, `redirect: 'manual'`, explicit 2xx test) and still wrong to keep: a
public internet Worker holding a credential to the **deploy control plane**
for an up/down boolean `toStatusJson`'s allowlist kept off the public page
entirely, surfacing only in `/debug`, which only Ex can open. Leaking the
Worker's secrets meant full infra access, not a CPU graph. Removed
2026-08-20 with `DOKPLOY_HOST`, token dropped from the Dokploy Access
policy, and `test/poll.test.js` guards it: `pollAll` must request no host
outside `NODE_HOSTS`, with `DOKPLOY_HOST` still set in that test's env so a
stale var can't revive it. Its earlier shape's lesson is worth keeping for
any future poller: it did an unauthenticated `GET` with
`up = res.status < 500`, and the runtime follows the Access `302` to a
`200` login page, so the tile would have stayed green forever. When a
polled origin gains an auth gate, re-check what the poller proves — "up"
must mean the origin answered, not its login page. (Narrative archived 2026-08-20 in
`docs/superpowers/failure-log-archive.md`.)

### The `*-metrics` hosts are separate Access apps

`dokploy.maybeit.work` and each `*-metrics` host are **separate** Access
applications, not one shared app: confirmed 2026-08-20 by their distinct
`aud`/`kid` in the login redirect. A `poll.js` comment claimed they shared
one, which is why a single token opening both read as unavoidable rather
than as a policy that needed narrowing.

### The Zero Trust API returns empty, not 403

The `wrangler login` OAuth token can't read or write Access config, and the
Zero Trust API returns `success: true` with an **empty result set** rather
than a 403. Never read that as "no Access apps configured" — an empty list
from that API means "look at your token's scopes first", and curling the
hostname for the `302` to `<team>.cloudflareaccess.com` stays a valid
cross-check.

**The conclusion drawn from that, "Access work is dashboard-only", was
wrong; superseded 2026-08-20 by live calls on this account.** The symptom
was diagnosed right and the cause wrong: this is **credential scope**, not
an API limitation. The `wrangler login` OAuth token lacks Access scopes,
and the Zero Trust API's failure mode for an under-scoped token is that
empty success — which is exactly what made it read as a platform limit. A
differently-scoped credential reads the same endpoints fine: the
`cloudflare-api` MCP server's credential got `success: true`, HTTP 200, and
**5 real apps** from `GET /accounts/{id}/access/apps` — `dokploy`
(`dokploy.maybeit.work`), a second path-scoped `dokploy` app on
`dokploy.maybeit.work/api/deploy`, and
`vps00-metrics`/`vps01-metrics`/`vps02-metrics`. Policies are readable per
app: `dokploy.maybeit.work` carries only `owner email allow`; the
path-scoped `/api/deploy` app carries `webhook-bypass` (decision `bypass`,
include `everyone`); `vps00-metrics` carries `status-worker service auth`
(decision `non_identity`, include `service_token`) plus `owner email
allow`. `GET /accounts/{id}/access/service_tokens` returns one token,
`status-worker`. That independently **confirms** the security claim in
`worker/status/CLAUDE.md` that the `status-worker` service-token policy was
detached from the Dokploy application — it is genuinely absent from that
app's policy list, which until now was assertable only from the dashboard.

Generalised, because it is this repo's most-repeated failure class: **an
empty success response is not evidence of absence, and "the platform can't
do this" is a conclusion that needs a second credential tried before it
gets written down.**

### A security comment citing a script that did not exist

A comment asserting a security invariant is worthless unless something
checks it: `index.js`'s `PAGE_HEADERS` comment claimed `page.html` "writes
data with textContent, never innerHTML" while the vendored page did use
`innerHTML` for the metric readout. It then said `scripts/check-rails.sh`
greps for markup sinks — that script did not exist until 2026-08-20, so
the fix and its stated enforcement were both fiction for months. The grep
is real now (`check-rails.sh`, fire-tested). When you re-copy `page.html`,
re-read every comment claiming something about its contents, and verify a
named check exists before citing it.

## `infra/`: inventory and human SSH access

### Provider images, not stock Debian

Never state a node's sshd setting from Debian's documented default: these
are provider images. `PermitRootLogin yes` sat uncommented at line 33 of
`/etc/ssh/sshd_config` on all three while this file, `README.md` and a
security audit asserted `prohibit-password` because stock Debian ships that.
Not exploitable (`PasswordAuthentication no` plus
`KbdInteractiveAuthentication no` left keys as the only method) but false
for months, and only `sshd -T` on the box revealed it — `sshd -t` checks
syntax, not effective values. Measured 2026-08-20 while chasing an unrelated
sshd finding, which is the only reason anyone looked.

### A key is rejected for a user, never in general

Name the user in an SSH finding, and test both. "Key X is rejected by all
three nodes" was recorded 2026-08-18 after testing `~/.ssh/id_ed25519_vps`
as `deploy@` only; it is the root key and works as `root@` everywhere. A key
is rejected *for a user*, never in general.

## `dokploy/`: compose apps Dokploy pulls from git

### ezBookkeeping's upload path was never mounted

ezBookkeeping writes transaction pictures to `/ezbookkeeping/storage`, a
path the first version of its compose file never mounted, so any receipt
photo would have lived in the container layer and vanished on redeploy. When
adding a container that accepts uploads, check where it writes them
(`du -sh /<appdir>/*` in the running container) rather than assuming the
database volume covers user data.

### Cloudflare caches `/server_settings.js` for 4 hours

Cloudflare caches ezBookkeeping's `/server_settings.js` (origin sends
`cache-control: max-age=14400`), so after flipping an env-driven feature
flag the login page can keep showing the old state for up to 4 hours. Do not
conclude the env change failed: check the container (`env | grep EBK_`) and
`curl` the origin file, then purge by hostname in Caching → Configuration →
Custom Purge. Verified 2026-08-18 turning `EBK_USER_ENABLE_REGISTER` off:
the container read `false` and `_['r']=0` while the browser still offered
"Create an account".

## `.github/workflows/`: validate, deploy, deploy-worker

### `docker compose pull` on an empty stack

A stack with `services: {}` makes plain `docker compose pull` error out
with nothing to pull. The pull/up step is guarded (`if [ -n "$(docker
compose config --services)" ]`). Keep the guard; don't cut it as dead
code without checking every node's stack first.

### deploy-vps02 wrote vps00's token

deploy-vps02's `.env` step used to write vps00's shared
`CLOUDFLARE_TUNNEL_TOKEN`. vps02 now has its own
`CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`, same pattern as vps01. Never
wire in vps00's token (rail 2). Full original entry in
`docs/superpowers/failure-log-archive.md`.

### `rsync --delete` and the excludes it needs

`rsync --delete` wiped vps01's `backup/` on every deploy until
2026-08-18: the run logs and the `.last-success` stamps the staleness
check reads are **node** state, not repo state. `.r2.env` /
`.telegram.env` are excluded for a subtler reason: `--delete` removes
them and later steps write them back, so a deploy overlapping the `:30`
staleness check made it exit 1 on "`.telegram.env` missing" and skip that
hour silently. `.env` is deliberately not excluded; nothing reads it
between the rsync and its rewrite.

### `paths:` listed `infra/`

`deploy.yml`'s `paths:` listed `infra/` until 2026-08-19 although nothing
under it is ever rsynced. A docs-only edit to `infra/CLAUDE.md` queued a
full three-node production deploy that sat 13h at the approval gate and,
once approved, shipped a by-then stale `deploy.yml` that wiped vps01's
backup state. Trigger deploys only on paths that reach a node.

### The 403 was a country rule, not bot protection

A post-deploy check probing the **public hostnames from the runner**
failed every probe with `403` while every service was healthy. The first
diagnosis (bot protection rejecting datacenter IPs) was **wrong**: it is
a zone-wide Cloudflare custom rule, `Block non-local traffic`, matching
`ip.src.country ne "PH"`, so every GitHub runner and both US-hosted nodes
are blocked. Amended 2026-08-19 after reading Security → Events instead
of inferring from response codes. `maybeit.work` is exempt now, the other
hostnames are not, so CI still cannot probe them. Read the matched rule
in Security Events before theorising about a 403.

### The post-deploy check raced its own restart

The rewritten node-side check then failed on its first real run with
`FAIL netdata: 503` on all three healthy nodes: the Deploy step ends with
`docker compose restart netdata` and Netdata answers 503 for ~5s while it
initialises, so one immediate request races the restart it just caused.
Fixed by polling (30 tries, 2s apart); it had passed by hand only because
the agents had been up for hours. A post-deploy check runs at the worst
possible moment by definition: give every probe a retry budget, and test
it right after a restart rather than on a warm node.

### gitleaks is logged in root, not here

The `gitleaks` hook scans staged changes only, so it contributes nothing
under `pre-commit run --all-files` in `validate.yml`. Kept once, in
root's failure log; don't duplicate it here.
