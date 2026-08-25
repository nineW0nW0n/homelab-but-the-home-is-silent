Parent: ../CLAUDE.md

# stacks/vps00/: metrics node + wiki-kit test deployment

Baseline services (cloudflared, Netdata, Vector) are documented in
`stacks/CLAUDE.md`; this file exists for the wiki-kit workload added
2026-08-26.

## wiki-kit (TEST — likely torn down after verification)

- Upstream: `nineW0nW0n/wiki-kit`, pinned image
  `ghcr.io/ninew0nw0n/wiki-kit:0.1.0`. Three services: `wiki-builder`
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
- `/` answers 404 until the first builder cycle finishes; liveness is
  `curl http://127.0.0.1:8001/status` (builder-written `status.json`) or
  `https://wiki.maybeit.work/work/` in a browser. CI's verify step
  samples the three containers' restart counters but has **no HTTP probe**
  for wiki: the probe helper requires 200 on `/`, which is only true
  after content exists.

## Teardown checklist (if the test is discarded)

Compose services + volumes (`wiki-*`), `bundles.yml`, `Caddyfile`, the
`WIKI_GIT_TOKEN` secret and its deploy.yml wiring, the `wiki.maybeit.work`
DNS CNAME, tunnel ingress entry and Access app `wiki`, the `brain-work`
repo, and this file's wiki sections + the route/listener lines in
`stacks/CLAUDE.md`.

## Failure log
