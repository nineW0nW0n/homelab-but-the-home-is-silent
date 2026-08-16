import assert from 'node:assert/strict'
import { test } from 'node:test'
import { renderStatusPage } from '../src/render.js'

test('renders "no data yet" when snapshot is null', () => {
  const html = renderStatusPage(null)
  assert.match(html, /No data yet/)
})

test('renders green light and utilization for an up node', () => {
  const html = renderStatusPage({
    nodes: {
      vps00: { up: true, cpu: 12.3, mem: 45.6, disk: 30.1, lastSeen: '2026-08-15T00:00:00Z' },
    },
    dokploy: { up: true, lastSeen: '2026-08-15T00:00:00Z' },
  })
  assert.match(html, /🟢 vps00/)
  assert.match(html, /12\.3%/)
})

test('renders red light for a down node', () => {
  const html = renderStatusPage({
    nodes: { vps01: { up: false, cpu: 0, mem: 0, disk: 0, lastSeen: '2026-08-15T00:00:00Z' } },
    dokploy: { up: true, lastSeen: '2026-08-15T00:00:00Z' },
  })
  assert.match(html, /🔴 vps01/)
})

test('renders a dokploy row', () => {
  const html = renderStatusPage({
    nodes: {},
    dokploy: { up: false, lastSeen: '2026-08-15T00:00:00Z' },
  })
  assert.match(html, /🔴 dokploy/)
})
