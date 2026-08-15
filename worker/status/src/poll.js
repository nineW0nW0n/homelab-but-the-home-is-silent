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

async function pollNode(fetchFn, host, headers, previous) {
  const now = new Date().toISOString()
  try {
    // PROVISIONAL: these chart/dimension names are unverified guesses --
    // never confirmed against a real Netdata instance. Confirm against
    // a live node's /api/v1/charts response before or shortly after
    // first production deploy (see worker/status/CLAUDE.md).
    const [idle, mem, disk] = await Promise.all([
      queryPercent(fetchFn, host, headers, 'system.cpu', 'idle'),
      queryPercent(fetchFn, host, headers, 'system.ram', 'used'),
      queryPercent(fetchFn, host, headers, 'disk_space._', 'used'),
    ])
    return {
      up: true,
      cpu: round1(100 - idle),
      mem: round1(mem),
      disk: round1(disk),
      lastPolled: now,
      lastSeen: now,
    }
  } catch {
    // lastPolled is always "now" -- honest "last time we checked".
    // lastSeen carries forward the previous snapshot's lastSeen (last
    // time this node was confirmed up), or null on a node's first-ever
    // poll with no prior snapshot to carry forward from.
    return {
      up: false,
      cpu: 0,
      mem: 0,
      disk: 0,
      lastPolled: now,
      lastSeen: previous?.lastSeen ?? null,
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
