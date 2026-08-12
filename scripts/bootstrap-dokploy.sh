#!/bin/sh
# One-time bootstrap: installs the Dokploy control plane on the primary
# node (vps00). Run once from a local machine with SSH access to vps00.
#
# vps01 and vps02 do NOT use this script. They join the cluster later via
# the Dokploy dashboard (Settings > Servers > Add Server), which uses a
# different join flow than the initial install — see docs.dokploy.com.
#
# Usage: scripts/bootstrap-dokploy.sh
# Reads VPS00_HOST / VPS00_SSH_USER / VPS00_SSH_PORT from .env if present,
# falling back to the environment, falling back to defaults.

set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
env_file="${repo_root}/.env"

if [ -f "$env_file" ]; then
  # shellcheck disable=SC1090
  . "$env_file"
fi

: "${VPS00_HOST:?VPS00_HOST not set. Export it or set it in .env (see .env.example)}"
ssh_user="${VPS00_SSH_USER:-deploy}"
ssh_port="${VPS00_SSH_PORT:-22}"

echo "Bootstrapping Dokploy on ${ssh_user}@${VPS00_HOST}:${ssh_port} ..."

ssh -p "$ssh_port" "${ssh_user}@${VPS00_HOST}" \
  'curl -sSL https://dokploy.com/install.sh | sh'

echo ""
echo "Install finished."
echo "1. Open http://${VPS00_HOST}:3000 and create the first admin account."
echo "2. Settings > Profile > API Tokens > Generate, then:"
echo "     gh secret set DOKPLOY_API_TOKEN"
echo "3. Add the public hostname route in Cloudflare Zero Trust"
echo "   (dokploy.maybeit.work -> http://localhost:3000) if not done yet."
