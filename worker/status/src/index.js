import page from './page.html'
import privacy from './privacy.html'
import terms from './terms.html'

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
// connect-src 'self' stays even with the poller gone: the vendored page
// still fires its one GET /status.json on load, and blocking it at CSP
// would turn a designed, silent fallback into a console error.
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

// The poller retired 2026-09-03 (phoenixlab step 17, section 0): Netdata's
// replacement is the Beszel hub, which is private, so this Worker no
// longer polls anything, reads no KV, and holds no secrets. /status.json
// and /debug are gone with it.
//
// What the page shows with no data is deliberate, not accidental:
// /status.json now falls through to the HTML shell below, the page's own
// DATA CONTRACT (src/page.html) swallows the JSON parse failure silently,
// and its hardcoded SERVICES fallback stands. Every fallback value
// quantizes into the page's green 1-7 band, so no node ever renders as
// down -- unlike the poller's fail-closed zeros, which rendered all three
// dead the moment the origins went away. The fallback path is the one
// visitors already hit whenever the old poll missed its 800ms budget.
export default {
  async fetch(request) {
    const pathname = new URL(request.url).pathname

    // Google's OAuth consent screen requires a reachable privacy policy
    // and terms of service before an app can leave Testing status, and
    // the zone-wide "Block non-local traffic" rule exempts only the apex
    // -- so they have to be served from here, not from gws.maybeit.work.
    // Static text, no data, same headers as the page.
    if (pathname === '/privacy') {
      return new Response(privacy, { headers: PAGE_HEADERS })
    }
    if (pathname === '/terms') {
      return new Response(terms, { headers: PAGE_HEADERS })
    }

    return new Response(page, { headers: PAGE_HEADERS })
  },
}
