Parent: ../CLAUDE.md

# stacks/vps00/: metrics node + wiki-kit + google-workspace-mcp

Baseline services (cloudflared, Vector, Beszel agent) are documented in
`stacks/CLAUDE.md`; this file exists for the workloads added
since: wiki-kit (2026-08-26) and google-workspace-mcp (2026-08-29).

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

## google-workspace-mcp

- Upstream `taylorwilsdon/google_workspace_mcp`, pinned image
  `ghcr.io/taylorwilsdon/google_workspace_mcp:1.25.2` (published by the
  repo's own `docker-publish.yml`; the GHCR tag has no `v` prefix even
  though the git tag does — `v1.25.2` 404s on the registry).
- One service, `gws-mcp`, `127.0.0.1:8051` → container `:8000`. Runs
  `--transport streamable-http --single-user --tool-tier complete`, so
  the full Gmail / Calendar / Drive / Docs / Sheets / Slides / Forms /
  Tasks / Chat / Contacts / Apps Script tool set is loaded and every
  tool call defaults to `USER_GOOGLE_EMAIL`.
- **Three Google accounts are granted, and `--single-user` does not stop
  that.** `abcollado.28@gmail.com` (the `USER_GOOGLE_EMAIL` default),
  `excollado@gmail.com` and `feeder.kantooter@gmail.com` (both added
  2026-08-29) each hold a refresh token in the `gws-mcp-creds` volume,
  one file per address. The External app's OAuth user cap is 100, so
  headroom is not the constraint. Pass
  `user_google_email` explicitly to reach either of the others; omit it and
  you get the default. No compose change and no redeploy were needed --
  the grant is browser-side state, not configuration. Read the compose
  comment on `USER_GOOGLE_EMAIL` for the two mechanisms this rests on.
  All three scope sets are identical: scopes come from `--tool-tier`,
  which is server-wide, so every account is as privileged as the first.
  A first-ever consent for a new address shows the full checkbox list --
  hit **Select all**, since a partial grant silently breaks whichever
  tools lost their scope.
- **`WORKSPACE_MCP_HOST: 0.0.0.0` is load-bearing.** Verified in
  `main.py@1.25.2`, `resolve_bind_host_for_transport`: legacy
  streamable-http binds `127.0.0.1` *inside the container* when this is
  unset, and `docker-proxy` dials the container's IP, not its loopback —
  so the published port would accept and then answer nothing. It does not
  widen rail 1: the host side of the publish is still `127.0.0.1`.
- **No MCP-level auth in this mode.** The server itself checks nothing;
  the locks are the loopback publish and the Cloudflare Access app on
  `gws.maybeit.work`. Same trust as wiki-mcp's `:8090` listener. Turning
  on the server's own OAuth 2.1 (`MCP_ENABLE_OAUTH21`) is the upgrade
  path if a second client or a non-browser consumer ever needs it.
- Two auth flows, don't confuse them. **Google's** OAuth (which Google
  account the tools act as) runs once in a browser: a tool returns a
  consent URL, Google redirects to `https://gws.maybeit.work/oauth2callback`,
  and the refresh token lands in the `gws-mcp-creds` volume. **Access's**
  auth (who may reach the endpoint at all) is per-request, and Claude
  Code presents `CF-Access-Client-Id`/`CF-Access-Client-Secret` headers.
  `GOOGLE_OAUTH_REDIRECT_URI` must match the Authorized redirect URI on
  the Google OAuth client character for character.
- Google side, done 2026-08-29 under `abcollado.28@gmail.com`: Cloud
  project **`gws-mcp-507002`**, consent screen app `gws-mcp`, OAuth client
  `gws-mcp vps00`, and 11 enabled APIs (Gmail, Calendar, Drive, Docs,
  Sheets, Slides, Forms, Tasks, Chat, People, Apps Script). Custom Search
  is deliberately NOT enabled: the `gsearch` tools need a separate
  Programmable Search key and engine ID, so enabling the API alone would
  buy nothing.
