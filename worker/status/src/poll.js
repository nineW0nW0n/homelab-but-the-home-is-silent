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
  // Window is 60s (>> Netdata's 5s update every, see netdata.conf) so a
  // slow tick or two never reads back empty -- a narrower window risks
  // throwing on a healthy node.
  const url = `https://${host}/api/v1/data?chart=${encodeURIComponent(chart)}&after=-60&points=1&options=percentage`
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

async function pollNode(fetchFn, host, headers, previous) {
  const now = new Date().toISOString()
  try {
    const [cpuBusy, mem, disk] = await Promise.all([
      queryCpuBusyPercent(fetchFn, host, headers, 'system.cpu'),
      queryPercent(fetchFn, host, headers, 'system.ram', 'used'),
      // Root filesystem chart id keeps the literal "/" -- confirmed
      // against a live vps00 node, not sanitized to "_" as guessed.
      queryPercent(fetchFn, host, headers, 'disk_space./', 'used'),
    ])
    return {
      up: true,
      cpu: round1(cpuBusy),
      mem: round1(mem),
      disk: round1(disk),
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
      lastPolled: now,
      lastSeen: previous?.lastSeen ?? null,
      error: err?.message ?? String(err),
    }
  }
}

async function pollDokploy(fetchFn, host, previous) {
  const now = new Date().toISOString()
  try {
    const res = await fetchWithTimeout(fetchFn, `https://${host}/`, { method: 'GET' })
    return { up: res.status < 500, lastPolled: now, lastSeen: now }
  } catch {
    return { up: false, lastPolled: now, lastSeen: previous?.lastSeen ?? null }
  }
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
  const dokploy = await pollDokploy(fetchFn, env.DOKPLOY_HOST, previousSnapshot?.dokploy)
  return { nodes, dokploy }
}
