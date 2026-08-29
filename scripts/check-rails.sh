#!/bin/sh
# Mechanical enforcement for the hard rails in .claude/CLAUDE.md. This repo's
# most-repeated failure is a rail that exists on paper with nothing running it
# (rail 5, rail 9, pre-commit itself, the CLAUDE.md budget check). Seven rails
# are checkable from the files in this repo -- rails 1 and 6 only at source
# level, see their stanzas; this checks them, plus two non-rail invariants:
# vector.yaml byte-identical across the three nodes and free of three
# settings that fail silently, and setup-maintenance.sh still setting
# Docker's journald log driver.
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

# --- rails 7 and 8: one approval, and it sits behind validate.yml -------
# Rail 7: a deploying job must either carry environment: production itself or
# need a job that does. ponytail: one level of needs, inline needs/environment
# only; anything else is reported as unsupported rather than silently passing.
# Rail 8: the job carrying that approval must need a job that calls the
# reusable validate.yml, or a red lint gate never blocks a deploy. Same parse,
# not a second one: rail 7 already collects needs/environment per job.
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
    job != "" && /^    uses:[ \t]*\.\/\.github\/workflows\/validate\.yml[ \t]*$/ { val[job] = 1 }
    job != "" && ($0 ~ /(^|[^a-zA-Z-])ssh / || $0 ~ /wrangler-action/ || $0 ~ /(^|[^a-zA-Z-])rsync /) { deploys[job] = 1 }
    END {
      for (j in deploys) {
        ok = env[j]; gate = j
        if (!ok) { m = split(needs[j], a, /[ \t]+/); for (i = 1; i <= m; i++) if (env[a[i]]) { ok = 1; gate = a[i] } }
        if (!ok) { printf "FAIL %s:%d rail 7: deploying job \"%s\" reaches no environment: production approval\n", f, line[j], j > "/dev/stderr"; bad = 1; continue }
        v = 0; m = split(needs[gate], a, /[ \t]+/); for (i = 1; i <= m; i++) if (val[a[i]]) v = 1
        if (!v) { printf "FAIL %s:%d rail 8: approval job \"%s\" does not need a job calling ./.github/workflows/validate.yml\n", f, line[gate], gate > "/dev/stderr"; bad = 1 }
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
  # The -I line above lives inside the WANDROP payload heredoc, so it stays
  # matched even with the unit that runs that payload at boot deleted. Assert
  # the unit and its enablement separately, or rail 1 survives one reboot.
  grep -qF 'ExecStart=/usr/local/sbin/docker-wan-drop.sh' "$h" ||
    err "$h rail 1: docker-wan-drop.service unit block is gone -- the drop rules would not survive a reboot"
  # enable and restart both: 'enable --now' re-runs nothing on an already-
  # active RemainAfterExit=yes unit, so an updated payload never applies.
  grep -qF 'systemctl enable docker-wan-drop.service' "$h" ||
    err "$h rail 1: 'systemctl enable docker-wan-drop.service' is gone -- the unit would not start at boot"
  grep -qF 'systemctl restart docker-wan-drop.service' "$h" ||
    err "$h rail 1: 'systemctl restart docker-wan-drop.service' is gone -- the drops are not applied on this run"
else
  err "$h rail 1: missing -- rail 1 has no enforcement at all"
fi

echo "rail 1: source-level only. Only an off-node port sweep proves the nodes"
echo "        are closed: nc -z -w 3 <ip> 22 80 443 8050 8101 8102 8150 8250 8251"
echo "        (no -G: BSD-only, Debian nc exits 1 without connecting)"

# --- rail 6 (partial): the CI deploy user stays key-only, no sudo -------
# Same honesty as rail 1: this catches deletion in the script that creates the
# user, not drift on a node -- only 'ssh deploy@node sudo -n true' does that.
p=scripts/provision-deploy-user.sh
if [ -f "$p" ]; then
  # passwd -d, never -l: under UsePAM no, sshd's own shadow check rejects
  # pubkey auth on a locked account, which broke every CI deploy once.
  grep -qF 'passwd -d deploy' "$p" || err "$p rail 6: 'passwd -d deploy' is gone -- the deploy account's password field must be emptied"
  ! grep -qF 'passwd -l' "$p" || err "$p rail 6: 'passwd -l' locks the account and breaks pubkey auth under UsePAM no; use passwd -d"
  # Any sudo grant at all, not a specific one: the script grants none today.
  ! grep -qE 'sudoers|NOPASSWD|usermod[^|]*sudo' "$p" || err "$p rail 6: the deploy user is being granted sudo"
else
  err "$p rail 6: missing -- nothing creates the key-only deploy user"
fi

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

# --- vector.yaml: three settings that fail silently or fail everywhere ---
# All three are in stacks/CLAUDE.md's failure log with a real incident behind
# them, and none was catchable by any tool that already ran here -- yamllint
# sees valid YAML and `vector validate` says Validated for all three.
#
# current_boot_only: false -- Vector refuses to start for systemd 250-257.
# Debian 12 runs 252 and the vector:*-debian image ships journalctl 257, so
# no node here can ever accept it; it crashlooped all three while the
# deploy's Verify step called them green.
#
# journal_directory -- pinning the journald source ships nothing on a node
# with volatile journal storage, and still reports healthy.
#
# ${...} without VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION -- Vector
# 0.57.0 disabled interpolation by default, so the placeholder text becomes
# the literal URI and the literal credentials. An uninterpolated ${...} is
# perfectly good YAML, which is why validate passes on a config that cannot
# send one request.
if [ -f "$v0" ]; then
  ! grep -qE '^[[:space:]]*current_boot_only:[[:space:]]*false' "$v0" ||
    err "$v0: current_boot_only: false -- Vector refuses to start on Debian 12's systemd"
  # The key, not the path: vector.yaml names /var/log/journal in a comment
  # explaining why it is not pinned, and the first cut of this check failed
  # on that comment.
  ! grep -qE '^[[:space:]]*journal_directory:' "$v0" ||
    err "$v0: journald source pins journal_directory -- ships nothing on volatile storage, reports healthy"
  # shellcheck disable=SC2016  # '${' is the literal Vector placeholder
  if grep -qF '${' "$v0"; then
    for c in stacks/vps00/docker-compose.yml stacks/vps01/docker-compose.yml stacks/vps02/docker-compose.yml; do
      [ -f "$c" ] || { err "$c: missing -- the Vector interpolation check scanned nothing"; continue; }
      grep -qF 'VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION' "$c" ||
        err "$c: vector.yaml uses \${...} but this node never sets VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION"
    done
  fi
else
  err "$v0: missing -- the Vector settings checks scanned nothing"
fi

[ "$fail" -eq 0 ] || { echo "check-rails: FAILED" >&2; exit 1; }
echo "check-rails: rails 1 (partial), 2, 3, 4, 6 (partial), 7, 8 + markup sinks, vector.yaml identity and settings, journald driver OK across $found compose files"
