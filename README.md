# homelab-but-the-home-is-silent

**Status: work in progress.** Nodes are provisioned, Dokploy and Cloudflare
Tunnel are wired up, the first workload is still being shaken out. Expect
rough edges and force-pushed fixes.

GitOps infrastructure for a 3-node Debian 12 VPS homelab: [Dokploy](https://dokploy.com)
as the deployment platform, Cloudflare Tunnel for public access with zero
inbound ports, GitHub Actions as the only path to production.

## Layout

```
.yamllint, .pre-commit-config.yaml   strict lint, enforced pre-commit + CI
.github/workflows/
  validate.yml                       pre-commit over the whole repo
  deploy.yml                         sequential rolling deploy: vps00 -> vps01 -> vps02
infra/
  common/base.yaml                   shared node config (OS, firewall, resources)
  nodes/vps0N/node.yaml              per-node role and overrides
  inventory.example.yaml             redacted node IP template (real one is gitignored)
stacks/
  vps0N/docker-compose.yml           per-node Cloudflare Tunnel connector + raw compose workloads
scripts/
  bootstrap-dokploy.sh               install Dokploy control plane (vps00 only)
  provision-deploy-user.sh           create the CI deploy user
  install-docker.sh                  Docker Engine on secondary nodes
  harden-node.sh                     UFW, key-only SSH, Fail2Ban
  add-swap.sh                        swap file (these nodes ship with none)
  cap-dokploy-resources.sh           memory-cap Dokploy's own control plane
```

## How it works

- Every YAML file is strict-linted (`yamllint --strict`), enforced locally
  via pre-commit and again in CI.
- `deploy.yml` never touches a node until `validate.yml` passes.
- Secrets live in GitHub Actions secrets/variables and gitignored local
  files, never in tracked YAML.
- Each node's Cloudflare Tunnel is independent — one token per node's set
  of origins, not shared. Details in `.claude/CLAUDE.md`.

## License

[AGPLv3](./LICENSE).

## Credits

Built by [nineW0nW0n](https://github.com/nineW0nW0n), with
[Claude Code](https://claude.com/claude-code) doing a lot of the typing.