- **Publishing status is "In production", and that is load-bearing.** An
  External app left in "Testing" has its Google refresh token expired
  after 7 days, which would mean re-running the browser consent flow
  every week. Production removes that. The app is unverified, so first
  consent shows Google's "unverified app" screen -- expected, click
  through it. Do not flip it back to Testing to silence anything.
- Production status requires a reachable home page, privacy policy and
  terms of service. They are served by the **status Worker on the apex**
  (`/privacy`, `/terms` -- see `worker/status/CLAUDE.md`), not from
  `gws.maybeit.work`, because the zone-wide "Block non-local traffic"
  rule exempts only the apex and Google could not otherwise fetch them.
  Changing what this MCP does means changing those pages: they claim
  single-user use and that Google data stays on this node.
- Cloudflare side, created and read back from the API 2026-08-29: the
  `gws` CNAME (proxied), the tunnel ingress entry, and Access app
  `gws-mcp` (session 24h) with its two policies. The service-token policy
  reuses the existing `claude-code` token that `wiki` already uses, so
  Claude Code needs no new credential for this endpoint.
- Secrets: `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`,
  `USER_GOOGLE_EMAIL` in GitHub secrets → vps00 `.env` (deploy.yml).
  All three are in the reject-mangle list, so a deploy fails loudly if
  one is unset rather than starting a container that cannot authenticate.
- `mem_limit` is `512m`, **measured twice** (issue #88). 2026-08-29
  minutes after the first deploy: `memory.peak` 347 MiB, before any grant
  or tool call existed. 2026-08-29 again, 6.4h later, over a window
  carrying the first real inbox reorganisation (125 `search_gmail_messages`,
  121 `manage_gmail_label`, 61 `batch_modify_gmail_message_labels`):
  `memory.peak` **354 MiB**, steady state 235 MiB, no restarts, no OOM.
  **Real traffic moved the peak 7 MiB.** The startup import of the
  complete tool tier is what this process costs; per-call payloads are
  noise beside it. 512m is kept rather than recomputed — peak + 50% is
  531m, and the 158 MiB of headroom is worth more than the 19m.
  One tool has never run: `get_gmail_threads_content_batch` fetches 25
  thread bodies at once. Read the peak again if that becomes routine.
- CI verify probes `gws-mcp:8051` on `/`, which the image serves as its
  health JSON (`core/server.py` registers `/` and `/health` on the same
  handler). That proves the process is up and bound; it proves nothing
  about the Google grant — a container with no valid refresh token still
  answers 200 there. Check the grant by calling a tool.

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

google-workspace-mcp: the `gws-mcp` service and `gws-mcp-creds` volume,
the three `GOOGLE_OAUTH_*`/`USER_GOOGLE_EMAIL` secrets and their
deploy.yml wiring (reject list, `.env` writer, `verify_args`), port 8051
in `port-sweep.yml` and root's manual sweep list, the `gws.maybeit.work`
CNAME, tunnel ingress entry and Access app `gws-mcp` (but NOT the
`claude-code` service token -- `wiki` uses it too), the Google Cloud
OAuth client, and this file's section plus the
route/listener lines in `stacks/CLAUDE.md`.

wiki-kit: compose services + volumes (`wiki-*`), `bundles.yml`, `Caddyfile`, the
`WIKI_GIT_TOKEN` secret and its deploy.yml wiring, the `wiki.maybeit.work`
DNS CNAME, tunnel ingress entry and Access app `wiki`, the `brain-work`
repo, and this file's wiki sections + the route/listener lines in
`stacks/CLAUDE.md`.

## Failure log

- **`--single-user` does not mean one account; `USER_GOOGLE_EMAIL` means
  one default.** This file and the compose comment both said every tool
  call acts as `USER_GOOGLE_EMAIL` and no second grant could exist.
  Wrong on both counts, found 2026-08-29 while adding a second address:
  the flag only skips FastMCP session mapping, and an explicit
  `user_google_email` argument is passed straight through to that
  address's own credential file. Adding an account needs no redeploy.
  Do not infer an upstream flag's blast radius from its name -- read the
  code that reads the flag.
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
