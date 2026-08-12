#!/bin/sh
# One-time (idempotent) per-node bootstrap: creates the unprivileged
# 'deploy' user that .github/workflows/deploy.yml and scripts/*.sh SSH in
# as. Key-based auth only, password login locked, added to docker group,
# owns /opt/stacks/<node> for CI rsync. Also installs rsync itself — the
# deploy workflow's sync step needs it on every node, not just Docker.
#
# Usage: scripts/provision-deploy-user.sh <node-name> <host>
#   scripts/provision-deploy-user.sh vps00 203.0.113.10
#
# Requires root SSH access with the key in PUBKEY_FILE below (or override
# via PUBKEY_FILE env var).

set -eu

node="${1:?usage: provision-deploy-user.sh <node-name> <host>}"
host="${2:?usage: provision-deploy-user.sh <node-name> <host>}"
pubkey_file="${PUBKEY_FILE:-$HOME/.ssh/id_ed25519_vps.pub}"
ssh_port="${SSH_PORT:-22}"

[ -f "$pubkey_file" ] || { echo "pubkey not found: $pubkey_file" >&2; exit 1; }
pubkey="$(cat "$pubkey_file")"

echo "Provisioning deploy user on ${node} (root@${host}:${ssh_port}) ..."

# SC2087: intentional — $pubkey and $node must expand client-side here.
# shellcheck disable=SC2087
ssh -p "$ssh_port" "root@${host}" "sh -s" <<EOF
set -eu

command -v rsync >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install rsync >/dev/null
}

id -u deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy

mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
printf '%s\n' "$pubkey" > /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh

# passwd -d (empty), not -l (locked): with UsePAM no (see harden-node.sh),
# sshd's own shadow check rejects pubkey auth outright on a *locked*
# account, even with a valid key. An empty password field doesn't trip
# that check. PasswordAuthentication no + default PermitEmptyPasswords no
# still fully block password login either way.
passwd -d deploy >/dev/null 2>&1 || true

getent group docker >/dev/null 2>&1 && usermod -aG docker deploy || true

mkdir -p /opt/stacks/${node}
chown -R deploy:deploy /opt/stacks/${node}

echo "deploy user ready on \$(hostname)"
EOF

echo "Done. Test with: ssh -i ${pubkey_file%.pub} deploy@${host}"
