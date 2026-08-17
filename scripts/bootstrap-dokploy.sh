#!/bin/sh
# One-time bootstrap: installs the Dokploy control plane on the primary
# node (vps00). Run once from a local machine with SSH access to vps00.
#
# vps01 and vps02 do NOT use this script. They join the cluster later via
# the Dokploy dashboard (Settings > Servers > Add Server), which uses a
# different join flow than the initial install. See docs.dokploy.com.
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

# Dokploy has no apt repository, so this stays a vendor installer fetched
# over TLS. What changed: it lands in a file, its sha256 is printed to the
# log, and only then does it run. That does not *verify* anything on a
# first run -- there is no published checksum to compare against -- but it
# makes the artifact reviewable and gives a hash to diff on the next run.
# Do not describe this as a checksum check; it is a record.
ssh -p "$ssh_port" "${ssh_user}@${VPS00_HOST}" 'set -eu
  tmp=$(mktemp)
  trap "rm -f \"$tmp\"" EXIT
  curl -fsSL https://dokploy.com/install.sh -o "$tmp"
  echo "installer sha256: $(sha256sum "$tmp" | cut -d" " -f1)"
  sh "$tmp"'

echo ""
echo "Install finished."
echo "1. Open http://${VPS00_HOST}:3000 and create the first admin account."
echo "2. Settings > Profile > API Tokens > Generate, then:"
echo "     gh secret set DOKPLOY_API_TOKEN"
echo "3. Add the public hostname route in Cloudflare Zero Trust"
echo "   (dokploy.maybeit.work -> http://localhost:3000) if not done yet."
