import { isDebugAuthorized } from './debug-auth.js'
import page from './page.html'
import { isFresh, POLL_TTL_MS, pollAll } from './poll.js'
import { toStatusJson } from './status-json.js'

const SNAPSHOT_KEY = 'snapshot'

// Defense in depth, not a fix for a live XSS: page.html takes no user
// input and writes data with textContent and real elements, never
// innerHTML. Enforced by scripts/check-rails.sh, which greps this repo's
// page.html for markup sinks -- true since 2026-08-20. It was NOT true
// when this comment first claimed it: the script did not exist, and the
// claim sat here unchallenged for months. Verify a named check exists
// before citing it.
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
  // The page is a static vendored file that only changes on deploy, so a
  // browser refresh has no reason to re-invoke the Worker for it.
  'cache-control': 'public, max-age=300',
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
    // internals, HTTP status codes). No secrets, but it is a recon aid, so
    // it takes a shared header.
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
    //
    // max-age matches POLL_TTL_MS: the data genuinely cannot change more
    // often than that, and without it every refresh of a public page is a
    // Worker invocation plus a KV read. That is a free-tier quota someone
    // can exhaust by holding down F5 -- the nodes themselves are already
    // shielded by the poll TTL, this protects the Worker.
    const JSON_HEADERS = {
      'x-content-type-options': 'nosniff',
      'cache-control': `public, max-age=${Math.floor(POLL_TTL_MS / 1000)}`,
    }
    // Raw snapshot (includes per-node `error` on down nodes) -- not linked
    // from the page, just a diagnostic escape hatch.
    if (pathname === '/debug') {
      // Never cached: it is gated by a shared key, and a cached copy could
      // outlive a rotated key or be served to the wrong client.
      return Response.json(snapshot, {
        headers: { ...JSON_HEADERS, 'cache-control': 'no-store' },
      })
    }
    const nodeHosts = env.NODE_HOSTS ? env.NODE_HOSTS.split(',') : []
    return Response.json(toStatusJson(snapshot, nodeHosts), { headers: JSON_HEADERS })
  },
}
