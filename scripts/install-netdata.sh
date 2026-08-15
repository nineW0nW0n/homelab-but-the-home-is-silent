#!/bin/sh
# One-time (idempotent) per-node: installs Netdata (local agent only, no
# Cloud claiming), tuned for a 2GB box: ML off, apps/ebpf plugins off
# (heaviest collectors, not needed for a 3-number status page), dbengine
# capped to 1 week of retention by time (not size -- simplest correct
# knob for "just keep a week"). Binds the web UI to loopback only --
# reachability from outside the node happens through the Cloudflare
# Tunnel route added in a later, separate (manual, dashboard-driven)
# step, never by opening 19999 directly.
#
# Usage: scripts/install-netdata.sh <host>
#   scripts/install-netdata.sh 203.0.113.10

set -eu

host="${1:?usage: install-netdata.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Installing/tuning Netdata on ${ssh_user}@${host}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu

echo "-- install --"
command -v netdata >/dev/null 2>&1 || {
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry --dont-wait
  rm -f /tmp/netdata-kickstart.sh
}

echo "-- config --"
cat > /etc/netdata/netdata.conf <<'CONF'
[global]
    update every = 5
    memory mode = dbengine

[db]
    mode = dbengine
    storage tiers = 1
    dbengine tier 0 retention size = 0
    dbengine tier 0 retention time = 7d

[ml]
    enabled = no

[web]
    bind to = 127.0.0.1

[plugins]
    apps = no
    ebpf = no
CONF

systemctl restart netdata
sleep 2
systemctl is-active --quiet netdata && echo "netdata active"

echo "-- verify local API --"
curl -fsS http://127.0.0.1:19999/api/v1/info >/dev/null && echo "API reachable"

echo "-- root filesystem disk chart id (needed verbatim in Task 6) --"
curl -fsS http://127.0.0.1:19999/api/v1/charts | grep -o '"disk_space[^"]*"' | sort -u

echo "Netdata ready on $(hostname)"
EOF

echo "Done."
