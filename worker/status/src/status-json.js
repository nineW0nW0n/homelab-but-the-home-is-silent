// Page's own DATA CONTRACT (see src/page.html): array of up to 3
// { name, load, cpu, mem, swap, disk }, raw 0-100 percents --
// the page hardcodes exactly 3 status-dot slots, mapped by ARRAY INDEX,
// not by name. Order must come from NODE_HOSTS, not Object.entries(nodes)
// -- pollAll fills that object from concurrent promises, so insertion
// order isn't guaranteed to match NODE_HOSTS's order.
export function toStatusJson(snapshot, nodeHosts) {
  return nodeHosts.flatMap((host) => {
    const name = host.split('-metrics.')[0]
    const n = snapshot.nodes[name]
    // A host in NODE_HOSTS but absent from the snapshot (stale KV after a
    // NODE_HOSTS change) is omitted, not zero-filled: n.load would throw and
    // 500 the whole endpoint, and zeros would render as a healthy node.
    if (!n) return []
    return [
      {
        name: name.toUpperCase(),
        load: n.load,
        cpu: n.cpu,
        mem: n.mem,
        swap: n.swap,
        disk: n.disk,
      },
    ]
  })
}
