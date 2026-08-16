import { isDebugAuthorized } from './debug-auth.js'
import page from './page.html'
import { isFresh, pollAll } from './poll.js'

const SNAPSHOT_KEY = 'snapshot'

// Defense in depth, not a fix for a live XSS: page.html takes no user
// input and writes data with textContent and real elements, never
// innerHTML. That is enforced upstream by the site repo's
// scripts/check-rails.sh, not by convention -- this comment was silently
// false for a while before that grep existed.
//
// 'unsafe-inline' is required for both script and style: page.html is a
// vendored copy of the designed front-end with two inline <script> blocks
// and one inline <style>, and there is no build step to hash them. Hashes
// would be stricter but would silently break the page every time the
// vendored file is re-copied, which is the worse failure. Fonts are
// data: URIs, already inlined, so no external origin is needed anywhere.
//
// HSTS is deliberately absent -- Cloudflare terminates TLS and should set
// it at the edge, not this Worker.
const PAGE_HEADERS = {
  'content-type': 'text/html; charset=utf-8',
  'content-security-policy': [
    "default-src 'none'",
    "script-src 'self' 'unsafe-inline'",
    "style-src 'self' 'unsafe-inline'",
    'font-src data:',
    "img-src 'self' data:",
    "connect-src 'self'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "form-action 'none'",
  ].join('; '),
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
}

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
  async fetch(request, env, ctx) {
    const pathname = new URL(request.url).pathname

    // The HTML shell needs no data at all -- the page fetches
    // /status.json itself on load. Serving `/`, /favicon.ico and every
    // 404 path used to poll all three nodes and write KV first.
    if (pathname !== '/status.json' && pathname !== '/debug') {
      return new Response(page, { headers: PAGE_HEADERS })
    }

    // /debug returns the raw snapshot: per-node error strings (Netdata
    // internals, HTTP status codes) and Dokploy reachability. No secrets,
    // but it is a recon aid, so it takes a shared header.
    //
    // Fails closed: if DEBUG_KEY is unset the route is 404 for everyone,
    // rather than open to everyone. 404 rather than 403 on a bad key too
    // -- do not confirm the route exists.
    if (pathname === '/debug' && !isDebugAuthorized(request, env)) {
      return new Response('not found', { status: 404 })
    }

    const previousSnapshot = await env.STATUS_KV.get(SNAPSHOT_KEY, { type: 'json' })
    let snapshot = previousSnapshot
    if (!isFresh(previousSnapshot)) {
      snapshot = await pollAll(env, fetch, previousSnapshot)
      // waitUntil so the response isn't blocked on the KV write. The
      // previous snapshot still threads through pollAll -- pollNode needs
      // it to carry lastSeen forward on a node that's currently down.
      ctx.waitUntil(env.STATUS_KV.put(SNAPSHOT_KEY, JSON.stringify(snapshot)))
    }

    // nosniff on the JSON routes too, not just the page. Without it a
    // browser is free to content-sniff a response body; the page headers
    // already carry it, these did not.
    const JSON_HEADERS = { 'x-content-type-options': 'nosniff' }
    // Raw snapshot (includes dokploy + per-node `error` on down nodes) --
    // not linked from the page, just a diagnostic escape hatch.
    if (pathname === '/debug') {
      return Response.json(snapshot, { headers: JSON_HEADERS })
    }
    const nodeHosts = env.NODE_HOSTS ? env.NODE_HOSTS.split(',') : []
    return Response.json(toStatusJson(snapshot, nodeHosts), { headers: JSON_HEADERS })
  },
}
