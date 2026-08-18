# Handoff, ezBookkeeping + backups + fleet alerting

**Written:** 2026-08-18, after adding ezBookkeeping, building nightly R2
backups, and fixing Netdata notifications across all three nodes.

**Audience:** the next agent. Read `.claude/CLAUDE.md` (root) and the
relevant directory `CLAUDE.md` first; the hard rails there apply on top of
this document. No real IPs appear here (rail 5): read them from
`infra/inventory.yaml` (gitignored) at run time.

Commits are cited by **message, not SHA** (a `git filter-repo` rewrite
invalidates SHAs, see root failure log).

---

## What shipped

| Area | State |
|---|---|
| ezBookkeeping | Live at `budget.maybeit.work` on vps01, SQLite, 256m cap, registration off |
| Pictures | `storage` volume mounted, 10 MB per-upload ceiling |
| Backups | Nightly 03:00 Asia/Manila to R2 `homelab-backups`, verified end to end |
| Backup alarm | Netdata plugin + `health.d/backup.conf`, warn 36h / crit 72h |
| Netdata → Telegram | Fixed on all three nodes, test notifications delivered |
| Booking app | Migrated into `dokploy/booking/`, image pinned `1.6.0`, MySQL cap 640m |
| Dokploy autodeploy | Cloudflare Access bypass added for `/api/deploy/*` |
| SSH access | Documented in `infra/CLAUDE.md`; local ssh config fixed |

Relevant commits: "feat(dokploy): add ezBookkeeping compose app for vps01",
"feat(ezbookkeeping): persist transaction pictures, cap upload size",
"feat(vps01): nightly ezBookkeeping backups to R2 with age alarm",
"fix(vps01): stop rclone calling CreateBucket on every backup",
"fix(stacks): Netdata could never read its notification config",
"feat(dokploy): bring the booking app into the repo",
"docs(infra): record how humans SSH to the nodes".

---

## To do, in priority order

### 1. Restore drill (highest value, never done)

Backups are proven to be *created*; they have never been proven
*restorable*. Until that test runs, treat the backup system as unverified.

Restore the newest `daily/` object into a scratch Dokploy app, confirm the
books open and a receipt image renders, then delete the scratch app. Record
the date it last passed in `stacks/CLAUDE.md`. See the restore notes in the
alerting/backup section there.

### 2. Five Dependabot PRs (#1-#5)

Open since before this session. #4 (`webfactory/ssh-agent` 0.9.0 to 0.10.0)
is load-bearing: every `deploy.yml` job uses it. The others bump
`actions/cache`, `setup-python`, `checkout`, `setup-node`. Root failure log
requires exact pinning, and these keep the SHA pins current. Review, then
merge one at a time and watch a deploy afterwards, since `deploy.yml` sits
behind a `production` environment gate needing manual approval.

### 3. Silence the sendmail error in alerts

Every Netdata alert also attempts email to `root` and fails
(`sendmail: account default not found`), because the stock role config
sends to both Telegram and email and no MTA exists. Telegram still
delivers, so alerts are not lost, but every alarm logs an error and
`alarm-notify.sh` exits non-zero. That noise is what hid the broken
notification config for weeks. Fix: `SEND_EMAIL="NO"` in
`stacks/*/health_alarm_notify.conf.template`.

### 4. README is stale (public document)

Found by the 2026-08-18 self-audit. `README.md` does not mention the
`dokploy/` tree, either live app by name (`booking.maybeit.work`,
`budget.maybeit.work`), or backups/R2 at all. Its repo-layout tree skips
`dokploy/`. Root's audit protocol calls out `README.md` specifically as the
only public document, where a stale claim is a claim made to strangers.

### 5. Directory map missing `docs/`

`docs/` (this tree) is absent from the directory map in `.claude/CLAUDE.md`.
The propagation protocol says to keep that column current in the same commit
a directory appears.

### 6. Record the Access bypass in the repo

The Cloudflare Access application `dokploy.maybeit.work/api/deploy`
(policy `webhook-bypass`, Bypass/Everyone) exists only in Cloudflare and in
the agent's memory. Nothing in `dokploy/CLAUDE.md` explains why that path is
unauthenticated or what to check when autodeploy silently stops. Same class
as the rail-9 and gitleaks entries: a control nothing in the repo describes.

### 7. Root SSH access is unaccounted for

`scripts/*.sh` default to `SSH_USER=root`, but `root@` is refused by every
key on Ex's laptop; only `deploy` (no sudo) works. Whoever ran
`setup-maintenance.sh` on 2026-08-16 had root access we cannot reproduce.
Establish and document how root is reached, or convert the scripts to a
path that works with `deploy` plus Docker.

---

## Verify-first notes

- **Autodeploy is fixed but unproven.** The Access redirect is gone
  (`/api/deploy/*` reaches Dokploy, `/` and `/api/trpc/*` still 302), but no
  merge has yet triggered a deploy on its own. The next merge touching
  `dokploy/` is the real test.
- **Netdata's failure mode is silence.** Test delivery as the container's
  own user, never as root: root can read the config regardless, so a root
  test passes on a broken setup. See `stacks/CLAUDE.md`.
- **Volume names carry the Dokploy project prefix.** Renaming or recreating
  a Dokploy app orphans its volume and brings the app up empty. This is why
  the booking migration switched the existing app's provider instead of
  creating a new one.
