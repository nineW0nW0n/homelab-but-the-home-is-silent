#!/bin/sh
# Alert to Telegram when the ezBookkeeping backup goes stale.
#
# Deployed to /opt/stacks/vps01/ by .github/workflows/deploy.yml (rsync of
# stacks/vps01/), run hourly from the deploy user's crontab.
#
# This deliberately duplicates Netdata's ezbookkeeping_backup_age alarm.
# Netdata's health engine was observed never executing its notification
# script for that alarm (no EXEC_RUN flag on any transition) while doing so
# for stock alarms, so the one alert guarding the only off-site copy of the
# books had no working delivery path. This script owns that alert outright:
# it reads the same stamp file, talks to the Telegram API directly, and has
# no roles, delays or notification queue to go wrong. Netdata keeps the
# chart and the dashboard alarm; it is no longer the only path.
#
# Reads the same stamp backup-ezbookkeeping.sh writes on success.
set -eu

STAMP_FILE=/opt/stacks/vps01/backup/.last-success
STATE_FILE=/opt/stacks/vps01/backup/.stale-alerted
ENV_FILE=/opt/stacks/vps01/.telegram.env
# One missed daily run. Matches health.d/backup.conf's warn threshold so the
# two agree about what "stale" means.
STALE_HOURS=36
# While stale, re-alert on this interval rather than hourly: a backup that
# stays broken should keep nagging, but not once an hour all night.
RENOTIFY_HOURS=12

log() { printf '%s check-backup-age: %s\n' "$(date -Is)" "$1"; }

if [ ! -r "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE missing; deploy.yml writes it from GitHub secrets"
    exit 1
fi
# TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID. Never echoed, only sent.
# shellcheck source=/dev/null
. "$ENV_FILE"

# --data-urlencode keeps the token out of the URL and the message safe to
# send verbatim. -sS is quiet but still prints real errors.
notify() {
    curl -sS -m 20 -o /dev/null \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1"
}

now=$(date +%s)

if [ -r "$STAMP_FILE" ]; then
    last=$(cat "$STAMP_FILE")
else
    # No stamp at all is the worst case, not the absence of a problem:
    # treat it as infinitely stale rather than skipping the check.
    last=0
fi

if [ "$last" -gt 0 ]; then
    age_hours=$(( (now - last) / 3600 ))
else
    age_hours=999
fi

if [ "$age_hours" -lt "$STALE_HOURS" ]; then
    # Fresh. If we alerted earlier, say so once and forget it happened.
    if [ -f "$STATE_FILE" ]; then
        notify "ezBookkeeping backup on vps01 recovered: last success ${age_hours}h ago."
        rm -f "$STATE_FILE"
        log "recovered, age ${age_hours}h"
    fi
    exit 0
fi

# Stale. Alert on the first detection, then every RENOTIFY_HOURS.
if [ -r "$STATE_FILE" ]; then
    alerted=$(cat "$STATE_FILE")
    if [ $(( (now - alerted) / 3600 )) -lt "$RENOTIFY_HOURS" ]; then
        exit 0
    fi
fi

if [ "$last" -gt 0 ]; then
    detail="last success ${age_hours}h ago"
else
    detail="no successful backup on record"
fi
notify "ezBookkeeping backup on vps01 is STALE: ${detail} (threshold ${STALE_HOURS}h). Check /opt/stacks/vps01/backup/backup.log."
printf '%s\n' "$now" > "$STATE_FILE"
log "stale alert sent, $detail"
