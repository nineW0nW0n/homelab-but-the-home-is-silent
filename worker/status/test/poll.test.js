import assert from 'node:assert/strict'
import { test } from 'node:test'
import { isFresh, pollAll } from '../src/poll.js'

function jsonResponse(labels, values, status = 200) {
  return new Response(JSON.stringify({ labels, data: [[0, ...values]] }), { status })
}

test('pollAll marks a node up with parsed cpu/mem/disk percentages', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
  }
  const fetchFn = async (url) => {
    // Shape confirmed against a live vps00 node: no "idle" dimension,
    // just the busy-state ones summing to the busy percentage.
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'system'], [10, 5])
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    if (url.includes('system.load'))
      return jsonResponse(['time', 'load1', 'load5', 'load15'], [0.5, 0.3, 0.2])
    if (url.includes('mem.swap')) return jsonResponse(['time', 'free', 'used'], [90, 10])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, true)
  assert.equal(snapshot.nodes.vps00.cpu, 15) // 10 + 5, summed busy dims
  assert.equal(snapshot.nodes.vps00.mem, 60)
  assert.equal(snapshot.nodes.vps00.disk, 30)
  // load1 0.5 / 2 vCPUs * 100 = 25
  assert.equal(snapshot.nodes.vps00.load, 25)
  assert.equal(snapshot.nodes.vps00.swap, 10)
})

test('pollAll marks a node down on fetch failure, without throwing', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps01-metrics.maybeit.work',
  }
  const fetchFn = async () => {
    throw new Error('network error')
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps01.up, false)
  assert.ok(snapshot.nodes.vps01.lastPolled)
  // first-ever poll, no previous snapshot to carry a lastSeen forward from
  assert.equal(snapshot.nodes.vps01.lastSeen, null)
})

test('pollAll carries the previous lastSeen forward when a node fails after being up before', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps01-metrics.maybeit.work',
  }
  const fetchFn = async () => {
    throw new Error('network error')
  }
  const previousSnapshot = {
    nodes: { vps01: { up: true, lastSeen: '2026-08-01T00:00:00.000Z' } },
  }
  const snapshot = await pollAll(env, fetchFn, previousSnapshot)
  assert.equal(snapshot.nodes.vps01.up, false)
  assert.equal(snapshot.nodes.vps01.lastSeen, '2026-08-01T00:00:00.000Z')
  assert.notEqual(snapshot.nodes.vps01.lastPolled, snapshot.nodes.vps01.lastSeen)
})

test('pollAll fails a node closed when a Netdata dimension value is non-numeric', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'system'], [15, null])
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, false)
})

test('pollAll clamps load to 100 when load1 exceeds vCPU count', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'system'], [10, 5])
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    // load1 of 5 on a 2 vCPU box is 250% raw -- must clamp to 100
    if (url.includes('system.load'))
      return jsonResponse(['time', 'load1', 'load5', 'load15'], [5, 3, 2])
    if (url.includes('mem.swap')) return jsonResponse(['time', 'free', 'used'], [90, 10])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.load, 100)
})

test('isFresh: missing, stale, and future-stamped snapshots all poll again', async () => {
  const now = Date.parse('2026-08-16T12:00:00.000Z')
  assert.equal(isFresh(null, now), false)
  assert.equal(isFresh({}, now), false)
  assert.equal(isFresh({ polledAt: 'not-a-date' }, now), false)
  assert.equal(isFresh({ polledAt: '2026-08-16T11:59:00.000Z' }, now), false)
  // Clock skew: a snapshot from the future is not "fresh", it's wrong.
  assert.equal(isFresh({ polledAt: '2026-08-16T12:05:00.000Z' }, now), false)
})

test('isFresh: a snapshot inside the TTL is served without re-polling', async () => {
  const now = Date.parse('2026-08-16T12:00:00.000Z')
  assert.equal(isFresh({ polledAt: '2026-08-16T11:59:59.000Z' }, now), true)
  assert.equal(isFresh({ polledAt: '2026-08-16T12:00:00.000Z' }, now), true)
  // Exactly at the TTL boundary is stale, not fresh.
  assert.equal(isFresh({ polledAt: '2026-08-16T11:59:30.000Z' }, now), false)
})

test('pollAll stamps a top-level polledAt the freshness check can use', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: '',
  }
  const fetchFn = async () => new Response('', { status: 200 })
  const snapshot = await pollAll(env, fetchFn)
  assert.ok(snapshot.polledAt, 'snapshot has polledAt')
  assert.equal(isFresh(snapshot), true)
})

test('pollAll never requests the Dokploy host, so the Access token cannot reach it', async () => {
  // Regression guard for the 2026-08-20 removal. The Worker is public and its
  // Access service token opens the deploy control plane; polling Dokploy put
  // that credential on the wire for an up/down boolean only /debug ever showed.
  // DOKPLOY_HOST is still set here deliberately -- a stale var must not be
  // enough to bring the behaviour back.
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const requested = []
  const fetchFn = async (url) => {
    requested.push(url)
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.ok(requested.length > 0, 'the node was actually polled')
  assert.ok(
    requested.every((url) => url.includes('vps00-metrics.maybeit.work')),
    `unexpected host polled: ${requested.find((u) => !u.includes('vps00-metrics.maybeit.work'))}`,
  )
  assert.equal(snapshot.dokploy, undefined)
})

test('pollAll marks a node down when Netdata answers non-2xx', async () => {
  const env = { NODE_HOSTS: 'vps00-metrics.maybeit.work' }
  const snapshot = await pollAll(env, async () => jsonResponse(['cpu'], [10], 503))
  assert.equal(snapshot.nodes.vps00.up, false)
})

test('pollAll marks a node down on malformed upstream JSON', async () => {
  const env = { NODE_HOSTS: 'vps00-metrics.maybeit.work' }
  const snapshot = await pollAll(env, async () => new Response('not json', { status: 200 }))
  assert.equal(snapshot.nodes.vps00.up, false)
})
