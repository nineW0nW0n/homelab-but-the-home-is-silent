Parent: ../CLAUDE.md

# stacks/vps00/: metrics node + wiki-kit

Baseline services (cloudflared, Netdata, Vector) are documented in
`stacks/CLAUDE.md`; this file exists for the wiki-kit workload added
2026-08-26.

## wiki-kit (kept)

- Deployed 2026-08-26 as a test, **kept 2026-08-27**. It is a normal
  workload now, not a trial: it deploys, is probed and is reasoned about
  like every other stack here.
- `wiki-builder`'s `mem_limit` is `512m`, measured 2026-08-29 (issue
  #82): cgroup `memory.peak` over a window containing a real Quartz build
  was 344 MiB, idle poll ~19 MiB. 512m is peak + ~50%, so every cap in
  this file now comes from observed usage + 50%. It replaced a `768m`
  hedge set before the service had ever built. Re-measure once
  `brain-work` has grown a lot, or if `bundles.yml` gains a second
  bundle — build peak scales with content volume.
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

## vps00 is the MCP node

New MCP servers land here, not on vps01 or vps02. `wiki-mcp` is already
here and it is the only MCP in the repo, so this keeps the MCP surface on
one node instead of scattering it.

Why this node and not the others: vps01 is the tightest (two apps plus
MySQL), and vps02 is the log sink, whose OpenObserve footprint grows with
ingest volume and retention — a neighbour whose memory moves on its own.
vps00 runs no user-facing app, and its one heavy service bursts only when
`brain-work` changes.

Check the committed total before adding one. Caps here sum to well under
the 2 GB the node has, but there is no swap, so the ceiling is real:
`grep -E 'mem_limit' docker-compose.yml`.

## Teardown checklist (not scheduled; kept here for whenever it is)

Compose services + volumes (`wiki-*`), `bundles.yml`, `Caddyfile`, the
`WIKI_GIT_TOKEN` secret and its deploy.yml wiring, the `wiki.maybeit.work`
DNS CNAME, tunnel ingress entry and Access app `wiki`, the `brain-work`
repo, and this file's wiki sections + the route/listener lines in
`stacks/CLAUDE.md`.

## Failure log

- **A bundle that fails wiki-kit's lint freezes the served site, silently.**
  `wiki-builder` runs lint before the Quartz build and skips the build on any
  ERROR, so `/` and every existing page keep answering 200 with stale content
  while new pages never appear. Found 2026-08-28: the 2026-08-27 ingest landed
  two `recommended field \`tags\` is absent` errors, and the site had been
  stale for a day. `brain-work`'s own `lint.yml` did not catch it -- it runs
  `on: pull_request` on a `[self-hosted, wiki]` runner that does not exist
  here, so it never ran. Judge the wiki by
  `curl http://127.0.0.1:8001/status` (`lint_exit` and `build` per bundle),
  never by an HTTP 200 on `/`; CI's verify step probes `/` and cannot see
  this.
