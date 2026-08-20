#!/bin/sh
# Idempotent. Caps docker container log growth, caps journald disk use,
# drops a weekly docker-prune cron.d entry, and enables unattended
# security upgrades. Run once per node; safe to re-run.
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

# --- unattended-upgrades: apply Debian security updates automatically ---
# Port 22 is the only permanently reachable port on these nodes (everything
# else is behind an outbound-only tunnel), so an unpatched sshd/openssl/kernel
# is the real exposure.
#
# Debian 12's shipped /etc/apt/apt.conf.d/50unattended-upgrades already limits
# origins to the security suite. Do NOT add an Origins-Pattern override here:
# it can only widen that default or drift out of sync with it.
#
# Interaction worth knowing: an unattended docker-ce upgrade restarts dockerd.
# That does not flush DOCKER-USER -- Docker creates that chain when absent and
# never rewrites its contents, which is the chain's whole purpose -- so rail
# 1's iptables enforcement survives the restart. That is why this is safe to
# enable on these nodes.
command -v unattended-upgrade >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install unattended-upgrades >/dev/null
}
auto_upgrades='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] &&
  [ "$(cat /etc/apt/apt.conf.d/20auto-upgrades)" = "$auto_upgrades" ]; then
  echo "/etc/apt/apt.conf.d/20auto-upgrades already set, leaving it alone"
else
  printf '%s\n' "$auto_upgrades" > /etc/apt/apt.conf.d/20auto-upgrades
  chmod 644 /etc/apt/apt.conf.d/20auto-upgrades
  echo "wrote /etc/apt/apt.conf.d/20auto-upgrades -- daily security updates"
fi

echo "Maintenance setup complete on $(hostname)"
EOF

echo "Done."
