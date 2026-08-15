# maybeit.work Status Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a status page at `maybeit.work` showing red/green health and
CPU/mem/disk % for vps00, vps01, vps02, and Dokploy — backed by tuned
Netdata agents, a Cloudflare Worker that polls and renders, and Netdata's
own Telegram alerting.

**Architecture:** Netdata agent (localhost:19999) on each VPS, reachable
only through a new Access-gated Cloudflare Tunnel route. A Cloudflare
Worker's Cron Trigger polls those routes + a Dokploy reachability check
every 5 minutes, writes one JSON snapshot to Workers KV; page views render
straight from that snapshot. Alerts fire from Netdata's own health engine
to Telegram, independent of the Worker.

**Tech Stack:** POSIX `sh` (node provisioning, matches `scripts/`),
Cloudflare Workers (plain JS, no framework), Workers KV, `wrangler`,
`node:test` for unit tests, GitHub Actions for the Worker's own deploy.

**Spec:** `docs/superpowers/specs/2026-08-15-maybeit-work-status-dashboard-design.md`

## Global Constraints

- One tunnel token per node, never shared (rail 2) — the new metrics
  route on each node reuses that node's *existing* `cloudflared`
  token/connector; it is a new Public Hostname, not a new token.
- Real IPs never committed (rail 5) — scripts take `<host>` as an
  argument, same as every existing script in `scripts/`; never hardcode
  an IP in a script or in this plan.
- CI deploy user stays key-only, no sudo (rail 6) — not touched by this
  work; Netdata install runs as `root` over SSH the same way
  `harden-node.sh` does, invoked manually by the operator, not by CI.
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

### Task 1: Install + tune Netdata on all 3 nodes

**Files:**
- Create: `scripts/install-netdata.sh`

**Interfaces:**
- Produces: a `netdata` service listening on `127.0.0.1:19999` on each
  node, with ML/apps/ebpf disabled and 1-week dbengine retention. Later
  tasks depend on this being reachable locally on each node.

- [ ] **Step 1: Write the script**

```sh
#!/bin/sh
# One-time (idempotent) per-node: installs Netdata (local agent only, no
# Cloud claiming), tuned for a 2GB box: ML off, apps/ebpf plugins off
# (heaviest collectors, not needed for a 3-number status page), dbengine
# capped to 1 week of retention by time (not size -- simplest correct
# knob for "just keep a week"). Binds the web UI to loopback only --
# reachability from outside the node happens through the Cloudflare
# Tunnel route added in a later, separate (manual, dashboard-driven)
# step, never by opening 19999 directly.
#
# Usage: scripts/install-netdata.sh <host>
#   scripts/install-netdata.sh 203.0.113.10

set -eu

host="${1:?usage: install-netdata.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Installing/tuning Netdata on ${ssh_user}@${host}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu

echo "-- install --"
command -v netdata >/dev/null 2>&1 || {
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry --dont-wait
  rm -f /tmp/netdata-kickstart.sh
}

echo "-- config --"
cat > /etc/netdata/netdata.conf <<'CONF'
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
CONF

systemctl restart netdata
sleep 2
systemctl is-active --quiet netdata && echo "netdata active"

echo "-- verify local API --"
curl -fsS http://127.0.0.1:19999/api/v1/info >/dev/null && echo "API reachable"

echo "-- root filesystem disk chart id (needed verbatim in Task 6) --"
curl -fsS http://127.0.0.1:19999/api/v1/charts | grep -o '"disk_space[^"]*"' | sort -u

echo "Netdata ready on $(hostname)"
EOF

echo "Done."
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck -s sh scripts/install-netdata.sh`
Expected: no output (clean).

- [ ] **Step 3: Run against vps00, capture the disk chart id**

Run: `scripts/install-netdata.sh <vps00 host from your local inventory.yaml>`
Expected: ends with `Netdata ready on <hostname>`. Note the exact
`disk_space.*` chart id printed for the root filesystem — Task 6's
`poll.js` needs it verbatim (it's expected to be `disk_space._` but
confirm against the real node instead of assuming).

- [ ] **Step 4: Run again, confirm idempotent**

Run the same command a second time.
Expected: `command -v netdata` short-circuits the install block, config
file content is identical (no diff), service restarts cleanly, same
"Netdata ready" output. No errors, no duplicate work.

- [ ] **Step 5: Repeat for vps01 and vps02**

Run: `scripts/install-netdata.sh <vps01 host>` and
`scripts/install-netdata.sh <vps02 host>`, same verification as steps
3-4 for each.

- [ ] **Step 6: Commit**

```bash
git add scripts/install-netdata.sh
git commit -m "feat: add idempotent Netdata install/tune script"
```

---

### Task 2: Configure Telegram alerting in Netdata

**Files:**
- Create: `scripts/configure-netdata-telegram.sh`
- Modify: `.env.example` (add `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`,
  empty values)

**Interfaces:**
- Consumes: `netdata` running on each node (Task 1).
- Produces: Netdata's default health alarms (already shipped, unmodified
  — deliberately not hand-tuning thresholds; see note below) now notify
  Telegram on breach.

Before this task: create a Telegram bot via `@BotFather` (`/newbot`),
save the bot token; message the bot once, then read
`https://api.telegram.org/bot<token>/getUpdates` to find your chat ID.
Both values go in your **local** `.env` (gitignored) as `TELEGRAM_BOT_TOKEN`
and `TELEGRAM_CHAT_ID` — never in `.env.example` or a commit.

