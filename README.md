# homelab-but-the-home-is-silent

[![validate](https://github.com/nineW0nW0n/homelab-but-the-home-is-silent/actions/workflows/validate.yml/badge.svg)](https://github.com/nineW0nW0n/homelab-but-the-home-is-silent/actions/workflows/validate.yml)
[![license: AGPLv3](https://img.shields.io/badge/license-AGPLv3-blue.svg)](./LICENSE)

GitOps infrastructure for a 3-node Debian 12 VPS homelab: plain Docker
Compose on each node, Cloudflare Tunnel for public access with zero
inbound ports, GitHub Actions as the only path to production. There is no
web control plane: Dokploy ran here until 2026-08-23, and removing it
freed ~800 MB on the primary node.

> [!NOTE]
> **Status: work in progress.** Nodes are provisioned, hardened, and
> deployable via CI. Cloudflare Tunnel and three workloads are
> live: `booking.maybeit.work` (EasyAppointments) and
> `budget.maybeit.work` (ezBookkeeping), both on vps01. A third,
> centralised logging (OpenObserve on vps02, `siem.maybeit.work`), has
> been ingesting the systemd journal and every container's output from
> all three nodes since 2026-08-23. ezBookkeeping is
> backed up nightly off-site to Cloudflare R2; the booking database is
> scheduled the same way — a forced end-to-end run has been proven, and
> the latest unattended stamp lives in `.last-success` on vps01.
> Expect rough edges. `main` is protected
> against force-push and deletion, so fixes land as new commits, not
> rewrites.

## 🗺️ Topology

| Node  | Role      | Notes                                                     |
|-------|-----------|-----------------------------------------------------------|
| vps00 | primary   | own `cloudflared`; the tunnel for the status page and its metrics |
| vps01 | secondary | both apps + own `cloudflared`                              |
| vps02 | secondary | OpenObserve logs + own `cloudflared`                       |

All three also run Netdata (bound to loopback) and Vector (ships logs to
vps02). Plain Docker Engine, no Swarm, no reverse proxy: each app publishes
one loopback port and `cloudflared` dials it directly.

2 vCPU / 2GB RAM each. Real IPs are never committed.
`infra/inventory.example.yaml` is the redacted template, usage examples in
`scripts/` use RFC 5737 documentation addresses (`203.0.113.x`), and a
pre-commit hook fails the commit if a routable IPv4 address appears in a
tracked text file. It matches dotted quads only: IPv6 literals pass, binary
files are not scanned, and `worker/status/package-lock.json` and
`worker/status/node_modules/` are excluded.
Note the `vps0N.maybeit.work` names are
inventory labels with no DNS records; they are not substitutes for an
address.

Each node stays independent and hosts its own apps rather than pooling
resources, which fits three boxes this small a lot better than clustering
them.

```mermaid
flowchart LR
    internet(("Public traffic")) --> tunnel["Cloudflare Tunnel\n(outbound-only)"]
    tunnel --> vps00["vps00, primary\nmetrics"]
    tunnel --> vps01["vps01, secondary\napps"]
    tunnel --> vps02["vps02, secondary\nlogs (OpenObserve)"]

    subgraph ci["GitHub Actions"]
        validate["validate.yml\nlint gate"] --> deploy["deploy.yml"]
    end

    deploy -. "one approval, then parallel" .-> vps00
    deploy -.-> vps01
    deploy -.-> vps02
```

## 🔒 Network model

> [!IMPORTANT]
> No node has an open inbound port except SSH (22). All public traffic
> (the apps, the log UI, the metrics) arrives through Cloudflare
> Tunnel, which is outbound-only from each node's side.

**UFW alone does not deliver that**, and for a while this README claimed
it did while ports 80, 443 and 3000 answered from the internet. Docker
inserts its own `nat`/`DOCKER` rules that are evaluated *before* UFW's
chains, so every container-published port bypasses the firewall no matter
what `ufw status` says. Two layers close it, both applied by
`harden-node.sh`:

- a drop for all new inbound traffic on the WAN interface in
  `DOCKER-USER`, the one chain Docker will not rewrite, reapplied at boot
  by a systemd unit ordered after `docker.service`. IPv4 is mandatory --
  a missing chain fails the unit loudly; IPv6 is best-effort, skipped with
  a warning wherever `ip6tables` has no `DOCKER-USER` chain;
- `"ip": "127.0.0.1"` in `/etc/docker/daemon.json`, so newly published
  ports do not land on `0.0.0.0` by default. `harden-node.sh` writes that
  file but never restarts Docker, so this layer is inert until the next
  Docker restart or reboot -- the `DOCKER-USER` drop is what holds the
  node until then.

Neither layer covers ingress-mode Swarm publishes, which traverse a
different chain (`DOCKER-INGRESS`), and `daemon.json`'s `"ip"` does not
apply to Swarm *host-mode* publishes either: measured on vps00, a
host-mode service still bound `0.0.0.0` with the setting active. Swarm is
inactive on every node since 2026-08-23, so neither case is live today.

That is precisely why the check that matters is a port sweep from
off-node, not `ufw status`. That sweep now runs daily in CI
(`.github/workflows/port-sweep.yml`), failing on any open port but 22; a
manual sweep remains the post-provisioning check after any hardening run.

Public hostnames that should not be public are behind **Cloudflare
Access**: all three Netdata endpoints, the OpenObserve UI, and
`budget.maybeit.work` require authentication at the edge, before the
tunnel. `booking.maybeit.work` is deliberately **not** — it is the public
booking page clients use, and locking it behind Access would defeat its
purpose. Do not "fix" that.

`cloudflared` runs in token mode (`tunnel run` + `TUNNEL_TOKEN`), and
public-hostname routing is configured in the Cloudflare Zero Trust
dashboard, not a file in this repo. `network_mode: host` is required on
every `cloudflared` service: bridge mode puts it in its own network
namespace, breaking `localhost:PORT` origin URLs.

**One tunnel token per node, never shared.** Cloudflare load-balances a
hostname's requests across every connector registered to its tunnel: a
route isn't pinned to a specific node. Two nodes sharing one token means
requests for either node's app can land on the wrong node and 502. Each
node that serves something gets its own tunnel and its own token.

**Not reachable from most of the world.** A zone-wide Cloudflare custom
rule blocks every request whose source country is not the Philippines,
across every hostname, with one exemption for the `maybeit.work` apex so
the status page is publicly readable. `booking` and `budget` are therefore
unreachable outside PH by design. Any non-PH client, including GitHub
Actions runners and the nodes themselves, gets a `403` that looks exactly
like an outage and is not one. The rule lives only in the Cloudflare
dashboard, so nothing in this repo can restore it.

All three Netdata agents are also **claimed into Netdata Cloud**, an
outbound HTTPS connection to a third party from every node. It opens no
inbound port, so the statement above still holds, but it is a dependency
worth naming next to a zero-inbound-ports posture.

## 📦 Repo layout

```
.yamllint, biome.json                strict lint config (YAML; JS/TS/JSON/CSS)
.pre-commit-config.yaml              enforced pre-commit + CI
.github/
  dependabot.yml                     weekly bumps for SHA-pinned actions + worker npm deps
  workflows/
    validate.yml                     pre-commit over the whole repo, reusable via workflow_call
    deploy.yml                       one approval, then all three nodes in parallel
    deploy-worker.yml                tests + deploys the status Worker (same production approval)
    port-sweep.yml                   daily off-node port sweep of all three nodes
infra/
  inventory.example.yaml             redacted node IP template (real IPs stay gitignored)
stacks/
  vps0N/docker-compose.yml           per-node cloudflared connector + Netdata + Vector (vps01 adds the two apps, vps02 OpenObserve)
  vps0N/vector.yaml                  journal shipper config, byte-identical on all three nodes
  vps0N/netdata.conf, health.d/      loopback bind, tightened RAM/disk alert thresholds
  vps01/backup-ezbookkeeping.sh      nightly off-site backup to Cloudflare R2
  vps01/backup-booking.sh            nightly MySQL dump to Cloudflare R2
  vps01/check-backup-age.sh          hourly staleness alert, straight to Telegram
worker/status/                       Cloudflare Worker: maybeit.work status page + health poller
docs/superpowers/                    handoffs, plans and specs from past sessions
scripts/
  provision-deploy-user.sh           create the CI deploy user, key-only, rsync installed
  install-docker.sh                  Docker Engine from Docker's apt repo
  harden-node.sh                     UFW, key-only sshd, Fail2Ban, DOCKER-USER drops
  add-swap.sh                        swap file (these nodes ship with none)
  setup-maintenance.sh               journald log driver for containers, journald cap, weekly docker prune, unattended security upgrades
  install-aide.sh                    AIDE file-integrity baseline + daily check into the journal
```

One deploy path: `deploy.yml` rsyncs `stacks/` to the nodes and runs
`docker compose up` there. Nothing else puts a container on a node.

All scripts are idempotent, POSIX `sh`, shellcheck-clean, and safe to
re-run; most matter again if a node ever gets rebuilt from scratch.

## CI/CD

- `validate.yml` runs on every PR and push to `main`: pre-commit over all
  files: `yamllint --strict`, `actionlint`, `shellcheck`, `biome ci`, a
  no-real-IP check, trailing-whitespace, large-file and private-key
  checks. `gitleaks` also runs, but only usefully at commit time: its
  hook is `gitleaks protect --staged`, which scans staged changes, and
  nothing is staged in CI, so it contributes no coverage there.
- `deploy.yml` runs on push to `main` (paths: `stacks/**`, `deploy.yml`
  itself) or manual dispatch. It calls `validate.yml` first (nothing deploys unless
  lint passes), then waits for a single **manual approval** on the
  `production` environment, after which all three nodes deploy in
  parallel. It was sequential until 2026-08-19; approving three per-job
  gates on every deploy was not worth the staged rollout on three nodes
  that are already independent. Per node: SSH in via
  `webfactory/ssh-agent` with that node's own key and a pinned
  `known_hosts`, `rsync --delete` the node's stack files — excluding
  `backup/`, `backup-booking/`, `.r2.env` and `.telegram.env`, which
  protects node-side state the repo does not own: each backup's run log
  and last-success stamp, and the two credential files later steps write
  back (a deploy overlapping the hourly staleness check once made it exit
  1 and skip that hour silently) — write that node's tunnel token and Netdata
  Cloud claim values to a remote `.env` over stdin plus separate
  `.r2.env` and `.telegram.env` credential files, then a guarded
  `docker compose pull && up -d`, guarded because a stack with no
  services defined makes plain `compose pull` error out otherwise.
- Each deploy job ends by verifying the node it just touched: Netdata
  answers on loopback, that node's `cloudflared` is running, and on vps01
  both apps answer directly on their loopback ports (127.0.0.1:8101 and
  :8102) — there is no reverse proxy. The check runs on the node over the SSH
  connection the deploy already holds, because a zone-wide Cloudflare rule
  blocks every request from outside the Philippines, so probing the public
  hostnames fails from CI while the site is perfectly healthy. The edge and tunnel
  path is covered by the status page and Netdata Cloud instead. The check
  reports and fails; it never rolls back. A revert cannot undo node-side
  state, and an automated retry loop against three nodes with nobody awake
  is worse than an alert.
- Every action is pinned to a full commit SHA, not a tag. Tags are
  mutable, and these workflows run with SSH keys and a Cloudflare API
  token in scope. Dependabot bumps the pins weekly.

## 🧯 Security

- UFW: deny-all-incoming except SSH, on every node, plus `DOCKER-USER`
  drops, because UFW does not govern container-published ports (see
  [Network model](#-network-model)).
- sshd: key-only auth (`PasswordAuthentication no`, `UsePAM no`,
  `PermitRootLogin prohibit-password`), written to
  `/etc/ssh/sshd_config.d/00-hardening.conf`. sshd keeps the *first* value
  per keyword, so the `00-` prefix means no drop-in a provider image might
  add later can outrank it — today it is the only file in that directory on
  all three nodes. Asserted against `sshd -T` afterwards, because `sshd -t`
  checks syntax, not which file won.
- Fail2Ban: aggressive sshd jail, `backend = systemd` (these images ship
  without rsyslog, so the default file-based jail backend has nothing to
  tail).
- Cloudflare Access in front of every Netdata endpoint, the OpenObserve
  UI, and `budget`. The status Worker holds a service token that opens
  the three Netdata endpoints **and nothing else**. `booking` stays open
  on purpose — it is the public booking page.
- One CI key **per node**, so a leaked Actions secret reaches one node
  rather than three, and deploys require a human approval.
- Netdata does not get the Docker socket. A `:ro` bind on a socket
  restricts nothing: anything that can reach the Docker API can start a
  container with the host filesystem mounted.
- A zone-wide Cloudflare rule blocks all non-Philippines traffic, and all
  three Netdata agents stream outbound to Netdata Cloud (see
  [Network model](#-network-model)). Both live outside this repo: the geo
  rule in the Cloudflare dashboard, the Cloud claim in a GitHub secret.

> [!NOTE]
> The CI deploy user has no sudo, but that is a smaller guarantee than it
> sounds: it is in the `docker` group and owns the compose files, so it
> can have root run whatever it writes. Any path that lets CI deploy
> containers is root-equivalent by construction. The controls that
> actually bound this are the per-node keys and the approval gate, not
> the absence of sudo.

## 💾 Backups

`budget.maybeit.work`'s data (a SQLite database plus uploaded receipt
images) is archived nightly at 03:00 Asia/Manila to a Cloudflare R2 bucket.
The app container is stopped for the few seconds the archive takes, so
SQLite checkpoints its write-ahead log and the copy is provably consistent;
a shell trap starts it again even when the backup fails, because
availability outranks the backup.

Retention lives in R2 lifecycle rules rather than in the script: `daily/`
expires after 7 days, `weekly/` after 28. Deletion is server-side, so a bug
in the script cannot erase history.

Staleness is alerted by `check-backup-age.sh`: an hourly cron job that reads
the same stamp file the backup writes and calls the Telegram API directly.
First alert at 36 hours, re-alert every 12 hours while stale, one message on
recovery. **It deliberately does not go through Netdata.** A Netdata alarm
charts the same age for the dashboard, but it silently stopped notifying
once and nothing depends on it any more.

A backup that is never restored is a guess, so the restore path is drilled by
hand: pull the newest archive, extract it into throwaway volumes, boot a
second container against them, then delete all of it. That drill is what
caught the schedule silently never firing.

`booking.maybeit.work`'s MySQL database is covered too, scheduled on the node
since 2026-08-20. It runs at 04:00, an hour after ezBookkeeping so two backups
never overlap on a 2GB node: a hot `mysqldump --single-transaction` taken
inside the MySQL container, so the booking site never goes down for it, writing
its own stamp file that the same staleness check watches, so the two backups
can go stale independently. The dump is rejected and the alert left to fire if
it carries fewer than 10 `CREATE TABLE` statements -- an empty-but-existing
database dumps as a complete, valid file, and uploading that would age out the
last real copy. It is not much data: 14 tables and 128
rows, 0.4 MB, dumping to a 6KB gzip; the volume's 203MB on disk is MySQL's
own tablespaces and binlogs, not appointments. Real customer bookings all the
same. A forced end-to-end run of the backup passed on 2026-08-19 and the
archive is in R2. A restore drill passed the same day: the archive was pulled
back down from R2 and restored into a throwaway MySQL container, and all 14
tables and every per-table row count matched production. The throwaway
container and its volume were deleted afterwards; production was never written
to.

## Resource constraints

Two vCPU, 2GB RAM, no swap by default: small enough that an unbounded
container can take the whole node down, not just itself.

- `add-swap.sh` provisions a 2GB swapfile (`vm.swappiness=10`) on every
  node, so a transient memory spike during app startup or a DB migration
  degrades instead of triggering a hard OOM-kill.
- Every app service in `stacks/` gets an explicit
  `mem_limit`/`mem_reservation`. Deliberately the classic Compose key, not
  `deploy.resources`, which is Swarm-oriented and isn't reliably honored
  by plain `docker compose up`, the command `deploy.yml` actually runs.
- Dokploy's own control plane was uncapped by default and took ~750 MiB
  of a 2 GB node on its own; it was capped, then removed outright on
  2026-08-23, taking vps00 from ~1400 MB used to ~590 MB.

## License

[AGPLv3](./LICENSE).

## Credits

Built by [nineW0nW0n](https://github.com/nineW0nW0n), with
[Claude Code](https://claude.com/claude-code) doing a lot of the typing.
