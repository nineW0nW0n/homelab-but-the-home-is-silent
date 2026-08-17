#!/bin/sh
# One-time (idempotent) per-node: adds a swap file. 2GB nodes with no swap
# turn a transient memory spike (app startup, migrations) into a hard
# OOM-kill instead of a slowdown. Idempotent: skips if swap already exists.
#
# Usage: scripts/add-swap.sh <host> [size_gb]
#   scripts/add-swap.sh 203.0.113.11 2
#   Real addresses live in infra/inventory.yaml (gitignored).

set -eu

host="${1:?usage: add-swap.sh <host> [size_gb]}"
size_gb="${2:-2}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Adding ${size_gb}G swap on ${ssh_user}@${host}:${ssh_port} ..."

# SC2087: intentional; $size_gb must expand client-side here.
# shellcheck disable=SC2087
ssh -p "$ssh_port" "${ssh_user}@${host}" "sh -s" <<EOF
set -eu
if swapon --show | grep -q '/swapfile'; then
  echo "swap already present, skipping"
  swapon --show
  exit 0
fi

fallocate -l ${size_gb}G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Low-priority swap: prefer RAM, only spill under real pressure.
sysctl -w vm.swappiness=10
grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf

swapon --show
free -h
EOF

echo "Done."
