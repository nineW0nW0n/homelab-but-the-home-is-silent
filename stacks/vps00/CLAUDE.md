Parent: ../CLAUDE.md

# stacks/vps00/: metrics node + wiki-kit

Baseline services (cloudflared, Netdata, Vector) are documented in
`stacks/CLAUDE.md`; this file exists for the wiki-kit workload added
2026-08-26.

## wiki-kit (kept)

- Deployed 2026-08-26 as a test, **kept 2026-08-27**. It is a normal
  workload now, not a trial: it deploys, is probed and is reasoned about
  like every other stack here.
- `wiki-builder`'s `mem_limit: 768m` is a hedge, not a measurement — it
  was set before the service had ever run a Quartz build. Measure real
  usage (`docker stats --no-stream wiki-builder`) once it has a week of
  cycles behind it and replace the number. Every other cap in this file
  came from observed usage + 50%; this one did not.
- Upstream: `nineW0nW0n/wiki-kit`, pinned image
  `ghcr.io/ninew0nw0n/wiki-kit:0.1.2`. Three services: `wiki-builder`
  (clones + lints + Quartz-builds bundles every `interval_seconds`),
  `wiki-web` (Caddy, the only published port: `127.0.0.1:8001` → its
  `:8090` tunnel listener), `wiki-mcp` (read-only MCP behind `/mcp`).
- Content: private repo `nineW0nW0n/brain-work`, listed in `bundles.yml`
  here (committed — no secrets in it; the read-only fine-grained PAT is
  `WIKI_GIT_TOKEN` in GitHub secrets → node `.env`).
- Upstream's compose also ships a `cloudflared` (skipped: vps00's
  host-mode one dials `localhost:8001`, rails 2/3) and a self-hosted
  `runner` (skipped: mounts `docker.sock`, banned on these nodes).
- `Caddyfile` is a copy of upstream's with one change: MCP upstream
  `mcp:8081` → `wiki-mcp:8081` (this stack's service name). Re-copy and
  re-apply that change when bumping the image.
- Ingress: `wiki.maybeit.work` on vps00's tunnel, Access app `wiki`,
  owner-only. The `:8090` listener trusts `Cf-Access-*` headers;
  publishing it on loopback means a node-local process could forge them
  to MCP — accepted, same trust as every other loopback origin here.
- Since 0.1.2 the builder writes a root index, so `/` answers 200 once
  the first cycle has run and CI's verify step probes `wiki:8001` on `/`
  (plus the three containers' restart counters). The `wiki-site` volume
  persists across deploys, so the probe only races the builder on a
  brand-new node/volume — if that first-ever deploy FAILs on the wiki
  probe, wait a cycle and re-run verify before diagnosing. Deeper check
  by hand: `curl http://127.0.0.1:8001/status` (builder-written
  `status.json` with per-bundle sha/lint/build).

## Teardown checklist (not scheduled; kept here for whenever it is)

Compose services + volumes (`wiki-*`), `bundles.yml`, `Caddyfile`, the
`WIKI_GIT_TOKEN` secret and its deploy.yml wiring, the `wiki.maybeit.work`
DNS CNAME, tunnel ingress entry and Access app `wiki`, the `brain-work`
repo, and this file's wiki sections + the route/listener lines in
`stacks/CLAUDE.md`.

## Failure log
