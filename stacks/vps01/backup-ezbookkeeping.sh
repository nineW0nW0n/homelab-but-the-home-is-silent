#!/bin/sh
# Nightly backup of ezBookkeeping (stacks/vps01) on vps01 to Cloudflare R2.
#
# Deployed to /opt/stacks/vps01/ by .github/workflows/deploy.yml (rsync of
# stacks/vps01/), run from the deploy user's crontab at 03:00 Asia/Manila.
#
# Consistency: the container is stopped for the duration of the tar, so
# SQLite checkpoints its WAL and closes cleanly. That costs a few seconds of
# downtime and removes any question of a torn database file. The container is
# started again even when the backup fails: availability outranks the backup.
#
# Volume contents are read through a throwaway container rather than from
# /var/lib/docker/volumes, so this needs Docker access but not root.
set -eu

# Debian's cron ignores CRON_TZ (verified on vps01, 2026-08-18), so cron runs
# this hourly in the node's own zone and the schedule lives here instead:
# 03:00 Asia/Manila, correct year-round without root or a host timezone change.
# FORCE_BACKUP=1 runs it now, for manual runs and restore drills.
[ "${FORCE_BACKUP:-}" = "1" ] || [ "$(TZ=Asia/Manila date +%H)" = "03" ] || exit 0

APP_CONTAINER=ezbookkeeping
VOLUME_PREFIX=vps01booking-ezbookkeeping-rqdyxo
WORK_DIR=/opt/stacks/vps01/backup
ENV_FILE=/opt/stacks/vps01/.r2.env
BUCKET=homelab-backups
R2_ENDPOINT=https://acb24619a369506235663e8cb25e7d1f.r2.cloudflarestorage.com
ALPINE_IMAGE=alpine:3.21
RCLONE_IMAGE=rclone/rclone:1.68.2

# Weekly copies land under a separate prefix so the two retention lifecycle
# rules in R2 can expire them on different schedules.
if [ "$(date +%u)" = "7" ]; then
    PREFIX=weekly
else
    PREFIX=daily
fi

STAMP=$(date +%Y-%m-%dT%H-%M-%S)
ARCHIVE="ezbookkeeping-${STAMP}.tar.gz"

log() { printf '%s backup-ezbookkeeping: %s\n' "$(date -Is)" "$1"; }

start_app() {
    docker start "$APP_CONTAINER" >/dev/null 2>&1 ||
        log "WARNING: could not start $APP_CONTAINER"
}

mkdir -p "$WORK_DIR"

if [ ! -r "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE missing; deploy.yml writes it from GitHub secrets"
    exit 1
fi

log "stopping $APP_CONTAINER"
docker stop "$APP_CONTAINER" >/dev/null

# From here on the app is down, so every exit path must bring it back.
trap 'start_app' EXIT INT TERM

log "archiving volumes"
docker run --rm \
    -v "${VOLUME_PREFIX}_data:/volumes/data:ro" \
    -v "${VOLUME_PREFIX}_storage:/volumes/storage:ro" \
    -v "${WORK_DIR}:/out" \
    "$ALPINE_IMAGE" \
    tar czf "/out/${ARCHIVE}" -C /volumes data storage

log "starting $APP_CONTAINER"
start_app
trap - EXIT INT TERM

log "uploading to r2://${BUCKET}/${PREFIX}/${ARCHIVE}"
docker run --rm \
    --env-file "$ENV_FILE" \
    -e RCLONE_CONFIG_R2_TYPE=s3 \
    -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    -e RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT" \
    -e RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
    -e RCLONE_CONFIG_R2_ACCESS_KEY_ID \
    -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY \
    -v "${WORK_DIR}:/data:ro" \
    "$RCLONE_IMAGE" \
    copyto "/data/${ARCHIVE}" "r2:${BUCKET}/${PREFIX}/${ARCHIVE}"

# Only now is the backup real: it exists off this node.
date +%s > "${WORK_DIR}/.last-success"
log "done"

# Keep one local copy for a fast restore; R2 lifecycle rules own the history.
find "$WORK_DIR" -name 'ezbookkeeping-*.tar.gz' ! -name "$ARCHIVE" -delete
