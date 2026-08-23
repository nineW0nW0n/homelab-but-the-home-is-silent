#!/bin/sh
# Mechanical enforcement for the hard rails in .claude/CLAUDE.md. This repo's
# most-repeated failure is a rail that exists on paper with nothing running it
# (rail 5, rail 9, pre-commit itself, the CLAUDE.md budget check). Four rails
# are checkable from the files in this repo; this checks them.
#
# Never skips: a missing file or an empty glob is a failure, because a check
# that scans nothing is the exact bug this script exists to prevent.
#
# Usage: scripts/check-rails.sh   (no args; always checks the whole repo)

set -eu

cd "$(git rev-parse --show-toplevel)"

fail=0
err() {
  echo "FAIL $*" >&2
  fail=1
}

# --- rails 3 and 4: compose services -----------------------------------
# Rail 3: cloudflared without network_mode: host resolves localhost:PORT
# origin URLs inside its own netns, so every tunnel route 502s.
# Rail 4: docker compose up ignores deploy.resources, so a service capped
# that way is uncapped in reality -- on a 2GB node with no swap that is an
# OOM-killed node, not a slow one. Only mem_limit/mem_reservation count.
check_compose() {
  awk -v f="$1" '
    function check() {
      if (svc == "cloudflared" && !host)
        printf "FAIL %s:%d rail 3: service \"%s\" has no network_mode: host\n", f, line, svc > "/dev/stderr"
      if (dep)
        printf "FAIL %s:%d rail 4: service \"%s\" uses deploy: -- docker compose up ignores deploy.resources; use mem_limit/mem_reservation\n", f, line, svc > "/dev/stderr"
      if (!ml || !mr)
        printf "FAIL %s:%d rail 4: service \"%s\" is missing mem_limit and/or mem_reservation\n", f, line, svc > "/dev/stderr"
      if ((svc == "cloudflared" && !host) || dep || !ml || !mr) bad = 1
      n++
    }
    /^services:/ { in_s = 1; next }
    in_s && /^[A-Za-z_-]+:/ { if (svc != "") { check(); svc = "" } in_s = 0 }
    in_s && /^  [A-Za-z0-9_.-]+:[ \t]*$/ {
      if (svc != "") check()
      svc = $1; sub(/:$/, "", svc); line = NR; host = 0; ml = 0; mr = 0; dep = 0; next
    }
    svc != "" && /^    network_mode:[ \t]*host[ \t]*$/ { host = 1 }
    svc != "" && /^    mem_limit:[ \t]*[^ \t]/ { ml = 1 }
    svc != "" && /^    mem_reservation:[ \t]*[^ \t]/ { mr = 1 }
    svc != "" && /^    deploy:/ { dep = 1 }
    END {
      if (svc != "") check()
      if (n == 0) { printf "FAIL %s: no services found -- check scanned nothing\n", f > "/dev/stderr"; bad = 1 }
      exit bad
    }
  ' "$1" || fail=1
}

found=0
for f in stacks/*/docker-compose.yml; do
  [ -f "$f" ] || continue
  found=$((found + 1))
  check_compose "$f"
done
[ "$found" -ge 3 ] || err "found $found compose files under stacks/ -- expected one per node"

# --- rail 2: one tunnel token per node, never shared --------------------
# A shared token makes the two nodes one interchangeable connector pool, so
# requests land on the node that does not host the origin and 502.
tokens=""
for f in stacks/*/docker-compose.yml; do
  [ -f "$f" ] || continue
  # Anchored on ${...} so the tunnel names in the file headers' prose do not
  # count as references. ${X:-} and ${X} normalize to the same name.
  t=$(grep -oE '\$\{CLOUDFLARE_TUNNEL_TOKEN[A-Z0-9_]*[:}]' "$f" | sed 's/[:}]$/}/' | sort -u)
  [ -n "$t" ] || { err "$f rail 2: no \${CLOUDFLARE_TUNNEL_TOKEN...} reference"; continue; }
  tokens="$tokens$t
"
done
shared=$(printf '%s' "$tokens" | sort | uniq -d)
[ -z "$shared" ] || err "rail 2: tunnel token shared by more than one node: $shared"

