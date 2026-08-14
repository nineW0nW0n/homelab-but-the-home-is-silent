# homelab-but-the-home-is-silent

**Status: work in progress.** Nodes are provisioned, hardened, and
deployable via CI. Dokploy and Cloudflare Tunnel are live. First workload
is still being shaken out. Expect rough edges and force-pushed fixes.

GitOps infrastructure for a 3-node Debian 12 VPS homelab: [Dokploy](https://dokploy.com)
as the deployment platform, Cloudflare Tunnel for public access with zero
inbound ports, GitHub Actions as the only path to production.

## Topology

| Node  | Role      | Runs                                        |
|-------|-----------|----------------------------------------------|
| vps00 | primary   | Dokploy control plane (Swarm-managed), its own `cloudflared` |
| vps01 | secondary | Dokploy-managed app (Remote Server), its own `cloudflared`   |
| vps02 | secondary | provisioned and hardened, no workload yet    |

2 vCPU / 2GB RAM each. Real IPs are supplied as a variable, not committed —
`infra/inventory.example.yaml` is the redacted template; reference the
inventory key or hostname instead of a literal IP anywhere in this repo.

vps01/vps02 are managed as Dokploy **Remote Servers**, not Swarm workers —
each node stays independent and hosts its own apps rather than pooling
resources, which fits three boxes this small a lot better than clustering
them.

## Network model

No node has an open inbound port except SSH (22, enforced by UFW). All
public traffic — the Dokploy dashboard, deployed apps — arrives through
Cloudflare Tunnel, which is outbound-only from each node's side.

`cloudflared` runs in token mode (`tunnel run` + `TUNNEL_TOKEN`), and
public-hostname routing is configured in the Cloudflare Zero Trust
dashboard, not a file in this repo. `network_mode: host` is required on
every `cloudflared` service — bridge mode puts it in its own network
namespace, breaking `localhost:PORT` origin URLs.

**One tunnel token per node, never shared.** Cloudflare load-balances a
hostname's requests across every connector registered to its tunnel — a
route isn't pinned to a specific node. Two nodes sharing one token means
requests for either node's app can land on the wrong node and 502. Each
node that serves something gets its own tunnel and its own token.

## Repo layout

```
.yamllint, .pre-commit-config.yaml   strict lint, enforced pre-commit + CI
.github/workflows/
  validate.yml                       pre-commit over the whole repo, reusable via workflow_call
  deploy.yml                         sequential rolling deploy: vps00 -> vps01 -> vps02
infra/
  inventory.example.yaml              redacted node IP template (real IPs come from a variable)
stacks/
  vps0N/docker-compose.yml            per-node cloudflared connector + any raw compose workloads
scripts/
  bootstrap-dokploy.sh                install Dokploy control plane (vps00 only)
  provision-deploy-user.sh            create the CI deploy user, key-only, rsync installed
  install-docker.sh                   Docker Engine on secondary nodes (no Dokploy)
  harden-node.sh                      UFW, key-only sshd, Fail2Ban (aggressive sshd jail)
  add-swap.sh                         swap file (these nodes ship with none)
  cap-dokploy-resources.sh            memory-cap Dokploy's own control plane
```

All scripts are idempotent, POSIX `sh`, shellcheck-clean, and safe to
re-run — most matter again if a node ever gets rebuilt from scratch.

## CI/CD

- `validate.yml` runs on every PR and push to `main`: pre-commit over all
  files — `yamllint --strict`, `actionlint`, `gitleaks`, trailing-whitespace,
  large-file and private-key checks.
- `deploy.yml` runs on push to `main` (paths: `infra/**`, `stacks/**`) or
  manual dispatch. It calls `validate.yml` first — nothing deploys unless
  lint passes — then runs three sequential jobs, never in parallel, so a
  bad deploy can't take all three nodes down at once. Per node: SSH in via
  `webfactory/ssh-agent` with a pinned `known_hosts`, `rsync --delete` the
  node's stack files, supply that node's tunnel token as a variable, then
  a guarded `docker compose pull && up -d` — guarded because a stack with
  no services defined makes plain `compose pull` error out otherwise.

## Security

- UFW: deny-all-incoming except SSH, on every node.
- sshd: key-only auth (`PasswordAuthentication no`, `UsePAM no`).
- Fail2Ban: aggressive sshd jail, `backend = systemd` (these images ship
  without rsyslog, so the default file-based jail backend has nothing to
  tail).
- The CI deploy user has no sudo and authenticates by key only —
  password login is fully disabled for it, no exceptions.
- Dokploy manages the other nodes over its own separate, dedicated SSH
  credential, scoped to that purpose only.

## Resource constraints

Two vCPU, 2GB RAM, no swap by default — small enough that an unbounded
container can take the whole node down, not just itself.

- `add-swap.sh` provisions a 2GB swapfile (`vm.swappiness=10`) on every
  node, so a transient memory spike during app startup or a DB migration
  degrades instead of triggering a hard OOM-kill.
- Every app service — in this repo's `stacks/` or deployed through
  Dokploy — gets an explicit `mem_limit`/`mem_reservation`. Deliberately
  the classic Compose key, not `deploy.resources`, which is Swarm-oriented
  and isn't reliably honored by plain `docker compose up` — the command
  both `deploy.yml` and Dokploy actually run.
- Dokploy's own control plane was uncapped by default, consuming a
  disproportionate share of a small node's memory on its own before
  `cap-dokploy-resources.sh` bounded it.

## License

[AGPLv3](./LICENSE).

## Credits

Built by [nineW0nW0n](https://github.com/nineW0nW0n), with
[Claude Code](https://claude.com/claude-code) doing a lot of the typing.
