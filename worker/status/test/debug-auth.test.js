import assert from 'node:assert/strict'
import { test } from 'node:test'
import { isDebugAuthorized } from '../src/debug-auth.js'

function req(headers = {}) {
  return new Request('https://maybeit.work/debug', { headers })
}

test('isDebugAuthorized fails closed when DEBUG_KEY is unset', async () => {
  // The state of a fresh deploy or a rolled-back secret. Must deny, not
  // allow -- an unset secret must never mean "no check".
  assert.equal(isDebugAuthorized(req({ 'x-debug-key': 'anything' }), {}), false)
  assert.equal(isDebugAuthorized(req({ 'x-debug-key': '' }), { DEBUG_KEY: '' }), false)
  assert.equal(isDebugAuthorized(req(), {}), false)
})

test('isDebugAuthorized rejects a missing, wrong, or truncated key', async () => {
  const env = { DEBUG_KEY: 'correct-horse-battery-staple' }
  assert.equal(isDebugAuthorized(req(), env), false)
  assert.equal(isDebugAuthorized(req({ 'x-debug-key': 'wrong' }), env), false)
  assert.equal(isDebugAuthorized(req({ 'x-debug-key': 'correct-horse-battery' }), env), false)
  assert.equal(isDebugAuthorized(req({ 'x-debug-key': 'correct-horse-battery-stapl' }), env), false)
  // A prefix that matches but runs long must not pass either.
  assert.equal(
    isDebugAuthorized(req({ 'x-debug-key': 'correct-horse-battery-staple!' }), env),
    false,
  )
})

test('isDebugAuthorized accepts the exact key', async () => {
  const env = { DEBUG_KEY: 'correct-horse-battery-staple' }
  assert.equal(isDebugAuthorized(req({ 'x-debug-key': 'correct-horse-battery-staple' }), env), true)
})
