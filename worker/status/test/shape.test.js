import assert from 'node:assert/strict'
import { test } from 'node:test'
import { toStatusJson } from '../src/shape.js'

const hosts = ['vps00-metrics.maybeit.work', 'vps01-metrics.maybeit.work']
const snapshot = {
  polledAt: '2026-08-21T10:00:00.000Z',
  nodes: {
    vps01: {
      up: false,
      cpu: 0,
      mem: 0,
      disk: 0,
      load: 0,
      swap: 0,
      lastPolled: '2026-08-21T10:00:00.000Z',
      lastSeen: '2026-08-20T22:14:03.000Z',
      error: 'netdata 530',
    },
    vps00: {
      up: true,
      cpu: 1.2,
      mem: 61.6,
      disk: 18.2,
      load: 0.5,
      swap: 0.9,
      lastPolled: '2026-08-21T10:00:00.000Z',
      lastSeen: '2026-08-21T10:00:00.000Z',
    },
  },
}

test('object shape, NODE_HOSTS order, no error field', () => {
  const out = toStatusJson(snapshot, hosts)
  assert.equal(out.polledAt, '2026-08-21T10:00:00.000Z')
  assert.deepEqual(
    out.nodes.map((n) => n.name),
    ['VPS00', 'VPS01'],
  )
  assert.deepEqual(out.nodes[1], {
    name: 'VPS01',
    up: false,
    lastSeen: '2026-08-20T22:14:03.000Z',
    load: 0,
    cpu: 0,
    mem: 0,
    swap: 0,
    disk: 0,
  })
  assert.equal('error' in out.nodes[1], false)
})

test('a host missing from the snapshot reports down, never throws', () => {
  const out = toStatusJson({ polledAt: snapshot.polledAt, nodes: {} }, hosts)
  assert.equal(out.nodes[0].up, false)
  assert.equal(out.nodes[0].lastSeen, null)
})

test('no snapshot at all', () => {
  const out = toStatusJson(null, hosts)
  assert.equal(out.polledAt, null)
  assert.equal(out.nodes.length, 2)
  assert.equal(out.nodes[0].up, false)
})
