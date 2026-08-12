# Project Context

GitOps infrastructure repo for a 3-node Debian 12 VPS cluster, deployed via
Dokploy and exposed through Cloudflare Tunnel. GitHub Actions handles
validation and rolling deployment. No inbound ports are opened on any node —
all public traffic arrives through the tunnel.

## Topology

| Node  | Hostname             | Role      |
|-------|----------------------|-----------|
| vps00 | vps00.maybeit.work   | primary   |
| vps01 | vps01.maybeit.work   | secondary |
| vps02 | vps02.maybeit.work   | secondary |

Real IPs live only in `infra/inventory.yaml` (gitignored) and in the
`VPS00_HOST` / `VPS01_HOST` / `VPS02_HOST` GitHub secrets. Never hardcode an
IP in a tracked file — reference the hostname or the inventory key instead.
`infra/inventory.example.yaml` is the tracked, redacted template.

Domain: `maybeit.work`, DNS on Cloudflare.

Tunnel runs in **token mode** (`cloudflared tunnel run` + `TUNNEL_TOKEN` env,
see `stacks/*/docker-compose.yml`) — ingress/public-hostname routing is
owned by the Cloudflare Zero Trust dashboard, not a local config file. Add
or change routes there (Zero Trust → Networks → Tunnels → *tunnel* → Public
Hostnames), not in this repo. Current routes:
- `dokploy.maybeit.work` → `http://localhost:3000` on vps00, tunnel token
  `CLOUDFLARE_TUNNEL_TOKEN`.
- `booking.maybeit.work` → `http://localhost:80` on vps01 (Dokploy's own
  Traefik, which forwards to the calcom app container on :3000 based on
  the Domain set in Dokploy's UI), tunnel token
  `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING` — its own dedicated tunnel, see
  below.

`cloudflared` must run with `network_mode: host` — bridge mode puts it in
its own network namespace, so `http://localhost:PORT` origin URLs resolve
to the container, not the VPS (caused 502s).

Direct `<node-ip>:3000` dashboard access only worked before hardening — UFW
now denies all inbound except 22, so `dokploy.maybeit.work` via the tunnel
is the only way in. That's intentional, matches "no inbound ports opened,
ever."

**One tunnel token = one interchangeable connector pool.** Cloudflare
load-balances a hostname's requests across *every* connector registered to
its tunnel — a route isn't pinned to a specific node. So vps00 and vps01
each need their own tunnel + token; sharing one across nodes with
different origins causes non-deterministic 502s (hit this once already,
see git history). vps02 still runs no `cloudflared` — no workload there
yet. When it gets one: new tunnel, new token, same pattern as vps01.

## Repo Layout

```
.yamllint                       # strict yamllint rules (all *.yaml/*.yml)
.pre-commit-config.yaml         # trailing-whitespace, yamllint, gitleaks, actionlint
.env.example                    # local tooling env template (no real values)
.gitignore                      # blocks .env, keys, infra/inventory.yaml, tfstate
.github/workflows/
  validate.yml                  # pre-commit --all-files, reusable via workflow_call
  deploy.yml                    # sequential rolling deploy vps00 -> vps01 -> vps02
infra/
  inventory.example.yaml        # tracked, redacted IP template
  inventory.yaml                # gitignored, real IPs
  common/
    base.yaml                   # OS, resources, firewall, dokploy agent
  nodes/
    vps00/node.yaml
    vps01/node.yaml
    vps02/node.yaml
stacks/
  vps00/docker-compose.yml        # cloudflared connector (+ future workloads)
  vps01/docker-compose.yml
  vps02/docker-compose.yml
scripts/
  bootstrap-dokploy.sh             # one-time: installs Dokploy control plane on vps00
  provision-deploy-user.sh         # one-time per node: deploy user + rsync
  install-docker.sh                # one-time per node: Docker Engine only (no Dokploy)
  harden-node.sh                   # one-time per node: UFW, sshd key-only, Fail2Ban
  add-swap.sh                      # one-time per node: swap file (2GB nodes have none by default)
```

## Conventions

- **Secrets**: never hardcoded. Local dev uses `.env` (gitignored, copied from
  `.env.example`). CI uses GitHub Actions Secrets (sensitive: tokens, IPs,
  SSH key) and Variables (non-sensitive: SSH user, SSH port).
- **YAML**: every file starts with `---`, 2-space indent, 120-char line max,
  no duplicate keys, strict yamllint enforced in pre-commit and CI.
- **Commits**: atomic, conventional commit format (`feat:`, `fix:`, `chore:`,
  `docs:`).
- **Shell**: POSIX-compatible, no bashisms unless the script is explicitly
  `#!/bin/bash`.
- **Node configs**: `infra/nodes/<name>/node.yaml` extends
  `infra/common/base.yaml`. Never duplicate a common setting per-node —
  override only what differs.
- **No code fragments in commits** — files are committed complete.

## CI/CD Flow

1. `validate.yml` runs on every PR and push to `main`: pre-commit over all
   files (yamllint --strict, actionlint, gitleaks, trailing-whitespace,
   large-file/private-key checks).
2. `deploy.yml` runs on push to `main` (paths: `infra/**`, `stacks/**`) or
   manual dispatch. Calls `validate.yml` first, then deploys sequentially —
   vps00, then vps01, then vps02 — via SSH (`webfactory/ssh-agent` +
   pinned `known_hosts`), never all three at once. Per node: `mkdir -p` the
   remote stack dir, `rsync --delete` the stack files there, write that
   node's tunnel token into a remote `.env` (piped over SSH stdin, never
   as a command-line arg, never committed), then `docker compose pull &&
   up -d`. Each node's "Write remote .env" step uses that node's own
   tunnel token secret — see below, don't reuse vps00's on another node.
