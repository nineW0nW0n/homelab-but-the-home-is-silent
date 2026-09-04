#!/bin/sh
# Alert to Telegram when a vps01 backup goes stale.
#
# Usage: check-backup-age.sh [APP_LABEL] [BACKUP_DIR]
# Defaults to the ezBookkeeping backup, so the original argument-less crontab
# entry and its existing .stale-alerted state file keep working unchanged.
#
# Deployed to /opt/stacks/vps01/ by .github/workflows/deploy.yml (rsync of
# stacks/vps01/), run hourly from the deploy user's crontab.
#
# This script exists because Netdata's own ezbookkeeping_backup_age alarm
# (retired with Netdata, 2026-09-04) was observed never executing its
# notification script for that alarm (no EXEC_RUN flag on any transition)
# while doing so for stock alarms, so the one alert guarding the only
# off-site copy of the books had no working delivery path. This script
# owns that alert outright: it reads the same stamp file, talks to the
# Telegram API directly, and has no roles, delays or notification queue
# to go wrong.
#
# It is parameterised rather than copied: the booking (EasyAppointments)
# MySQL backup gets the same treatment by passing its own label and work
# dir, so there is still exactly one staleness implementation to get right.
#
# Reads the same stamp the matching backup script writes on success.
set -eu

APP=${1:-ezBookkeeping}
BACKUP_DIR=${2:-/opt/stacks/vps01/backup}

STAMP_FILE="${BACKUP_DIR}/.last-success"
STATE_FILE="${BACKUP_DIR}/.stale-alerted"
ENV_FILE=/opt/stacks/vps01/.telegram.env
# One missed daily run: the backup fires once every 24h, so 36h gives it
# a 12h grace window before this counts as stale.
STALE_HOURS=36
# While stale, re-alert on this interval rather than hourly: a backup that
# stays broken should keep nagging, but not once an hour all night.
RENOTIFY_HOURS=12

log() { printf '%s check-backup-age[%s]: %s\n' "$(date -Is)" "$APP" "$1"; }

if [ ! -r "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE missing; deploy.yml writes it from GitHub secrets"
    exit 1
fi
# TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID. Never echoed, only sent.
# shellcheck source=/dev/null
. "$ENV_FILE"

# --data-urlencode covers chat_id and text only, so the message is safe to
# send verbatim. The bot token sits in the URL path and cannot move to the
# body: it is in argv, readable via /proc/<pid>/cmdline by any local user.
# Accepted on a single-admin node. -sS is quiet but still prints real errors.
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
        notify "${APP} backup on vps01 recovered: last success ${age_hours}h ago."
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
notify "${APP} backup on vps01 is STALE: ${detail} (threshold ${STALE_HOURS}h). Check ${BACKUP_DIR}/backup.log."
printf '%s\n' "$now" > "$STATE_FILE"
log "stale alert sent, $detail"
