import { pollAll } from './poll.js'
import { renderStatusPage } from './render.js'

const SNAPSHOT_KEY = 'snapshot'

async function runPoll(env) {
  const previousSnapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
  const snapshot = await pollAll(env, fetch, previousSnapshot)
  await env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(snapshot))
  return snapshot
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url)
    // Raw snapshot (includes per-node `error` on down nodes) -- not
    // linked from the page, just a diagnostic escape hatch.
    if (pathname === '/debug') {
      return Response.json(await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' }))
    }
    // The actual poll, run inside a fetch() invocation -- see the
    // comment on scheduled() below for why it can't run there directly.
    if (pathname === '/__poll') {
      return Response.json(await runPoll(env))
    }
    const snapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    return new Response(renderStatusPage(snapshot), {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  },

  // Confirmed 2026-08-16: Netdata calls made directly from inside
  // scheduled() get a 403 from Cloudflare Access on this account, even
  // with a verified-working CF-Access-Client-Id/Secret -- the exact
  // same pollAll() call succeeds every time when it instead runs inside
  // a fetch() invocation. Cron Trigger subrequests to this account's own
  // Access-protected apps appear to hit Access differently than a normal
  // HTTP-triggered subrequest does. Working around it by having the cron
  // trigger a self-fetch to /__poll, so the actual Netdata calls always
  // run inside a fetch() handler.
  async scheduled(_event, env) {
    await fetch('https://maybeit.work/__poll')
  },
}
