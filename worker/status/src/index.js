import { pollAll } from './poll.js'
import { renderStatusPage } from './render.js'

const SNAPSHOT_KEY = 'snapshot'

export default {
  async fetch(request, env) {
    const snapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    // Raw snapshot (includes per-node `error` on down nodes) -- not
    // linked from the page, just a diagnostic escape hatch.
    if (new URL(request.url).pathname === '/debug') {
      return Response.json(snapshot)
    }
    return new Response(renderStatusPage(snapshot), {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  },

  async scheduled(_event, env) {
    const previousSnapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    const snapshot = await pollAll(env, fetch, previousSnapshot)
    await env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(snapshot))
  },
}
