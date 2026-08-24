#!/bin/sh
# verify-node.sh: post-deploy verification, run ON a node. deploy.yml pipes
# this file over the SSH connection it already holds:
#   ssh ... "sh -s -- <args>" < scripts/verify-node.sh
#
# Usage: sh -s -- NETDATA_PORT OPENOBSERVE_PORT APP_PROBES CONTAINER...
#   NETDATA_PORT      loopback port Netdata answers on (8050/8150/8250)
#   OPENOBSERVE_PORT  loopback port for the OpenObserve /healthz probe,
#                     or '-' for none (only vps02 runs OpenObserve)
#   APP_PROBES        comma-separated label:port loopback probes, or '-'
#                     (vps01: booking:8101,budget:8102)
#   CONTAINER...      containers whose restart counters are sampled
#
# Probed from the node, not the runner: a zone-wide Cloudflare custom rule
# ("Block non-local traffic") blocks every request whose source country is
# not PH, so the public hostnames 403 from GitHub Actions while the service
# is perfectly healthy. Only the apex is exempt. The origin is what CI can
# honestly assert; the edge and tunnel path is covered by the status page
# and Netdata Cloud.
#
# It reports and fails; it never reverts (rollback is git revert, rail 12).
set -eu

netdata_port=$1
openobserve_port=$2
app_probes=$3
shift 3

# Polls rather than asking once: the Deploy step ends with 'docker compose
# restart netdata', and Netdata answers 503 for a few seconds while it
# initialises. Measured at ~5s on a real node; 60s of patience costs
# nothing when everything is healthy and still fails fast enough to be
# useful.
probe() {
  label=$1
  url=$2
  i=0
  code=000
  while [ "$i" -lt 30 ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$url" || true)
    if [ "$code" = 200 ]; then
      echo "ok   $label"
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  echo "FAIL $label: last code $code"
  return 1
}

# 2>/dev/null || echo missing: unguarded, set -e kills the script at this
# assignment when the container does not exist, so the FAIL line below
# never prints and the log shows docker stderr instead. A rename is
# plausible -- see the frozen-name entry in the stacks/vps01/CLAUDE.md
# failure log.
#
# Running alone is not aliveness. Under restart: unless-stopped a container
# that crashes on startup is Running for a moment out of every minute, and
# this check caught vector there and printed "ok" while it had never once
# started. Sample the restart counter across a wait instead: unchanged
# means it is genuinely staying up. An absolute count would not work -- a
# healthy container that restarted once weeks ago keeps that count until
# something recreates it.
#
# 75s, and one window shared by every container on the node: the Docker
# restart backoff caps at 60s, so a mature crashloop ticks its counter only
# once a minute and a shorter sample can sit entirely between two restarts
# and see no change. A 20s window did exactly that against a vector that
# had never started once.
snap() {
  docker inspect -f "{{.State.Running}} {{.RestartCount}}" \
    "$1" 2>/dev/null || echo "missing missing"
}

up() {
  now=$(snap "$1")
  if [ "$now" != "true ${2##* }" ]; then
    echo "FAIL $1: was [$2], now [$now]"
    exit 1
  fi
  echo "ok   $1"
}

probe netdata "http://127.0.0.1:$netdata_port/api/v1/info"

was=$(for c in "$@"; do printf '%s %s\n' "$c" "$(snap "$c")"; done)
sleep 75
printf '%s\n' "$was" | while read -r c state; do
  up "$c" "$state"
done

if [ "$openobserve_port" != - ]; then
  # Both, not either: /healthz proves it answers, the restart counter
  # above proves it is not answering from inside a loop. A polling HTTP
  # probe alone can catch a looping container in its up window.
  probe openobserve "http://127.0.0.1:$openobserve_port/healthz"
fi

if [ "$app_probes" != - ]; then
  # Each app owns one loopback port (stacks/vps01/docker-compose.yml), so
  # no Host header: the port names the app. This tests the containers this
  # deploy owns regardless of where the tunnel points, so a FAIL here is
  # an app that is down, not a cutover-ordering artefact.
  oldifs=$IFS
  IFS=,
  # shellcheck disable=SC2086  # splitting label:port entries on IFS=, is the point
  set -- $app_probes
  IFS=$oldifs
  for entry in "$@"; do
    probe "${entry%%:*}" "http://127.0.0.1:${entry#*:}/"
  done
fi
