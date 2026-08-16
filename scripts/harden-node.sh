#!/bin/sh
# One-time (idempotent) per-node hardening: UFW (deny-by-default, SSH only),
# sshd (key-only auth), Fail2Ban (aggressive sshd jail).
#
# SAFETY ORDER MATTERS: the SSH allow rule is added and UFW's policy is set
# *before* UFW is enabled, so enabling it never has a window where the only
# open port is closed. sshd config is syntax-checked (sshd -t) before the
# service is restarted, so a bad drop-in can't lock out further SSH access.
#
# Usage: scripts/harden-node.sh <host>
#   scripts/harden-node.sh 203.0.113.10
#   Real addresses live in infra/inventory.yaml (gitignored).

set -eu

host="${1:?usage: harden-node.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Hardening ${ssh_user}@${host}:${ssh_port} ..."

# SC2087: intentional — $ssh_port must expand client-side here.
# shellcheck disable=SC2087
ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<EOF
set -eu

echo "-- UFW --"
command -v ufw >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install ufw >/dev/null
}
ufw allow ${ssh_port}/tcp comment 'SSH'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status verbose

echo "-- sshd --"
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
SSHD
sshd -t
systemctl restart ssh

echo "-- Fail2Ban --"
command -v fail2ban-client >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install fail2ban >/dev/null
}
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<'F2B'
[sshd]
enabled = true
mode = aggressive
backend = systemd
F2B
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client status sshd || true

echo "Hardening complete on \$(hostname)"
EOF

echo "Done."
