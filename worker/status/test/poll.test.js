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
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'idle'], [15, 85])
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    if (url.includes('system.load'))
      return jsonResponse(['time', 'load1', 'load5', 'load15'], [0.5, 0.3, 0.2])
    if (url.includes('mem.swap')) return jsonResponse(['time', 'free', 'used'], [90, 10])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, true)
  assert.equal(snapshot.nodes.vps00.cpu, 15)
  assert.equal(snapshot.nodes.vps00.mem, 60)
  assert.equal(snapshot.nodes.vps00.disk, 30)
  // load1 0.5 / 2 vCPUs * 100 = 25
  assert.equal(snapshot.nodes.vps00.load, 25)
  assert.equal(snapshot.nodes.vps00.swap, 10)
  assert.equal(snapshot.dokploy.up, true)
})

test('pollAll marks a node down on fetch failure, without throwing', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps01-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('dokploy')) return new Response('', { status: 200 })
    throw new Error('network error')
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps01.up, false)
  assert.ok(snapshot.nodes.vps01.lastPolled)
  // first-ever poll, no previous snapshot to carry a lastSeen forward from
  assert.equal(snapshot.nodes.vps01.lastSeen, null)
  assert.equal(snapshot.dokploy.up, true)
})

test('pollAll carries the previous lastSeen forward when a node fails after being up before', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps01-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async () => {
    throw new Error('network error')
  }
  const previousSnapshot = {
    nodes: { vps01: { up: true, lastSeen: '2026-08-01T00:00:00.000Z' } },
    dokploy: { up: false, lastSeen: '2026-07-30T00:00:00.000Z' },
  }
  const snapshot = await pollAll(env, fetchFn, previousSnapshot)
  assert.equal(snapshot.nodes.vps01.up, false)
  assert.equal(snapshot.nodes.vps01.lastSeen, '2026-08-01T00:00:00.000Z')
  assert.notEqual(snapshot.nodes.vps01.lastPolled, snapshot.nodes.vps01.lastSeen)
  assert.equal(snapshot.dokploy.up, false)
  assert.equal(snapshot.dokploy.lastSeen, '2026-07-30T00:00:00.000Z')
})

test('pollAll fails a node closed when a Netdata dimension value is non-numeric', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'idle'], [15, null])
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, false)
})

test('pollAll sums busy-state dimensions when Netdata reports no idle dimension', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    // Shape confirmed against a live vps00 node: no "idle" dimension,
    // just the busy-state ones summing to the busy percentage.
    if (url.includes('system.cpu')) {
      return jsonResponse(['time', 'user', 'system', 'iowait'], [10, 5, 2])
    }
    if (url.includes('system.ram')) return jsonResponse(['time', 'free', 'used'], [40, 60])
    if (url.includes('disk_space')) return jsonResponse(['time', 'avail', 'used'], [70, 30])
    if (url.includes('system.load'))
      return jsonResponse(['time', 'load1', 'load5', 'load15'], [0.5, 0.3, 0.2])
    if (url.includes('mem.swap')) return jsonResponse(['time', 'free', 'used'], [90, 10])
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, true)
  assert.equal(snapshot.nodes.vps00.cpu, 17)
})

test('pollAll clamps load to 100 when load1 exceeds vCPU count', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: 'vps00-metrics.maybeit.work',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async (url) => {
    if (url.includes('system.cpu')) return jsonResponse(['time', 'user', 'idle'], [15, 85])
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

test('pollAll marks dokploy down on a 5xx response', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: '',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async () => new Response('', { status: 502 })
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.dokploy.up, false)
})

test('pollAll marks dokploy down on an Access login redirect', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: '',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  // Without redirect:manual the runtime follows this to a 200 login
  // page and the check silently reports Access, not Dokploy.
  const fetchFn = async () =>
    new Response('', {
      status: 302,
      headers: { location: 'https://old-firefly-996b.cloudflareaccess.com/' },
    })
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.dokploy.up, false)
})

test('pollAll sends the Access service token to dokploy', async () => {
  const env = {
    CF_ACCESS_CLIENT_ID: 'id',
    CF_ACCESS_CLIENT_SECRET: 'secret',
    NODE_HOSTS: '',
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  let seen = null
  const fetchFn = async (_url, options) => {
    seen = options
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.dokploy.up, true)
  assert.equal(seen.headers['CF-Access-Client-Id'], 'id')
  assert.equal(seen.headers['CF-Access-Client-Secret'], 'secret')
  assert.equal(seen.redirect, 'manual')
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
    DOKPLOY_HOST: 'dokploy.maybeit.work',
  }
  const fetchFn = async () => new Response('', { status: 200 })
  const snapshot = await pollAll(env, fetchFn)
  assert.ok(snapshot.polledAt, 'snapshot has polledAt')
  assert.equal(isFresh(snapshot), true)
})