# --- rail 7: one approval gates production ------------------------------
# A deploying job must either carry environment: production itself or need a
# job that does. ponytail: one level of needs, inline needs/environment only;
# anything else is reported as unsupported rather than silently passing.
for f in .github/workflows/*.yml; do
  [ -f "$f" ] || { err "no workflows found under .github/workflows/"; break; }
  awk -v f="$f" '
    /^jobs:/ { in_j = 1; next }
    in_j && /^[A-Za-z_-]+:/ { in_j = 0 }
    in_j && /^  [A-Za-z0-9_-]+:[ \t]*$/ { job = $1; sub(/:$/, "", job); line[job] = NR; next }
    job != "" && /^    environment:/ {
      if ($0 ~ /^    environment:[ \t]*production[ \t]*$/) env[job] = 1
      else { printf "FAIL %s:%d rail 7: job \"%s\" uses an environment: form this check cannot read\n", f, NR, job > "/dev/stderr"; bad = 1 }
    }
    job != "" && /^    needs:/ {
      n = $0; sub(/^    needs:[ \t]*/, "", n); gsub(/[][,]/, " ", n)
      if (n ~ /^[ \t]*$/) { printf "FAIL %s:%d rail 7: job \"%s\" uses a block-form needs: this check cannot read\n", f, NR, job > "/dev/stderr"; bad = 1 }
      needs[job] = n
    }
    job != "" && ($0 ~ /(^|[^a-zA-Z-])ssh / || $0 ~ /wrangler-action/ || $0 ~ /(^|[^a-zA-Z-])rsync /) { deploys[job] = 1 }
    END {
      for (j in deploys) {
        ok = env[j]
        if (!ok) { m = split(needs[j], a, /[ \t]+/); for (i = 1; i <= m; i++) if (env[a[i]]) ok = 1 }
        if (!ok) { printf "FAIL %s:%d rail 7: deploying job \"%s\" reaches no environment: production approval\n", f, line[j], j > "/dev/stderr"; bad = 1 }
      }
      exit bad
    }
  ' "$f" || fail=1
done

# --- rail 1 (partial): the enforcement still exists ---------------------
# UFW does not cover Docker-published ports, so rail 1 rests on two things in
# harden-node.sh. This only catches their deletion; it proves nothing about
# the running nodes.
h=scripts/harden-node.sh
if [ -f "$h" ]; then
  # -I specifically: the script's -D loop also ends in -j DROP, and a looser
  # pattern matched that instead, passing with the insert deleted.
  grep -qE '\-I DOCKER-USER .*-j DROP' "$h" || err "$h rail 1: DOCKER-USER drop rule is gone"
  grep -qF '"ip": "127.0.0.1"' "$h" || err "$h rail 1: daemon.json loopback bind (\"ip\": \"127.0.0.1\") is gone"
else
  err "$h rail 1: missing -- rail 1 has no enforcement at all"
fi

echo "rail 1: source-level only. Only an off-node port sweep proves the nodes"
echo "        are closed: nc -z -w 3 <ip> 22 80 443 2377 3000 5080 19999"
echo "        (no -G: BSD-only, Debian nc exits 1 without connecting)"

# --- Docker's journald log driver still set --------------------------------
# Not part of rail 1 above: vector.yaml (all nodes) reads container stdout
# from the journal, which is only true while setup-maintenance.sh sets the
# driver. Guarded like harden-node.sh: a missing file is a missing check.
m=scripts/setup-maintenance.sh
if [ -f "$m" ]; then
  grep -qF '"log-driver": "journald"' "$m" || err "$m: journald log driver is gone -- Vector would ship no container logs"
else
  err "$m: missing -- nothing sets Docker's journald log driver"
fi

# --- markup sinks in the public status page ----------------------------
# page.html is served to anonymous visitors and is a vendored copy of a
# designed front-end, re-copied by hand. It writes poll data with
# textContent and real elements, never innerHTML -- but nothing enforced
# that, while a comment in index.js claimed this grep already existed. It
# did not, for months. Now it does, and the claim is true.
#
# Not a general XSS scanner: the page takes no user input and reads no
# query params. This catches a re-copy that reintroduces a sink.
pg=worker/status/src/page.html
if [ -f "$pg" ]; then
  if grep -nE '\.(inner|outer)HTML|insertAdjacentHTML|document\.write|new Function' "$pg"; then
    err "$pg: markup sink in the public status page -- write with textContent"
  fi
else
  err "$pg: missing -- the markup-sink check scanned nothing"
fi

# --- vector.yaml: three copies, one file ------------------------------
# The shipper config is deployed per node (deploy.yml rsyncs one
# directory each) so it exists three times. Two copies do not stay equal
# (root CLAUDE.md failure log, the 2026-08-20 directory split), so this
# asserts they are byte-identical. Per-node differences belong in the
# compose environment, never in this file.
v0=stacks/vps00/vector.yaml
v1=stacks/vps01/vector.yaml
v2=stacks/vps02/vector.yaml
if [ -f "$v0" ] && [ -f "$v1" ] && [ -f "$v2" ]; then
  cmp -s "$v0" "$v2" || err "$v0 differs from $v2 -- vector.yaml must be identical on all nodes"
  cmp -s "$v1" "$v2" || err "$v1 differs from $v2 -- vector.yaml must be identical on all nodes"
else
  err "vector.yaml missing on a node -- expected $v0 $v1 $v2"
fi

[ "$fail" -eq 0 ] || { echo "check-rails: FAILED" >&2; exit 1; }
echo "check-rails: rails 1 (partial), 2, 3, 4, 7 + markup sinks OK across $found compose files"
