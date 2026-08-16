#!/bin/sh
# Idempotent. Caps docker container log growth, caps journald disk use,
# and drops a weekly docker-prune cron.d entry. Run once per node; safe
# to re-run.
#
# This script never restarts Docker. The log-opts it merges into
# /etc/docker/daemon.json take effect at the next Docker restart or
# reboot, which the operator schedules -- restarting Docker on vps00
# restarts the Swarm control plane and every container on it. journald
# is restarted immediately; that only rotates logs, no container impact.
#
# Usage: scripts/setup-maintenance.sh <host>
#   scripts/setup-maintenance.sh 203.0.113.10
#   Real addresses live in infra/inventory.yaml (gitignored).

set -eu

host="${1:?usage: setup-maintenance.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Setting up maintenance on ${ssh_user}@${host}:${ssh_port} ..."

# shellcheck disable=SC2087
ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu

# --- docker log-opts: cap per-container json-file log size ---
if command -v docker >/dev/null 2>&1; then
  if [ ! -e /etc/docker/daemon.json ]; then
    printf '{\n  "ip": "127.0.0.1",\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "3"\n  }\n}\n' > /etc/docker/daemon.json
    echo "wrote /etc/docker/daemon.json -- takes effect at next Docker restart"
  elif grep -q '"log-opts"' /etc/docker/daemon.json; then
    echo "daemon.json already sets log-opts, leaving it alone"
  elif [ "$(tr -d '[:space:]' < /etc/docker/daemon.json)" = '{"ip":"127.0.0.1"}' ]; then
    printf '{\n  "ip": "127.0.0.1",\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "3"\n  }\n}\n' > /etc/docker/daemon.json
    echo "added log-opts to daemon.json -- takes effect at next Docker restart"
  else
    echo "WARNING: /etc/docker/daemon.json has unexpected content --" >&2
    echo "merge log-opts by hand, not clobbering it." >&2
  fi
else
  echo "docker not installed, skipping log-opts"
fi

# --- journald: cap disk use, restart to apply (safe, no container impact) ---
if grep -q '^SystemMaxUse=200M$' /etc/systemd/journald.conf 2>/dev/null; then
  echo "journald.conf already caps SystemMaxUse, leaving it alone"
else
  if grep -q '^#\?SystemMaxUse=' /etc/systemd/journald.conf; then
    sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
  else
    echo 'SystemMaxUse=200M' >> /etc/systemd/journald.conf
  fi
  systemctl restart systemd-journald
  echo "capped journald at 200M and restarted it"
fi

# --- weekly docker prune: dangling images/containers/build cache, never volumes ---
cron_line='0 3 * * 0 root docker system prune -af --filter "until=168h" >/var/log/docker-prune.log 2>&1'
if [ -f /etc/cron.d/docker-prune ] && grep -qF "$cron_line" /etc/cron.d/docker-prune; then
  echo "/etc/cron.d/docker-prune already set, leaving it alone"
else
  printf '%s\n' "$cron_line" > /etc/cron.d/docker-prune
  chmod 644 /etc/cron.d/docker-prune
  echo "wrote /etc/cron.d/docker-prune -- weekly Sunday 03:00"
fi

echo "Maintenance setup complete on $(hostname)"
EOF

echo "Done."