3. `stacks/<node>/docker-compose.yml` runs that node's `cloudflared`
   connector (own tunnel token) plus any node-specific workload compose
   services not deployed through Dokploy directly.

## Required GitHub Secrets / Variables

Secrets: `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `VPS00_HOST`, `VPS01_HOST`,
`VPS02_HOST`, `DOKPLOY_API_TOKEN`, `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_TUNNEL_TOKEN` (vps00), `CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`
(vps01), `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ACCOUNT_ID`.

Variables (non-sensitive, optional, default in workflow): `VPS00_SSH_USER`,
`VPS00_SSH_PORT` (and `01`/`02` equivalents).

## Dokploy Bootstrap

Dokploy itself is NOT installed by `deploy.yml` — that workflow only manages
`stacks/*/docker-compose.yml`. Installing Dokploy is a separate, one-time,
manual step: run `scripts/bootstrap-dokploy.sh` (needs `VPS00_HOST` in
`.env` or the environment). It installs the Dokploy control plane on vps00
only. vps01/vps02 join later through the Dokploy dashboard (Settings >
Servers > Add Server) — a different flow, not this script.

## Node Hardening

`scripts/harden-node.sh <host>` (root SSH): UFW (deny-all-incoming except
22), sshd (`PasswordAuthentication no`, `UsePAM no`), Fail2Ban (aggressive
sshd jail). Run once per node — already applied to all 3.

Gotcha: Fail2Ban's default sshd jail expects a log *file*
(`/var/log/auth.log`), which doesn't exist on these minimal Debian 12
images — no rsyslog installed, sshd logs go straight to journald. Jail
config must set `backend = systemd` or the service exits immediately with
"Have not found any log file for sshd jail."

Gotcha (bigger one): `UsePAM no` makes sshd do its own `/etc/shadow` check
instead of delegating to PAM — and that check rejects pubkey auth outright
on a **locked** account ("account is locked"), even with a perfectly valid
key. `deploy` is created passwordless, which `useradd` already marks
locked by default; `provision-deploy-user.sh` used to reinforce that with
`passwd -l`, which worked fine under the pre-hardening default `UsePAM
yes` and broke the instant `UsePAM no` landed — every CI deploy started
failing with `Permission denied (publickey)`. Fix: `passwd -d` (empty
password field) instead of `passwd -l` (locked marker) — sshd's shadow
check only vetoes the locked marker specifically, not an empty field, and
`PasswordAuthentication no` already fully blocks password login regardless
of which one you use. If you ever provision a node before hardening it,
run `provision-deploy-user.sh` (or re-run it) *after* `harden-node.sh`, or
just make sure it's using the current `passwd -d` version.

Dokploy's Remote Servers connects as **root** (not `deploy` — that user has
no sudo, and Dokploy requires root or passwordless-sudo). This is a
separate SSH keypair Dokploy generates itself, added to each node's
`root` `authorized_keys` manually (not via a script — one-time, done
during dashboard setup). Using **Remote Servers**, not Swarm/multi-server
clustering — each of the 3 nodes stays independent, hosts its own apps,
given the 2vCPU/2GB-per-node resource ceiling.

## Memory (2vCPU/2GB nodes)

Nodes have no swap by default — `scripts/add-swap.sh <host>` adds a 2GB
swapfile (`vm.swappiness=10`, prefers RAM, spills under real pressure
only). Already applied to all 3 nodes. Without it, a transient memory
spike (app startup, migrations) is a hard OOM-kill instead of a slowdown —
this is what broke Calcom's first deploy on vps01 ("can't complete build
process" was actually an OOM kill under a too-tight `mem_limit`, not a
real build). Re-run this script on any node rebuilt from scratch.

Always set `mem_limit`/`mem_reservation` on app services in `stacks/` or
Dokploy-deployed compose files — an unbounded container can starve
Traefik/cloudflared/sshd of RAM and take the whole node down, not just
itself. Use `mem_limit` (classic Compose key), not `deploy.resources` —
the latter is swarm-oriented and isn't reliably honored by plain `docker
compose up`, which is what both `deploy.yml` and Dokploy actually run.

## When Extending This Repo

- New per-node setting → edit `infra/nodes/<name>/node.yaml`, not `base.yaml`,
  unless it applies to all 3 nodes.
- New secret → add to `.env.example` (empty value) and to this file's
  required-secrets list, add to GitHub repo secrets, never commit the value.
- New YAML file → must pass `yamllint -c .yamllint <file>` before commit;
  pre-commit enforces this automatically.
- New workflow → add `actionlint` will catch shell-injection risks from
  unquoted `${{ }}` expressions in `run:` blocks; keep using intermediate
  `env:` vars for untrusted input (PR titles, branch names) rather than
  interpolating directly into shell.