- [ ] **Step 1: Add the two new vars to `.env.example`**

```
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

- [ ] **Step 2: Write the script**

```sh
#!/bin/sh
# One-time (idempotent) per-node: points Netdata's existing default
# health alarms at a Telegram bot. Deliberately does NOT hand-tune
# alarm thresholds (ram_in_use, used_disk_space, etc.) -- Netdata ships
# sane defaults out of the box and hand-rolling threshold overrides
# risks getting the health.d template syntax subtly wrong. Revisit only
# if the defaults prove too noisy/quiet in practice.
#
# Usage: TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=yyy \
#   scripts/configure-netdata-telegram.sh <host>

set -eu

host="${1:?usage: configure-netdata-telegram.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"
bot_token="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN must be set}"
chat_id="${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID must be set}"

echo "Configuring Telegram alerts on ${ssh_user}@${host}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<EOF
set -eu

sed -i \
  -e 's/^SEND_TELEGRAM=.*/SEND_TELEGRAM="YES"/' \
  -e 's/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN="${bot_token}"/' \
  -e 's/^DEFAULT_RECIPIENT_TELEGRAM=.*/DEFAULT_RECIPIENT_TELEGRAM="${chat_id}"/' \
  /etc/netdata/health_alarm_notify.conf

grep -q '^SEND_TELEGRAM="YES"' /etc/netdata/health_alarm_notify.conf
systemctl restart netdata
sleep 2
systemctl is-active --quiet netdata && echo "netdata active"

echo "-- sending test alert --"
su -s /bin/sh netdata -c '/usr/libexec/netdata/plugins.d/alarm-notify.sh test'
EOF

echo "Done. Check Telegram for the test message."
```

- [ ] **Step 3: shellcheck**

Run: `shellcheck -s sh scripts/configure-netdata-telegram.sh`
Expected: clean.

- [ ] **Step 4: Run against vps00, confirm delivery**

Run: `TELEGRAM_BOT_TOKEN=<your token> TELEGRAM_CHAT_ID=<your chat id> scripts/configure-netdata-telegram.sh <vps00 host>`
Expected: a test alert arrives in Telegram within a few seconds.

- [ ] **Step 5: Run again, confirm idempotent**

Same command again. Expected: `sed` replacements are no-ops on already-set
lines (values unchanged), service restarts cleanly, another test message
arrives.

- [ ] **Step 6: Repeat for vps01 and vps02**

Same as steps 4-5 for each remaining node.

- [ ] **Step 7: Commit**

```bash
git add scripts/configure-netdata-telegram.sh .env.example
git commit -m "feat: wire Netdata alerts to Telegram"
```

---

### Task 3: Cloudflare Tunnel route + Access gating (manual, dashboard)

This step is dashboard-driven, not code — ingress routing for this
repo's tunnels has always lived in the Cloudflare Zero Trust dashboard,
never a local config file (`stacks/CLAUDE.md`). Do this once per node.

**Interfaces:**
- Consumes: Netdata reachable at `127.0.0.1:19999` on each node (Task 1).
- Produces: `vps00-metrics.maybeit.work`, `vps01-metrics.maybeit.work`,
  `vps02-metrics.maybeit.work` — each reachable only with a valid
  Cloudflare Access service-token header pair, or your own logged-in
  session. Task 6 (`poll.js`) and Task 8 (Worker secrets) consume the
  service token this step creates.

- [ ] **Step 1: Create one shared Access service token**

Cloudflare Zero Trust dashboard → Access → Service Auth → Service
Tokens → Create Service Token. Name: `status-worker`. Save the
generated **Client ID** and **Client Secret** immediately (shown once)
— these become `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` in
Task 8. Do not paste them into any file in this repo.

- [ ] **Step 2: Add a Public Hostname on each node's tunnel**

For each of vps00, vps01, vps02: Zero Trust → Networks → Tunnels →
select that node's tunnel → Public Hostnames → Add a public hostname.
- Subdomain: `<node>-metrics` (e.g. `vps00-metrics`)
- Domain: `maybeit.work`
- Type: `HTTP`
- URL: `localhost:19999`

- [ ] **Step 3: Add an Access application per node, gated by the service token**

For each of the 3 new hostnames: Zero Trust → Access → Applications →
Add an application → Self-hosted.
- Application name: `<node> Netdata metrics`
- Application domain: `<node>-metrics.maybeit.work`
- Policy 1 — name: `worker-service-token`, Action: `Service Auth`,
  Include: Service Token → `status-worker` (the one from Step 1).
- Policy 2 — name: `owner-access`, Action: `Allow`, Include: Emails →
  your own account email (lets you open the raw Netdata dashboard
  yourself later; not required by the Worker).

- [ ] **Step 4: Verify gating and reachability**

Without credentials (expect blocked):
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://vps00-metrics.maybeit.work/api/v1/info
```
Expected: `302` or `403` (Access is blocking the request), not `200`.

With the service token (expect success):
```bash
curl -sS \
  -H "CF-Access-Client-Id: <client id from Step 1>" \
  -H "CF-Access-Client-Secret: <client secret from Step 1>" \
  https://vps00-metrics.maybeit.work/api/v1/info
```
Expected: `200` with a JSON body containing Netdata version info.

Repeat both checks for vps01-metrics and vps02-metrics.

- [ ] **Step 5: Note in commit trail**

No files change in this repo for this task. Record what was done in the
next task's commit message body (`docs:` note), since there's nothing
to `git add` here — dashboard state isn't tracked by this repo, same as
the two existing tunnel routes.

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
