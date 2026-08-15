import { pollAll } from './poll.js'
import { renderStatusPage } from './render.js'

const SNAPSHOT_KEY = 'snapshot'

export default {
  async fetch(_request, env) {
    const snapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
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
