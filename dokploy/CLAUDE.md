Parent: ../.claude/CLAUDE.md

# dokploy/: compose apps Dokploy pulls from this repo

One directory per workload. Dokploy is configured (Compose application,
Provider: GitHub, this repo, Compose Path
`dokploy/<workload>/docker-compose.yml`) to clone and deploy these
itself. `.github/workflows/deploy.yml` never touches this tree: it
rsyncs `stacks/` only. Two different deploy paths, one repo.

Split rule: node-level services (cloudflared, Netdata) live in
`stacks/<node>/docker-compose.yml`. User-facing apps that want Dokploy's
UI (logs, redeploy button, env editor, backups) live here.

## Local rails

- **No `ports:`.** Publishing a port on a node bypasses UFW (root rail
  1). Attach to the external `dokploy-network` and let Dokploy's Traefik
  reach the container port through Traefik labels.
- **Traefik `entrypoints: web` only.** TLS terminates at Cloudflare;
  `cloudflared` hits `http://localhost:80`. A `websecure` router on a
  node with no certificate just fails.
- **Secrets live in Dokploy's environment tab**, referenced as
  `${VAR:?...}` in the compose file. Commit a `.env.example` with
  redacted placeholders, never a `.env` (root rail 11).
- **`mem_limit`/`mem_reservation` on every service** (root rail 4). 2GB
  nodes, and Dokploy's own control plane already takes a bite.
- **Pin image tags exactly.** No `latest`, no `1.6`.

## Workloads

- `ezbookkeeping/` → vps01, `budget.maybeit.work`, SQLite, 256m cap.
  Registration disabled by default; flip `EBK_USER_ENABLE_REGISTER=true`
  in Dokploy's env tab only long enough to create the first account.
  Routed through vps01's existing tunnel
  (`CLOUDFLARE_TUNNEL_TOKEN_VPS01_BOOKING`), which already points at
  `http://localhost:80`; the only Cloudflare-side step is adding the
  Public Hostname.

## Failure log

- Cloudflare caches ezBookkeeping's `/server_settings.js` (origin sends
  `cache-control: max-age=14400`), so after flipping an env-driven
  feature flag the login page can keep showing the old state for up to
  4 hours. Do not conclude the env change failed: check the container
  (`env | grep EBK_`) and `curl` the origin file, then purge by hostname
  in Caching -> Configuration -> Custom Purge. Verified 2026-08-18 while
  turning `EBK_USER_ENABLE_REGISTER` off: container read `false` and
  `_['r']=0` while the browser still offered "Create an account".
