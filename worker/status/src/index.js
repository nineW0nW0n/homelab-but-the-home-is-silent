import { pollAll } from './poll.js'
import { renderStatusPage } from './render.js'

const SNAPSHOT_KEY = 'snapshot'

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
    // Raw snapshot (includes per-node `error` on down nodes) -- not
    // linked from the page, just a diagnostic escape hatch.
    if (new URL(request.url).pathname === '/debug') {
      return Response.json(snapshot)
    }
    return new Response(renderStatusPage(snapshot), {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  },
}
