// Authorization for the /debug route. Its own module, not index.js, so
// it is testable under `node --test` -- index.js imports page.html via a
// Wrangler Text module rule, which plain Node cannot resolve.

// Constant-time-ish comparison. Not a strong guarantee in a JS runtime,
// but it avoids the trivially timeable early-exit of === on strings and
// costs one small function. Kept hand-rolled on purpose:
// crypto.subtle.timingSafeEqual is a workerd extension absent from plain
// Node's webcrypto, and this module's tests run under `node --test`.
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

// Fails closed: with DEBUG_KEY unset the route is denied to everyone
// rather than open to everyone. That matters because an unset secret is
// the normal state of a fresh deploy or a rolled-back secret.
export function isDebugAuthorized(request, env) {
  if (!env?.DEBUG_KEY) return false
  return safeEqual(request.headers.get('x-debug-key') ?? '', env.DEBUG_KEY)
}
