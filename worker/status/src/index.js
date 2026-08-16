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
    // On-demand live probe, bypasses waiting for the next cron tick.
    if (new URL(request.url).pathname === '/debug/probe') {
      const res = await fetch('https://vps00-metrics.maybeit.work/api/v1/charts', {
        headers: {
          'CF-Access-Client-Id': env.CF_ACCESS_CLIENT_ID,
          'CF-Access-Client-Secret': env.CF_ACCESS_CLIENT_SECRET,
        },
      })
      const body = await res.text()
      return Response.json({
        status: res.status,
        idPresent: Boolean(env.CF_ACCESS_CLIENT_ID),
        idLen: env.CF_ACCESS_CLIENT_ID?.length,
        secretLen: env.CF_ACCESS_CLIENT_SECRET?.length,
        bodySnippet: body.slice(0, 300),
      })
    }
    // Runs the exact scheduled()-handler poll path on demand, isolating
    // whether failures are specific to the scheduled trigger context.
    if (new URL(request.url).pathname === '/debug/pollnow') {
      const previousSnapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
      const fresh = await pollAll(env, fetch, previousSnapshot)
      await env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(fresh))
      return Response.json(fresh)
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
