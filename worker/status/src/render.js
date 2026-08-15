// Pure function: status snapshot -> HTML status page. No fetch, no KV --
// keeps this testable without touching the Workers runtime.

function light(up) {
  return up ? '🟢' : '🔴'
}

function bar(pct) {
  const clamped = Math.max(0, Math.min(100, pct))
  return `<div class="bar"><div class="bar-fill" style="width:${clamped}%"></div><span>${clamped.toFixed(1)}%</span></div>`
}

// lastSeen is "last time this node was confirmed up" -- null on a
// node's first-ever poll if it's never come back up. "never" reads
// better than the literal string "null".
function seen(lastSeen) {
  return lastSeen ?? 'never'
}

function renderShell(body) {
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>maybeit.work status</title>
<style>
  body { font-family: system-ui, sans-serif; background:#111; color:#eee; padding:2rem; }
  table { border-collapse: collapse; width:100%; max-width:640px; }
  td, th { padding:.5rem; text-align:left; border-bottom:1px solid #333; }
  .bar { position:relative; background:#333; border-radius:4px; width:120px; height:1rem; }
  .bar-fill { position:absolute; inset:0; background:#3b82f6; border-radius:4px; }
  .bar span { position:relative; z-index:1; font-size:.7rem; padding-left:4px; }
</style></head>
<body><h1>maybeit.work status</h1>${body}</body></html>`
}

export function renderStatusPage(snapshot) {
  if (!snapshot) {
    return renderShell('<p>No data yet.</p>')
  }

  const nodeRows = Object.entries(snapshot.nodes)
    .map(
      ([name, n]) => `
      <tr>
        <td>${light(n.up)} ${name}</td>
        <td>${bar(n.cpu)}</td>
        <td>${bar(n.mem)}</td>
        <td>${bar(n.disk)}</td>
        <td>${seen(n.lastSeen)}</td>
      </tr>`,
    )
    .join('')

  const dokployRow = `
    <tr>
      <td>${light(snapshot.dokploy.up)} dokploy</td>
      <td colspan="3">control plane</td>
      <td>${seen(snapshot.dokploy.lastSeen)}</td>
    </tr>`

  return renderShell(`
    <table>
      <thead><tr><th>node</th><th>cpu</th><th>mem</th><th>disk</th><th>last seen</th></tr></thead>
      <tbody>${nodeRows}${dokployRow}</tbody>
    </table>`)
}
