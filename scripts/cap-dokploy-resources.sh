#!/bin/sh
# One-time (idempotent, safe to re-run) per-node: caps Dokploy's own
# control-plane services -- none of it is part of this repo's compose
# files, all installed by scripts/bootstrap-dokploy.sh's upstream
# installer. `dokploy` and `dokploy-postgres` are Docker Swarm services
# (need `docker service update --limit-memory`, plain `docker update`
# doesn't stick -- swarm reconciles it away). `dokploy-traefik` is a
# plain container the installer starts directly (needs plain `docker
# update --memory` instead -- `docker service update` 404s on it).
# Rerun after any Dokploy reinstall/upgrade.
#
# Observed baseline on vps00 before capping: dokploy app ~913MiB (of
# 1.9GiB total, uncapped), dokploy-postgres ~67MiB, both otherwise
# unbounded. Limits below give real headroom above observed usage while
# still bounding worst-case growth on a 2GB node.
#
# Usage: scripts/cap-dokploy-resources.sh <host>
#   scripts/cap-dokploy-resources.sh 203.0.113.10

set -eu

host="${1:?usage: cap-dokploy-resources.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Capping Dokploy resources on ${ssh_user}@${host}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu

docker service update --limit-memory 1024M --reserve-memory 512M dokploy
docker service update --limit-memory 320M --reserve-memory 128M dokploy-postgres
docker update --memory 128m --memory-swap 256m dokploy-traefik

echo "-- current limits --"
docker service inspect dokploy --format '{{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}}'
docker service inspect dokploy-postgres --format '{{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}}'
docker inspect dokploy-traefik --format '{{.HostConfig.Memory}}'
EOF

echo "Done."
