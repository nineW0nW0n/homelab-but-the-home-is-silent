import assert from 'node:assert/strict'
import { test } from 'node:test'
import { pollAll } from '../src/poll.js'

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
    return new Response('', { status: 200 })
  }
  const snapshot = await pollAll(env, fetchFn)
  assert.equal(snapshot.nodes.vps00.up, true)
  assert.equal(snapshot.nodes.vps00.cpu, 15)
  assert.equal(snapshot.nodes.vps00.mem, 60)
  assert.equal(snapshot.nodes.vps00.disk, 30)
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
