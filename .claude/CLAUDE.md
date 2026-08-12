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
Hostnames), not in this repo. Current routes: `dokploy.maybeit.work` →
`http://localhost:3000` on vps00.

`cloudflared` must run with `network_mode: host` — bridge mode puts it in
its own network namespace, so `http://localhost:PORT` origin URLs resolve
to the container, not the VPS (caused 502s).

**One tunnel token = one set of origins.** Only vps00 runs `cloudflared`
right now — it's the only node with a workload behind the tunnel's routes.
Do NOT reuse `CLOUDFLARE_TUNNEL_TOKEN` on vps01/vps02 until they serve the
*same* origins vps00 does: Cloudflare load-balances a hostname's requests
across every connector registered to that tunnel, so a node with nothing
listening on the origin port causes ~2/3 of requests to 502. A node with a
genuinely different workload/hostname needs its own tunnel + token, not
the shared one.

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
   remote stack dir, `rsync --delete` the stack files there, write
   `CLOUDFLARE_TUNNEL_TOKEN` into a remote `.env` (piped over SSH stdin,
   never as a command-line arg, never committed), then
   `docker compose pull && up -d`.
3. `stacks/<node>/docker-compose.yml` currently runs only the `cloudflared`
   connector. Add node workload services to that same file — one compose
   file per node, kept in sync with the node's `infra/nodes/<node>/node.yaml`
   `workloads:` list.

## Required GitHub Secrets / Variables

Secrets: `SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `VPS00_HOST`, `VPS01_HOST`,
`VPS02_HOST`, `DOKPLOY_API_TOKEN`, `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ACCOUNT_ID`.

Variables (non-sensitive, optional, default in workflow): `VPS00_SSH_USER`,
`VPS00_SSH_PORT` (and `01`/`02` equivalents).

## Dokploy Bootstrap

Dokploy itself is NOT installed by `deploy.yml` — that workflow only manages
`stacks/*/docker-compose.yml`. Installing Dokploy is a separate, one-time,
manual step: run `scripts/bootstrap-dokploy.sh` (needs `VPS00_HOST` in
`.env` or the environment). It installs the Dokploy control plane on vps00
only. vps01/vps02 join later through the Dokploy dashboard (Settings >
Servers > Add Server) — a different flow, not this script.

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
