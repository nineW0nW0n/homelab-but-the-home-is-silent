import page from './page.html'
import { pollAll } from './poll.js'

const SNAPSHOT_KEY = 'snapshot'

// Page's own DATA CONTRACT (see src/page.html): array of up to 3
// { name, load, cpu, mem, swap, disk }, raw 0-100 percents. No dokploy --
// the page hardcodes exactly 3 status-dot slots, mapped by ARRAY INDEX,
// not by name. Order must come from NODE_HOSTS, not Object.entries(nodes)
// -- pollAll fills that object from concurrent promises, so insertion
// order isn't guaranteed to match NODE_HOSTS's order.
function toStatusJson(snapshot, nodeHosts) {
  return nodeHosts.map((host) => {
    const name = host.split('-metrics.')[0]
    const n = snapshot.nodes[name]
    return {
      name: name.toUpperCase(),
      load: n.load,
      cpu: n.cpu,
      mem: n.mem,
      swap: n.swap,
      disk: n.disk,
    }
  })
}

// No Cron Trigger: cron-triggered subrequests to this account's own
// Access-protected Netdata apps get a 403 from Cloudflare Access, even
// with a verified-working CF-Access-Client-Id/Secret (confirmed
// 2026-08-16, see worker/status/CLAUDE.md). Polling once per page load
// instead sidesteps that entirely -- it always runs inside a real
// fetch() invocation, which works every time.
export default {
  async fetch(request, env) {
    const previousSnapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    const snapshot = await pollAll(env, fetch, previousSnapshot)
    await env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(snapshot))
    const pathname = new URL(request.url).pathname
    // Raw snapshot (includes dokploy + per-node `error` on down nodes) --
    // not linked from the page, just a diagnostic escape hatch.
    if (pathname === '/debug') {
      return Response.json(snapshot)
    }
    if (pathname === '/status.json') {
      const nodeHosts = env.NODE_HOSTS ? env.NODE_HOSTS.split(',') : []
      return Response.json(toStatusJson(snapshot, nodeHosts))
    }
    return new Response(page, {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  },
}
