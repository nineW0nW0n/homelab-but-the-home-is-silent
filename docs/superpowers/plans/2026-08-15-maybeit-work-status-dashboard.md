# maybeit.work Status Dashboard Implementation Plan

> **Commit SHAs in this document are dangling (2026-08-16).** History was
> rewritten with `git filter-repo` to remove real node IPs and
> force-pushed, so every SHA recorded before that rewrite no longer
> resolves. Search by commit *message* instead. The work itself is
> unaffected; only the identifiers moved.


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a status page at `maybeit.work` showing red/green health and
CPU/mem/disk % for vps00, vps01, vps02, and Dokploy — backed by tuned
Netdata agents, a Cloudflare Worker that polls and renders, and Netdata's
own Telegram alerting.

**Architecture:** Netdata runs as a Docker container (`network_mode:
host`, same pattern as this repo's `cloudflared` services) in each
node's `stacks/<node>/docker-compose.yml`, deployed by the existing
`deploy.yml` GitOps pipeline — not an ad-hoc SSH script (revised
mid-execution: the only SSH access available, `deploy`, has no sudo,
rail 6; it's already in the `docker` group). Reachable only through a
new Access-gated Cloudflare Tunnel route. A Cloudflare Worker's Cron
Trigger polls those routes + a Dokploy reachability check every 5
minutes, writes one JSON snapshot to Workers KV; page views render
straight from that snapshot. Alerts fire from Netdata's own health
engine to Telegram, independent of the Worker.

**Tech Stack:** Docker Compose + GitHub Actions (Netdata delivery,
matches `stacks/`/`deploy.yml` conventions), Cloudflare Workers (plain
JS, no framework), Workers KV, `wrangler`, `node:test` for unit tests.

**Spec:** `docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`

## Global Constraints

- One tunnel token per node, never shared (rail 2) — vps00 and vps01
  reuse their *existing* `cloudflared` token/connector for the new
  metrics Public Hostname. vps02 has **no** `cloudflared` yet
  (`services: {}`) — Netdata is its first workload, so it needs a
  brand-new dedicated tunnel + `CLOUDFLARE_TUNNEL_TOKEN_VPS02_*` secret,
  never vps00's shared token (see `stacks/vps02/docker-compose.yml`'s
  own comment, written for exactly this moment).
- Real IPs never committed (rail 5) — nothing in this revised plan
  takes a host argument directly; deploy targets come from the existing
  `VPS0N_HOST` GitHub secrets, same as every other `deploy.yml` job.
- CI deploy user stays key-only, no sudo (rail 6) — confirmed live
  during execution: root SSH is refused, `deploy` connects fine and is
  already in the `docker` group. This is *why* Netdata is a Docker
  service through `deploy.yml` rather than a native install over SSH.
- Explicit `mem_limit`/`mem_reservation` on every app service (rail 4)
  — the new `netdata` service in each `docker-compose.yml` is no
  exception.
- `validate.yml` passes before any deploy runs (rail 8) — the new
  `deploy-worker.yml` calls it via `workflow_call`, same pattern as
  `deploy.yml`.
- Biome lints all JS/TS/JSON (rail 9) — this plan adds the repo's first
  JS files, so `biome.json` is created as part of Task 4, per
  `tooling-setup`'s instruction to set it up on first real contact.
- Never print secret material in full (rail 11) — Access service-token
  credentials, the Telegram bot token, and Worker secrets are referenced
  by name only, never pasted as literal values anywhere in this plan,
  a commit, or chat output.
- Retention is **1 week**, not 1 month (per the approved spec, revised
  down from the design's initial draft).
- Alerts go to **Telegram only** — no mail server exists in this repo
  and none is being added.

---

### Task 1: Netdata as a Docker service (vps00, vps01, vps02) + vps02's first Cloudflare Tunnel

Revised mid-execution (see the spec's "Implementation update" note):
native root-SSH install isn't reachable — `deploy` (the only key that
authenticates) has no sudo, but is already in the `docker` group. This
task instead adds Netdata as a container in each node's existing
`stacks/<node>/docker-compose.yml`, deployed by the existing
`deploy.yml` pipeline — no new script, no SSH access beyond what
`deploy.yml` already uses.

vps02 currently has `services: {}` — no `cloudflared` at all. Netdata
is its first workload, so this task also gives vps02 its own dedicated
tunnel wiring (its compose file's own comment already prescribes this
exact pattern).

**Files:**
- Create: `stacks/vps00/netdata.conf`, `stacks/vps01/netdata.conf`,
  `stacks/vps02/netdata.conf` (identical content, matching this repo's
  existing per-node duplication style)
- Modify: `stacks/vps00/docker-compose.yml`,
  `stacks/vps01/docker-compose.yml` (add the `netdata` service)
- Modify: `stacks/vps02/docker-compose.yml` (add `netdata` **and**
  `cloudflared` — replace the stale "no cloudflared here" comment)
- Modify: `.github/workflows/deploy.yml` (vps02's job gains a "Write
  remote .env" step, same shape as vps01's)
- Modify: `.env.example` (add `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`,
  empty)
- Modify: `stacks/CLAUDE.md` (document the new `netdata` service +
  vps02's new tunnel; retire the now-false "vps02 has no cloudflared"
  framing)

**Interfaces:**
- Produces: once this branch merges and `deploy.yml` runs, a `netdata`
  container reachable at `127.0.0.1:19999` on each node (`network_mode:
  host`, same pattern as `cloudflared`), plus vps02's own tunnel
  connector. Task 3 (Cloudflare dashboard) and Task 6 (`poll.js`)
  depend on the hostnames/ports this defines — not on a live deploy;
  nothing in this task touches production, it only adds commits to
  this worktree branch.
- Consumes: none from earlier tasks.
- Note: the compose files reference `/opt/stacks/<node>/health_alarm_notify.conf`
  (Task 2 generates this file at deploy time; it is never committed).
  `docker compose config` — this task's own verification bar — doesn't
  care that the file doesn't exist yet; `docker compose up` would, so
  don't attempt a real deploy until Task 2 is also done.

- [ ] **Step 1: Resolve and pin the exact Netdata image tag**

Run: `curl -fsSL "https://registry.hub.docker.com/v2/repositories/netdata/netdata/tags?page_size=25&ordering=last_updated" | grep -o '"name":"v2\.[0-9]*\.[0-9]*"' | head -1`
Note the resolved tag (e.g. `v2.11.0`) — used verbatim below instead of
`latest`, per this repo's pinning convention.

- [ ] **Step 2: Create the three `netdata.conf` files (identical content)**

```
[global]
    update every = 5
    memory mode = dbengine

[db]
    mode = dbengine
    storage tiers = 1
    dbengine tier 0 retention size = 0
    dbengine tier 0 retention time = 7d

[ml]
    enabled = no

[web]
    bind to = 127.0.0.1

[plugins]
    apps = no
    ebpf = no
```

Write this exact content to `stacks/vps00/netdata.conf`,
`stacks/vps01/netdata.conf`, and `stacks/vps02/netdata.conf`.

- [ ] **Step 3: Add the `netdata` service to `stacks/vps00/docker-compose.yml`**

Append under `services:` (keep the existing `cloudflared` block
untouched above it):

```yaml
  netdata:
    image: netdata/netdata:REPLACE_WITH_RESOLVED_TAG_FROM_STEP_1
    container_name: netdata
    restart: unless-stopped
    network_mode: host
    volumes:
      - netdataconfig:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./netdata.conf:/etc/netdata/netdata.conf:ro
      - ./health_alarm_notify.conf:/etc/netdata/health_alarm_notify.conf:ro
    mem_limit: 200m
    mem_reservation: 100m

volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
```

(The bind-mounted `/proc`, `/sys` etc. are what let a containerized
Netdata see the *host's* metrics instead of just the container's own —
required for this to mean anything. `docker.sock` read-only is for
container-name enrichment in the cgroups plugin, not control.)

- [ ] **Step 4: Same `netdata` service block in `stacks/vps01/docker-compose.yml`**

Identical block to Step 3, appended under vps01's existing `cloudflared`
service and its own `volumes:` top-level key.

- [ ] **Step 5: vps02 — add both `netdata` and its first `cloudflared`**

Replace vps02's `services: {}` and its stale explanatory comment
(the one starting "No cloudflared here...") with:

```yaml
---
# vps02 stack. Deployed by .github/workflows/deploy.yml to
# /opt/stacks/vps02/docker-compose.yml.
#
# Netdata is this node's first workload — it gets its own dedicated
# tunnel + token (CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS), never vps00's
# shared CLOUDFLARE_TUNNEL_TOKEN (see stacks/CLAUDE.md, rail 2 — a
# shared token load-balances requests across nodes with different
# origins and 502s).
#
# network_mode: host so localhost:19999 in the tunnel's Public Hostname
# route resolves to this VPS's own Netdata, not the container's netns.
services:
  cloudflared:
    image: cloudflare/cloudflared:2024.12.2
    container_name: cloudflared-vps02
    restart: unless-stopped
    network_mode: host
    command: tunnel run
    environment:
      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS}

  netdata:
    image: netdata/netdata:REPLACE_WITH_RESOLVED_TAG_FROM_STEP_1
    container_name: netdata
    restart: unless-stopped
    network_mode: host
    volumes:
      - netdataconfig:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./netdata.conf:/etc/netdata/netdata.conf:ro
      - ./health_alarm_notify.conf:/etc/netdata/health_alarm_notify.conf:ro
    mem_limit: 200m
    mem_reservation: 100m

volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
```

- [ ] **Step 6: Add vps02's "Write remote .env" step to `deploy.yml`**

In the `deploy-vps02` job, insert a new step between "Sync stack files"
and "Deploy vps02" (mirror `deploy-vps01`'s equivalent step exactly):

```yaml
      - name: Write remote .env
        run: |
          printf 'CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS=%s\n' "${{ secrets.CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS }}" | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps02/.env'
```

- [ ] **Step 7: Add the new secret placeholder to `.env.example`**

```
CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS=
```

- [ ] **Step 8: Update `stacks/CLAUDE.md`**

Add `netdata` to the "Current routes" / service description section:
note it runs on all 3 nodes, `network_mode: host`, config in
`netdata.conf` (committed, no secrets) + `health_alarm_notify.conf`
(generated at deploy time by Task 2, never committed). Update or remove
the vps02-specific old guidance that said "no cloudflared here yet" —
it now has one.

- [ ] **Step 9: Validate compose syntax**

Run: `cd stacks/vps00 && docker compose config >/dev/null` (repeat for
`vps01`, `vps02`).
Expected: no errors (a warning about the missing
`health_alarm_notify.conf` file, if any, is fine — see the Interfaces
note above; `docker compose config` validates syntax/interpolation,
not that bind-mount source files exist).

- [ ] **Step 10: yamllint**

Run: `yamllint --strict stacks/vps00/docker-compose.yml stacks/vps01/docker-compose.yml stacks/vps02/docker-compose.yml .github/workflows/deploy.yml`
Expected: clean.

- [ ] **Step 11: Commit**

```bash
git add stacks/vps00/netdata.conf stacks/vps00/docker-compose.yml \
  stacks/vps01/netdata.conf stacks/vps01/docker-compose.yml \
  stacks/vps02/netdata.conf stacks/vps02/docker-compose.yml \
  .github/workflows/deploy.yml .env.example stacks/CLAUDE.md
git commit -m "feat: run Netdata as a Docker service on all 3 nodes; vps02's first Cloudflare Tunnel"
```

---

### Task 2: Telegram alerting for Netdata

**Files:**
- Create: `stacks/vps00/health_alarm_notify.conf.template`,
  `stacks/vps01/health_alarm_notify.conf.template`,
  `stacks/vps02/health_alarm_notify.conf.template` (identical content,
  placeholders only — no secrets)
- Modify: `.github/workflows/deploy.yml` (one new step per node: render
  the template with the real secrets, write it to the remote host —
  same shape as the existing "Write remote .env" step)
- Modify: `.github/workflows/CLAUDE.md` (required-secrets list)
- Modify: `.env.example` (add `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`)

**Interfaces:**
- Consumes: the `netdata` service definitions from Task 1 (this task's
  files are what fills the bind mount Task 1 left pointing at a
  not-yet-existing file).
- Produces: once deployed, Netdata's default health alarms (unmodified
  — see the note below) notify Telegram on breach. Nothing else in
  `health_alarm_notify.conf` needs to be set: `alarm-notify.sh` already
  has its own internal default (disabled) for every notification method
  it doesn't find configured, so a minimal file that only turns on
  Telegram is a complete, valid file — not a partial one.

Before this task: create a Telegram bot via `@BotFather` (`/newbot`),
save the bot token; message the bot once, then read
`https://api.telegram.org/bot<token>/getUpdates` to find your chat ID.

- [ ] **Step 1: Create the three `health_alarm_notify.conf.template` files (identical content)**

```
# Netdata alarm notifications -- Telegram only. Rendered into the real
# file at deploy time (deploy.yml); the two placeholders below are
# substituted from GitHub secrets, never committed as real values.
# Every other notification method stays at alarm-notify.sh's own
# built-in default (disabled) -- this file only needs to turn on what
# we're using.
SEND_TELEGRAM="YES"
TELEGRAM_BOT_TOKEN="__TELEGRAM_BOT_TOKEN__"
DEFAULT_RECIPIENT_TELEGRAM="__TELEGRAM_CHAT_ID__"
```

Write this exact content to all three
`stacks/<node>/health_alarm_notify.conf.template` files.

- [ ] **Step 2: Add the render-and-write step to each `deploy.yml` job**

In `deploy-vps00`, insert a new step immediately after "Write remote
.env":

```yaml
      - name: Write remote health_alarm_notify.conf
        run: |
          sed \
            -e "s/__TELEGRAM_BOT_TOKEN__/${{ secrets.TELEGRAM_BOT_TOKEN }}/" \
            -e "s/__TELEGRAM_CHAT_ID__/${{ secrets.TELEGRAM_CHAT_ID }}/" \
            stacks/vps00/health_alarm_notify.conf.template | \
            ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
            'umask 077 && cat > /opt/stacks/vps00/health_alarm_notify.conf'
```

Add the same step (with `vps01`/`vps02` substituted for `vps00` in both
the local template path and the remote destination path) to
`deploy-vps01` right after its "Write remote .env" step, and to
`deploy-vps02` right after the "Write remote .env" step Task 1 Step 6
added.

- [ ] **Step 3: actionlint**

Run: `actionlint .github/workflows/deploy.yml`
Expected: clean.

- [ ] **Step 4: Add the two new vars to `.env.example`**

```
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

- [ ] **Step 5: Update `.github/workflows/CLAUDE.md`'s required-secrets list**

Add `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`,
`CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` (the last one belongs to Task 1
but wasn't yet documented there — pick it up here too) to the
"Required GitHub Secrets / Variables" line.

- [ ] **Step 6: yamllint**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add stacks/vps00/health_alarm_notify.conf.template \
  stacks/vps01/health_alarm_notify.conf.template \
  stacks/vps02/health_alarm_notify.conf.template \
  .github/workflows/deploy.yml .github/workflows/CLAUDE.md .env.example
git commit -m "feat: wire Netdata alerts to Telegram via GitOps deploy"
```

---

### Task 3: Cloudflare Tunnel routes + Access gating (manual, dashboard)

This step is dashboard-driven, not code — ingress routing for this
repo's tunnels has always lived in the Cloudflare Zero Trust dashboard,
never a local config file (`stacks/CLAUDE.md`). This is the one task in
this plan that touches your real Cloudflare account — do it yourself,
at your own pace; nothing later in this plan needs it done before Tasks
4-8 (Worker code) proceed.

**Interfaces:**
- Produces: `vps00-metrics.maybeit.work`, `vps01-metrics.maybeit.work`,
  `vps02-metrics.maybeit.work` — each reachable only with a valid
  Cloudflare Access service-token header pair, or your own logged-in
  session. Task 6 (`poll.js`) and Task 8 (Worker secrets) consume the
  service token this step creates. `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS`
  (Step 1 below) is also what unblocks vps02's actual deploy from Task 1
  — until this secret exists in GitHub, vps02's `cloudflared` container
  can't start (empty `TUNNEL_TOKEN`).

- [ ] **Step 1: Create vps02's first Cloudflare Tunnel**

Zero Trust dashboard → Networks → Tunnels → Create a tunnel → Cloudflared
→ name it (e.g. `vps02`). Copy the generated token — this becomes the
GitHub secret `CLOUDFLARE_TUNNEL_TOKEN_VPS02_METRICS` referenced by
Task 1's compose change. Add it now: repo Settings → Secrets and
variables → Actions → New repository secret.

- [ ] **Step 2: Create one shared Access service token**

Access → Service Auth → Service Tokens → Create Service Token. Name:
`status-worker`. Save the generated **Client ID** and **Client Secret**
immediately (shown once) — these become `CF_ACCESS_CLIENT_ID` /
`CF_ACCESS_CLIENT_SECRET` in Task 8. Do not paste them into any file in
this repo.

- [ ] **Step 3: Add a Public Hostname on each node's tunnel**

For each of vps00, vps01, vps02 (vps02 using the tunnel from Step 1):
Networks → Tunnels → select that node's tunnel → Public Hostnames → Add
a public hostname.
- Subdomain: `<node>-metrics` (e.g. `vps00-metrics`)
- Domain: `maybeit.work`
- Type: `HTTP`
- URL: `localhost:19999`

- [ ] **Step 4: Add an Access application per node, gated by the service token**

For each of the 3 new hostnames: Access → Applications → Add an
application → Self-hosted.
- Application name: `<node> Netdata metrics`
- Application domain: `<node>-metrics.maybeit.work`
- Policy 1 — name: `worker-service-token`, Action: `Service Auth`,
  Include: Service Token → `status-worker` (from Step 2).
- Policy 2 — name: `owner-access`, Action: `Allow`, Include: Emails →
  your own account email (lets you open the raw Netdata dashboard
  yourself later; not required by the Worker).

- [ ] **Step 5: Verify gating and reachability (after this branch merges and deploys)**

Without credentials (expect blocked):
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://vps00-metrics.maybeit.work/api/v1/info
```
Expected: `302` or `403`, not `200`.

With the service token (expect success):
```bash
curl -sS \
  -H "CF-Access-Client-Id: <client id from Step 2>" \
  -H "CF-Access-Client-Secret: <client secret from Step 2>" \
  https://vps00-metrics.maybeit.work/api/v1/info
```
Expected: `200` with a JSON body containing Netdata version info.

Repeat both checks for vps01-metrics and vps02-metrics.

- [ ] **Step 6: Note in commit trail**

No files change in this repo for this task (Step 1's secret excepted,
added directly in GitHub, never committed). Nothing to `git add` here —
dashboard state isn't tracked by this repo.

---

### Task 4: Worker project scaffold + Biome setup

**Files:**
- Create: `biome.json` (repo root — first JS/TS/JSON in this repo)
- Create: `worker/status/package.json`
- Create: `worker/status/wrangler.toml`
- Create: `worker/status/CLAUDE.md`
- Modify: `.claude/CLAUDE.md` (directory map row for `worker/`)

**Interfaces:**
- Produces: an empty-but-lintable Worker project skeleton. Tasks 5-7 add
  the actual `src/*.js` files this `package.json`/`wrangler.toml`
  reference.

- [ ] **Step 1: Resolve and pin the exact `wrangler` version**

Run: `npm view wrangler version`
Note the resolved version (e.g. `4.x.y`) — used verbatim in Step 3, per
this repo's "never `latest`" convention.

- [ ] **Step 2: Create `biome.json`** (hard-railed content, per
  `tooling-setup`)

```json
{
  "$schema": "https://biomejs.dev/schemas/2.5.0/schema.json",
  "vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
  "files": { "ignoreUnknown": false, "ignore": ["node_modules", "dist", "build"] },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2, "lineWidth": 100 },
  "organizeImports": { "enabled": true },
  "linter": { "enabled": true, "rules": { "recommended": true } },
  "javascript": {
    "formatter": { "quoteStyle": "single", "semicolons": "asNeeded", "trailingCommas": "all" }
  },
  "json": { "formatter": { "enabled": true } }
}
```

- [ ] **Step 3: Create `worker/status/package.json`**

```json
{
  "name": "maybeit-status",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test test/",
    "dev": "wrangler dev",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "wrangler": "REPLACE_WITH_RESOLVED_VERSION_FROM_STEP_1"
  }
}
```

- [ ] **Step 4: Create `worker/status/wrangler.toml`**

```toml
name = "maybeit-status"
main = "src/index.js"
compatibility_date = "2026-08-15"

routes = [
  { pattern = "maybeit.work", custom_domain = true }
]

[triggers]
crons = ["*/5 * * * *"]

[[kv_namespaces]]
binding = "STATUS_KV"
id = "REPLACE_AFTER_RUNNING: wrangler kv namespace create STATUS_KV"

[vars]
NODE_HOSTS = "vps00-metrics.maybeit.work,vps01-metrics.maybeit.work,vps02-metrics.maybeit.work"
DOKPLOY_HOST = "dokploy.maybeit.work"
```

- [ ] **Step 5: Install deps, create the real KV namespace, fill in its id**

```bash
cd worker/status
npm install
npx wrangler kv namespace create STATUS_KV
```
Copy the returned `id` into `wrangler.toml`'s `kv_namespaces[0].id`,
replacing the placeholder.

- [ ] **Step 6: Create `worker/status/CLAUDE.md`**

```markdown
Parent: ../../.claude/CLAUDE.md

# worker/status/ — maybeit.work status dashboard (Cloudflare Worker)

Serves the status page at the `maybeit.work` apex and polls node health
on a Cron Trigger. Deliberately **not** deployed via Dokploy/VPS — see
the design spec for why (`docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`).

## Layout

- `src/render.js` — pure function, status JSON in, HTML out. No fetch,
  no KV — this is the only part with real branching logic, and the only
  part with a test.
- `src/poll.js` — polls each node's Netdata API (through the
  Access-gated tunnel route) + a plain Dokploy reachability check,
  returns a status snapshot. `fetch` is injectable for testing.
- `src/index.js` — wires `fetch` (render from KV) and `scheduled` (poll,
  write to KV) handlers together. No logic of its own.

## Local dev

`npm install`, `npx wrangler dev --test-scheduled`, then
`curl "http://localhost:8787/__scheduled?cron=*+*+*+*+*"` to manually
fire the poll locally before hitting `http://localhost:8787/`.

## Secrets

`CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` — the Cloudflare
Access service token created in the design's Cloudflare dashboard step.
Set via `wrangler secret put`, never in this directory.

## Failure log

```

- [ ] **Step 7: Update the directory map in `.claude/CLAUDE.md`**

Add a row: `| worker/status/ | Cloudflare Worker: status page + health
poller | exists → worker/status/CLAUDE.md |`

- [ ] **Step 8: Verify lint passes on the skeleton**

Run: `biome ci .`
Expected: passes (nothing to flag yet — `wrangler.toml` is TOML, not
JSON/JS, so Biome doesn't touch it; `package.json` is valid JSON).

- [ ] **Step 9: Commit**

```bash
git add biome.json worker/status/package.json worker/status/package-lock.json \
  worker/status/wrangler.toml worker/status/CLAUDE.md .claude/CLAUDE.md
git commit -m "chore: scaffold status Worker project + Biome setup"
```

---

### Task 5: `render.js` — status JSON to HTML

**Files:**
- Create: `worker/status/src/render.js`
- Test: `worker/status/test/render.test.js`

**Interfaces:**
- Produces: `renderStatusPage(snapshot: {nodes: {[name]: {up, cpu, mem,
  disk, lastSeen}}, dokploy: {up, lastSeen}} | null): string` (HTML).
  Task 7 imports this exact name/signature.

- [ ] **Step 1: Write the failing tests**

```js
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { renderStatusPage } from '../src/render.js'

test('renders "no data yet" when snapshot is null', () => {
  const html = renderStatusPage(null)
  assert.match(html, /No data yet/)
})

test('renders green light and utilization for an up node', () => {
  const html = renderStatusPage({
    nodes: { vps00: { up: true, cpu: 12.3, mem: 45.6, disk: 30.1, lastSeen: '2026-08-15T00:00:00Z' } },
    dokploy: { up: true, lastSeen: '2026-08-15T00:00:00Z' },
  })
  assert.match(html, /🟢 vps00/)
  assert.match(html, /12\.3%/)
})

test('renders red light for a down node', () => {
  const html = renderStatusPage({
    nodes: { vps01: { up: false, cpu: 0, mem: 0, disk: 0, lastSeen: '2026-08-15T00:00:00Z' } },
    dokploy: { up: true, lastSeen: '2026-08-15T00:00:00Z' },
  })
  assert.match(html, /🔴 vps01/)
})

test('renders a dokploy row', () => {
  const html = renderStatusPage({
    nodes: {},
    dokploy: { up: false, lastSeen: '2026-08-15T00:00:00Z' },
  })
  assert.match(html, /🔴 dokploy/)
})
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd worker/status && node --test test/render.test.js`
Expected: FAIL — `Cannot find module '../src/render.js'`.

- [ ] **Step 3: Implement**

```js
// Pure function: status snapshot -> HTML status page. No fetch, no KV --
// keeps this testable without touching the Workers runtime.

function light(up) {
  return up ? '🟢' : '🔴'
}

function bar(pct) {
  const clamped = Math.max(0, Math.min(100, pct))
  return `<div class="bar"><div class="bar-fill" style="width:${clamped}%"></div><span>${clamped.toFixed(1)}%</span></div>`
}

function renderShell(body) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>maybeit.work status</title>
<style>
  body { font-family: system-ui, sans-serif; background:#111; color:#eee; padding:2rem; }
  table { border-collapse: collapse; width:100%; max-width:640px; }
  td, th { padding:.5rem; text-align:left; border-bottom:1px solid #333; }
  .bar { position:relative; background:#333; border-radius:4px; width:120px; height:1rem; }
  .bar-fill { position:absolute; inset:0; background:#3b82f6; border-radius:4px; }
  .bar span { position:relative; z-index:1; font-size:.7rem; padding-left:4px; }
</style></head>
<body><h1>maybeit.work status</h1>${body}</body></html>`
}

export function renderStatusPage(snapshot) {
  if (!snapshot) {
    return renderShell('<p>No data yet.</p>')
  }

  const nodeRows = Object.entries(snapshot.nodes)
    .map(
      ([name, n]) => `
      <tr>
        <td>${light(n.up)} ${name}</td>
        <td>${bar(n.cpu)}</td>
        <td>${bar(n.mem)}</td>
        <td>${bar(n.disk)}</td>
        <td>${n.lastSeen}</td>
      </tr>`,
    )
    .join('')

  const dokployRow = `
    <tr>
      <td>${light(snapshot.dokploy.up)} dokploy</td>
      <td colspan="3">control plane</td>
      <td>${snapshot.dokploy.lastSeen}</td>
    </tr>`

  return renderShell(`
    <table>
      <thead><tr><th>node</th><th>cpu</th><th>mem</th><th>disk</th><th>last seen</th></tr></thead>
      <tbody>${nodeRows}${dokployRow}</tbody>
    </table>`)
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `cd worker/status && node --test test/render.test.js`
Expected: 4 passing.

- [ ] **Step 5: Lint**

Run: `biome ci worker/status/src/render.js worker/status/test/render.test.js`
Expected: clean (or auto-fixable — run `biome check --write` if so, then
re-run tests).

- [ ] **Step 6: Commit**

```bash
git add worker/status/src/render.js worker/status/test/render.test.js
git commit -m "feat: add status page render function"
```

---

### Task 6: `poll.js` — collect node + Dokploy status

**Files:**
- Create: `worker/status/src/poll.js`
- Test: `worker/status/test/poll.test.js`

**Interfaces:**
- Consumes: nothing from earlier tasks directly, but the disk chart id
  noted in Task 1 Step 3 (expected `disk_space._`, confirm against what
  was actually printed).
- Produces: `pollAll(env: {CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET,
  NODE_HOSTS, DOKPLOY_HOST}, fetchFn?: typeof fetch): Promise<{nodes:
  {[name]: {up, cpu, mem, disk, lastSeen}}, dokploy: {up, lastSeen}}>`.
  Task 7 imports this exact name/signature and passes it the real `env`
  + global `fetch`.

- [ ] **Step 1: Write the failing tests**

```js
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { pollAll } from '../src/poll.js'

function jsonResponse(labels, values, status = 200) {
  return new Response(JSON.stringify({ labels, data: [[0, ...values]] }), { status })
}

test('pollAll marks a node up with parsed cpu/mem/disk percentages', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'idle'], [15, 85])
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, true)
  assert.equal(snapshot.nodes.vps00.cpu, 15)
  assert.equal(snapshot.nodes.vps00.mem, 60)
  assert.equal(snapshot.nodes.vps00.disk, 30)
  assert.equal(snapshot.dokploy.up, true)
})

test('pollAll marks a node down on fetch failure, without throwing', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps01-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('dokploy')) return new Response('', { status: 200 })
    throw new Error('network error')
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps01.up, false)
  assert.equal(snapshot.dokploy.up, true)
})

