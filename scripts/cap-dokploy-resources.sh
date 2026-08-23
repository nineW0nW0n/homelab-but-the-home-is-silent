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
# Runs on all three nodes. Only vps00 has the `dokploy` and
# `dokploy-postgres` Swarm services; vps01/vps02 have `dokploy-traefik`
# alone, installed there by Dokploy's Remote Server setup. Each cap is
# therefore skipped, not fatal, when its target is absent on this node --
# see scripts/CLAUDE.md for what the unguarded version cost.
#
# Observed baseline on vps00 before capping: dokploy app ~913MiB (of
# 1.9GiB total, uncapped), dokploy-postgres ~67MiB, both otherwise
# unbounded. Limits below give real headroom above observed usage while
# still bounding worst-case growth on a 2GB node.
#
# Usage: scripts/cap-dokploy-resources.sh <host>
#   scripts/cap-dokploy-resources.sh 203.0.113.10
#   SSH_KEY=~/.ssh/id_ed25519_vps scripts/cap-dokploy-resources.sh 203.0.113.10
#   Real addresses live in infra/inventory.yaml (gitignored).
#
# SSH_KEY is optional and only passed as `-i` when set. A bare IP matches no
# `Host` block in ~/.ssh/config, so without SSH_KEY this script still depends
# on the right key being agent-loaded (`ssh-add`) or on being handed a
# `vps0N-root` alias instead of an address -- see scripts/CLAUDE.md.

set -eu

host="${1:?usage: cap-dokploy-resources.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"
ssh_key="${SSH_KEY:-}"

# Two branches rather than an unquoted "$ssh_opts": an empty SSH_KEY must
# vanish, not become an empty argument, and word-splitting a built-up
# option string is the bug shellcheck SC2086 is about.
node_ssh() {
    if [ -n "$ssh_key" ]; then
        ssh -i "$ssh_key" -p "$ssh_port" "${ssh_user}@${host}" "$@"
    else
        ssh -p "$ssh_port" "${ssh_user}@${host}" "$@"
    fi
}

echo "Capping Dokploy resources on ${ssh_user}@${host}:${ssh_port} ..."

node_ssh 'sh -s' <<'EOF'
set -eu

# Swarm service: docker service update. A plain `docker update` here gets
# reconciled away silently.
cap_service() {
    name=$1
    limit_mb=$2
    reserve_mb=$3
    if ! docker service inspect "$name" >/dev/null 2>&1; then
        echo "skip: swarm service $name is not on this node"
        return 0
    fi
    want=$((limit_mb * 1024 * 1024))
    have=$(docker service inspect "$name" \
        --format '{{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}}' \
        2>/dev/null || echo 0)
    if [ "$have" = "$want" ]; then
        echo "ok: $name already capped at ${limit_mb}M"
        return 0
    fi
    # Re-running an update restarts the service's tasks, so only do it
    # when the limit actually differs -- that is what keeps a second run
    # a genuine no-op rather than a control-plane bounce.
    docker service update \
        --limit-memory "${limit_mb}M" --reserve-memory "${reserve_mb}M" \
        "$name" >/dev/null
    echo "capped: $name -> ${limit_mb}M limit / ${reserve_mb}M reserve"
}

# Plain container: docker update. `docker service update` 404s on it.
cap_container() {
    name=$1
    limit_mb=$2
    swap_mb=$3
    if ! docker inspect "$name" >/dev/null 2>&1; then
        echo "skip: container $name is not on this node"
        return 0
    fi
    want=$((limit_mb * 1024 * 1024))
    have=$(docker inspect "$name" --format '{{.HostConfig.Memory}}')
    if [ "$have" = "$want" ]; then
        echo "ok: $name already capped at ${limit_mb}m"
        return 0
    fi
    docker update \
        --memory "${limit_mb}m" --memory-swap "${swap_mb}m" "$name" >/dev/null
    echo "capped: $name -> ${limit_mb}m limit / ${swap_mb}m memory+swap"
}

cap_service dokploy 1024 512
cap_service dokploy-postgres 320 128
cap_container dokploy-traefik 128 256
EOF

echo "Done."
