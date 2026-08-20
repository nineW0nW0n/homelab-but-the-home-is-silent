// Polls each node's Netdata API (through the Access-gated tunnel
// route). `fetchFn` is injectable so tests never hit the network.
//
// Deliberately does NOT poll Dokploy. It used to, sending the same Access
// service token to dokploy.maybeit.work -- which meant a public Worker held a
// credential to the deploy control plane in order to produce an up/down
// boolean that only ever appeared in /debug. Removed 2026-08-20; the token
// now opens Netdata metrics only. Check Dokploy by loading its URL.

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

async function queryChart(fetchFn, host, headers, chart, dimName, options) {
  // Window is 60s (>> Netdata's 5s update every, see netdata.conf) so a
  // slow tick or two never reads back empty -- a narrower window risks
  // throwing on a healthy node.
  const optionsParam = options ? `&options=${options}` : ''
  const url = `https://${host}/api/v1/data?chart=${encodeURIComponent(chart)}&after=-60&points=1${optionsParam}`
  const res = await fetchWithTimeout(fetchFn, url, { headers })
  if (!res.ok) throw new Error(`netdata ${chart} status ${res.status}`)
  const { labels, data } = await res.json()
  const idx = labels.indexOf(dimName)
  if (idx < 0 || !data[0]) throw new Error(`netdata ${chart} missing dimension ${dimName}`)
  const value = data[0][idx]
  // Fail closed: a non-numeric read (null/undefined/NaN) means the node
  // reports down rather than silently rendering NaN/0 as if it were 0%.
  if (typeof value !== 'number' || Number.isNaN(value)) {
    throw new Error(`netdata ${chart} dimension ${dimName} not numeric`)
  }
  return value
}

// "percentage" makes Netdata return the dimension as % of that chart's
// stacked dimensions at that point -- works for any chart whose dims sum
// to a whole (system.ram, mem.swap), regardless of the chart's own units.
function queryPercent(fetchFn, host, headers, chart, dimName) {
  return queryChart(fetchFn, host, headers, chart, dimName, 'percentage')
}

// system.load's dimensions (load1/load5/load15) don't sum to anything --
// each is its own absolute load-average number, so no percentage option.
// Confirmed against a live vps00 node's /api/v1/charts (2026-08-16):
// dims are load1/load5/load15, units "load".
function queryRaw(fetchFn, host, headers, chart, dimName) {
  return queryChart(fetchFn, host, headers, chart, dimName, null)
}

// Confirmed against a live vps00 node's /api/v1/charts (2026-08-16):
// system.cpu has no "idle" dimension in this deployment's Netdata
// config -- only the busy-state dimensions (user/system/nice/iowait/
// irq/softirq/steal/guest/guest_nice), which already sum to the busy
// percentage. Other Netdata configs do report "idle" explicitly, so
// handle both rather than hardcoding one shape.
async function queryCpuBusyPercent(fetchFn, host, headers, chart) {
  const url = `https://${host}/api/v1/data?chart=${encodeURIComponent(chart)}&after=-60&points=1&options=percentage`
  const res = await fetchWithTimeout(fetchFn, url, { headers })
  if (!res.ok) throw new Error(`netdata ${chart} status ${res.status}`)
  const { labels, data } = await res.json()
  const row = data[0]
  if (!row) throw new Error(`netdata ${chart} no data`)
  const idleIdx = labels.indexOf('idle')
  if (idleIdx >= 0) {
    const idleValue = row[idleIdx]
    if (typeof idleValue !== 'number' || Number.isNaN(idleValue)) {
      throw new Error(`netdata ${chart} dimension idle not numeric`)
    }
    return 100 - idleValue
  }
  const values = row.slice(1) // drop the leading timestamp column
  if (values.length === 0 || values.some((v) => typeof v !== 'number' || Number.isNaN(v))) {
    throw new Error(`netdata ${chart} missing/invalid dimension values`)
  }
  return values.reduce((sum, v) => sum + v, 0)
}

// Every node in this homelab is a 2 vCPU VPS (root CLAUDE.md) -- load1 is
// an absolute average, not a percent, so normalize by core count to get
// a 0-100 score. Update this if a node's spec ever changes.
const NODE_VCPUS = 2

async function pollNode(fetchFn, host, headers, previous) {
  const now = new Date().toISOString()
  try {
    const [cpuBusy, mem, disk, load1, swap] = await Promise.all([
      queryCpuBusyPercent(fetchFn, host, headers, 'system.cpu'),
      queryPercent(fetchFn, host, headers, 'system.ram', 'used'),
      // Root filesystem chart id keeps the literal "/" -- confirmed
      // against a live vps00 node, not sanitized to "_" as guessed.
      queryPercent(fetchFn, host, headers, 'disk_space./', 'used'),
      queryRaw(fetchFn, host, headers, 'system.load', 'load1'),
      queryPercent(fetchFn, host, headers, 'mem.swap', 'used'),
    ])
    const loadPercent = Math.max(0, Math.min(100, (load1 / NODE_VCPUS) * 100))
    return {
      up: true,
      cpu: round1(cpuBusy),
      mem: round1(mem),
      disk: round1(disk),
      load: round1(loadPercent),
      swap: round1(swap),
      lastPolled: now,
      lastSeen: now,
    }
  } catch (err) {
    // lastPolled is always "now" -- honest "last time we checked".
    // lastSeen carries forward the previous snapshot's lastSeen (last
    // time this node was confirmed up), or null on a node's first-ever
    // poll with no prior snapshot to carry forward from. `error` is
    // kept (not rendered on the page) so a silent down-node can still
    // be diagnosed via the raw snapshot -- see index.js's /debug route.
    return {
      up: false,
      cpu: 0,
      mem: 0,
      disk: 0,
      load: 0,
      swap: 0,
      lastPolled: now,
      lastSeen: previous?.lastSeen ?? null,
      error: err?.message ?? String(err),
    }
  }
}

// How long a snapshot is served without re-polling. Every poll is five
// Netdata calls per node against 2 vCPU boxes plus a KV write, so an
// unauthenticated request loop used to be a load generator pointed at the
// homelab. Keyed on a top-level polledAt, deliberately not on a per-node
// lastPolled -- a node may be missing from the snapshot entirely.
export const POLL_TTL_MS = 30_000

export function isFresh(snapshot, now = Date.now(), ttlMs = POLL_TTL_MS) {
  if (!snapshot?.polledAt) return false
  const polledAt = Date.parse(snapshot.polledAt)
  if (!Number.isFinite(polledAt)) return false
  const age = now - polledAt
  // A snapshot stamped in the future is a clock problem, not freshness.
  return age >= 0 && age < ttlMs
}

export async function pollAll(env, fetchFn = fetch, previousSnapshot = null) {
  const headers = {
    'CF-Access-Client-Id': env.CF_ACCESS_CLIENT_ID,
    'CF-Access-Client-Secret': env.CF_ACCESS_CLIENT_SECRET,
  }
  const nodeHosts = env.NODE_HOSTS ? env.NODE_HOSTS.split(',') : []
  const nodes = {}
  await Promise.all(
    nodeHosts.map(async (host) => {
      const name = host.split('-metrics.')[0]
      nodes[name] = await pollNode(fetchFn, host, headers, previousSnapshot?.nodes?.[name])
    }),
  )
  return { nodes, polledAt: new Date().toISOString() }
}