test('pollAll marks dokploy down on a 5xx response', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: '',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async () => new Response('', { status: 502 })
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.dokploy.up, false)
})
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd worker/status && node --test test/poll.test.js`
Expected: FAIL — `Cannot find module '../src/poll.js'`.

- [ ] **Step 3: Implement**

```js
// Polls each node's Netdata API (through the Access-gated tunnel
// route) + a plain Dokploy reachability check. `fetchFn` is injectable
// so tests never hit the network.

const TIMEOUT_MS = 5000

async function fetchWithTimeout(fetchFn, url, options) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
  try {
    return await fetchFn(url, { ...options, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

function round1(n) {
  return Math.round(n * 10) / 10
}

async function queryPercent(fetchFn, host, headers, chart, dimName) {
  const url = `https://${host}/api/v1/data?chart=${encodeURIComponent(chart)}&after=-1&points=1&options=percentage`
  const res = await fetchWithTimeout(fetchFn, url, { headers })
  if (!res.ok) throw new Error(`netdata ${chart} status ${res.status}`)
  const { labels, data } = await res.json()
  const idx = labels.indexOf(dimName)
  if (idx < 0 || !data[0]) throw new Error(`netdata ${chart} missing dimension ${dimName}`)
  return data[0][idx]
}

async function pollNode(fetchFn, host, headers) {
  const now = new Date().toISOString()
  try {
    const [idle, mem, disk] = await Promise.all([
      queryPercent(fetchFn, host, headers, 'system.cpu', 'idle'),
      queryPercent(fetchFn, host, headers, 'system.ram', 'used'),
      queryPercent(fetchFn, host, headers, 'disk_space._', 'used'),
    ])
    return { up: true, cpu: round1(100 - idle), mem: round1(mem), disk: round1(disk), lastSeen: now }
  } catch {
    return { up: false, cpu: 0, mem: 0, disk: 0, lastSeen: now }
  }
}

async function pollDokploy(fetchFn, host) {
  const now = new Date().toISOString()
  try {
    const res = await fetchWithTimeout(fetchFn, `https://${host}/`, { method: 'GET' })
    return { up: res.status < 500, lastSeen: now }
  } catch {
    return { up: false, lastSeen: now }
  }
}

export async function pollAll(env, fetchFn = fetch) {
  const headers = {
    'CF-Access-Client-Id': env.CF_ACCESS_CLIENT_ID,
    'CF-Access-Client-Secret': env.CF_ACCESS_CLIENT_SECRET,
  }
  const nodeHosts = env.NODE_HOSTS ? env.NODE_HOSTS.split(',') : []
  const nodes = {}
  await Promise.all(
    nodeHosts.map(async (host) => {
      const name = host.split('-metrics.')[0]
      nodes[name] = await pollNode(fetchFn, host, headers)
    }),
  )
  const dokploy = await pollDokploy(fetchFn, env.DOKPLOY_HOST)
  return { nodes, dokploy }
}
```

If Task 1 Step 3 printed a disk chart id other than `disk_space._`,
change the literal in `pollNode`'s `Promise.all` call to match before
running Step 4.

- [ ] **Step 4: Run, verify it passes**

Run: `cd worker/status && node --test test/poll.test.js`
Expected: 3 passing.

- [ ] **Step 5: Lint**

Run: `biome ci worker/status/src/poll.js worker/status/test/poll.test.js`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add worker/status/src/poll.js worker/status/test/poll.test.js
git commit -m "feat: add node/dokploy status polling"
```

---

### Task 7: `index.js` — wire fetch + scheduled handlers

**Files:**
- Create: `worker/status/src/index.js`

**Interfaces:**
- Consumes: `renderStatusPage` (Task 5), `pollAll` (Task 6),
  `env.STATUS_KV` (Task 4's `wrangler.toml` binding).

- [ ] **Step 1: Implement**

```js
import { renderStatusPage } from './render.js'
import { pollAll } from './poll.js'

const SNAPSHOT_KEY = 'snapshot'

export default {
  async fetch(request, env) {
    const snapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    return new Response(renderStatusPage(snapshot), {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  },

  async scheduled(event, env) {
    const snapshot = await pollAll(env)
    await env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(snapshot))
  },
}
```

- [ ] **Step 2: Lint**

Run: `biome ci worker/status/src/index.js`
Expected: clean.

- [ ] **Step 3: Local smoke test**

```bash
cd worker/status
npx wrangler dev --test-scheduled
```
In another terminal:
```bash
curl http://localhost:8787/
```
Expected: HTML page, "No data yet" (KV is empty locally).

```bash
curl "http://localhost:8787/__scheduled?cron=*+*+*+*+*"
curl http://localhost:8787/
```
Expected: second `curl /` now renders a table — node polls will show
red (no real Access creds in local dev unless you've set `.dev.vars`),
Dokploy may show green if your dev machine reaches the real internet.
This confirms the fetch → poll → KV → render loop works end to end
without deploying.

- [ ] **Step 4: Commit**

```bash
git add worker/status/src/index.js
git commit -m "feat: wire status Worker fetch + scheduled handlers"
```

---

### Task 8: Deploy pipeline + secrets + first real deploy

**Files:**
- Create: `.github/workflows/deploy-worker.yml`
- Modify: `.github/workflows/CLAUDE.md` (required secrets list)
- Modify: `.env.example` (add `CF_ACCESS_CLIENT_ID`,
  `CF_ACCESS_CLIENT_SECRET`, empty values)

**Interfaces:**
- Consumes: `worker/status/` (Tasks 4-7), the service token from Task 3
  Step 1, the existing (currently unused) `CLOUDFLARE_API_TOKEN` /
  `CLOUDFLARE_ACCOUNT_ID` GitHub secrets.

- [ ] **Step 1: Add the new GitHub repo secrets**

In the repo's GitHub Settings → Secrets and variables → Actions, add:
`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` (values from Task 3
Step 1). Confirm `CLOUDFLARE_API_TOKEN` has `Account.Workers
Scripts:Edit` permission in the Cloudflare dashboard (My Profile → API
Tokens → edit the token) — it was reserved but unused before this task,
so its scope has never been exercised.

- [ ] **Step 2: Add `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` to `.env.example`**

```
CF_ACCESS_CLIENT_ID=
CF_ACCESS_CLIENT_SECRET=
```

- [ ] **Step 3: Write `.github/workflows/deploy-worker.yml`**

```yaml
name: Deploy Worker

on:
  push:
    branches: [main]
    paths:
      - 'worker/status/**'
      - '.github/workflows/deploy-worker.yml'
  workflow_dispatch: {}

concurrency:
  group: deploy-worker
  cancel-in-progress: false

jobs:
  validate:
    uses: ./.github/workflows/validate.yml

  deploy:
    needs: validate
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: worker/status
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '22'

      - run: npm ci

      - run: npm test

      - uses: cloudflare/wrangler-action@v3
        with:
          apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          accountId: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          workingDirectory: worker/status
          secrets: |
            CF_ACCESS_CLIENT_ID
            CF_ACCESS_CLIENT_SECRET
        env:
          CF_ACCESS_CLIENT_ID: ${{ secrets.CF_ACCESS_CLIENT_ID }}
          CF_ACCESS_CLIENT_SECRET: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
```

- [ ] **Step 4: actionlint**

Run: `actionlint .github/workflows/deploy-worker.yml`
Expected: clean.

- [ ] **Step 5: Update `.github/workflows/CLAUDE.md`'s required-secrets list**

Add to the "Required GitHub Secrets / Variables" line:
`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/deploy-worker.yml .github/workflows/CLAUDE.md .env.example
git commit -m "ci: deploy status Worker on push, gated by validate.yml"
```

- [ ] **Step 7: Push to main, watch the deploy**

Push this branch/commit to `main` (or open a PR and merge). Watch the
`Deploy Worker` GitHub Actions run.
Expected: `validate` job passes, `deploy` job's `npm test` passes,
`wrangler-action` reports a successful deploy.

- [ ] **Step 8: Verify the live page**

```bash
curl -sS https://maybeit.work/
```
Expected: `200`, HTML containing "No data yet" (cron hasn't fired yet)
or a populated table if 5+ minutes have passed since deploy.

- [ ] **Step 9: Verify alerts still independent**

No action needed — Netdata's Telegram alerting (Task 2) doesn't depend
on the Worker at all. Confirmed already in Task 2 Step 4.

---

## Self-review notes

- **Spec coverage:** data collection (Task 1), alerting (Task 2),
  transport/Access (Task 3), delivery/Worker (Tasks 4-7), deploy
  pipeline (Task 8) — every section of the design spec maps to a task.
- **Placeholder scan:** the only two literal `REPLACE_*` markers
  (`wrangler.toml`'s KV id, `package.json`'s wrangler version) are
  filled in by the task's own steps before it's considered done — not
  left open-ended.
- **Type/name consistency:** `renderStatusPage(snapshot)` (Task 5) and
  `pollAll(env, fetchFn)` (Task 6) are used with matching
  names/signatures in Task 7's `index.js`.
