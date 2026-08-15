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
    return {
      up: true,
      cpu: round1(100 - idle),
      mem: round1(mem),
      disk: round1(disk),
      lastSeen: now,
    }
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
