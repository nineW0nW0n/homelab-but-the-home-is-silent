#!/bin/sh
# One-time (idempotent) per-node bootstrap: installs Docker Engine only.
# Every node just runs stacks/<node>/docker-compose.yml; there is no
# control plane (Dokploy was removed 2026-08-23). Adds 'deploy' to the
# docker group.
#
# Usage: scripts/install-docker.sh <host>
#   scripts/install-docker.sh 203.0.113.11
#   Real addresses live in infra/inventory.yaml (gitignored).

set -eu

host="${1:?usage: install-docker.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Installing Docker on ${ssh_user}@${host}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu
# Docker from Docker's own apt repository rather than piping
# https://get.docker.com into a root shell. Same end state -- the
# convenience script configures exactly this repo and keyring, verified
# against a node it had already provisioned -- but every package is
# GPG-verified through apt and upgrades arrive through the normal
# channel instead of a re-run of an unpinned remote script.
#
# The residual is the initial key fetch, which is still
# trust-on-first-use over TLS. Shipping the key in the repo would close
# that; it has not been judged worth the maintenance.
command -v docker >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install \
    ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
    "$(dpkg --print-architecture)" \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
    > /etc/apt/sources.list.d/docker.list
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin >/dev/null
}
systemctl enable --now docker
id -u deploy >/dev/null 2>&1 && usermod -aG docker deploy || true
docker version --format 'Docker {{.Server.Version}} installed'
EOF

echo "Done."
