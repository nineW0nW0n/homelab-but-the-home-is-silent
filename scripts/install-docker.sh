#!/bin/sh
# One-time (idempotent) per-node bootstrap: installs Docker Engine only
# (no Dokploy control plane — that's scripts/bootstrap-dokploy.sh, vps00
# only). Use this for secondary nodes that just need to run
# stacks/<node>/docker-compose.yml. Adds 'deploy' to the docker group.
#
# Usage: scripts/install-docker.sh <host>
#   scripts/install-docker.sh 203.0.113.11

set -eu

host="${1:?usage: install-docker.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Installing Docker on ${ssh_user}@${host}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu
command -v docker >/dev/null 2>&1 || {
  curl -fsSL https://get.docker.com | sh
}
systemctl enable --now docker
id -u deploy >/dev/null 2>&1 && usermod -aG docker deploy || true
docker version --format 'Docker {{.Server.Version}} installed'
EOF

echo "Done."
