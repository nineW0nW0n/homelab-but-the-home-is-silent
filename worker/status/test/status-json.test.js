import assert from 'node:assert/strict'
import { test } from 'node:test'
import { toStatusJson } from '../src/status-json.js'

const metrics = { load: 10, cpu: 20, mem: 30, swap: 0, disk: 40 }

test('toStatusJson maps each host to its snapshot entry', () => {
  const snapshot = { nodes: { vps00: metrics, vps01: metrics } }
  const out = toStatusJson(snapshot, ['vps00-metrics.maybeit.work', 'vps01-metrics.maybeit.work'])
  assert.deepEqual(
    out.map((s) => s.name),
    ['VPS00', 'VPS01'],
  )
  assert.equal(out[0].disk, 40)
})

// Regression: toStatusJson read n.load off a missing node and threw, taking
// /status.json to a 500. Omitting is the fix -- zeros would render as healthy.
test('toStatusJson omits a host missing from the snapshot instead of throwing', () => {
  const snapshot = { nodes: { vps00: metrics } }
  const out = toStatusJson(snapshot, ['vps00-metrics.maybeit.work', 'vps99-metrics.maybeit.work'])
  assert.deepEqual(
    out.map((s) => s.name),
    ['VPS00'],
  )
})

test('toStatusJson returns an empty array when the snapshot has no nodes', () => {
  assert.deepEqual(toStatusJson({ nodes: {} }, ['vps00-metrics.maybeit.work']), [])
})
