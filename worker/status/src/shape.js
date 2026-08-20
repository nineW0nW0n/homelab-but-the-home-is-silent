// /status.json contract, v2 (2026-08-21). The page accepts this object and
// the old bare array; this Worker only emits the object.
//   { polledAt: ISO|null, nodes: [{ name, up, lastSeen: ISO|null, load, cpu, mem, swap, disk }] }
// Ordered from NODE_HOSTS, never from Object.entries(snapshot.nodes) --
// pollAll fills that object from concurrent promises. A host absent from the
// snapshot is reported down rather than dropped, so the page's slots stay
// aligned by index. `error` stays on /debug only.
const DOWN = { up: false, lastSeen: null, load: 0, cpu: 0, mem: 0, swap: 0, disk: 0 }

export function toStatusJson(snapshot, nodeHosts) {
  return {
    polledAt: snapshot?.polledAt ?? null,
    nodes: nodeHosts.map((host) => {
      const name = host.split('-metrics.')[0]
      const n = snapshot?.nodes?.[name] ?? DOWN
      return {
        name: name.toUpperCase(),
        up: n.up === true,
        lastSeen: n.lastSeen ?? null,
        load: n.load,
        cpu: n.cpu,
        mem: n.mem,
        swap: n.swap,
        disk: n.disk,
      }
    }),
  }
}
