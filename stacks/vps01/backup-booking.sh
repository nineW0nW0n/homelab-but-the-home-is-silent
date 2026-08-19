#!/bin/sh
# Nightly backup of the booking (EasyAppointments) MySQL database on vps01
# to Cloudflare R2.
#
# Deployed to /opt/stacks/vps01/ by .github/workflows/deploy.yml (rsync of
# stacks/vps01/), run from the deploy user's crontab at 04:00 Asia/Manila.
#
# Consistency: unlike the ezBookkeeping backup, nothing is stopped. This is a
# hot logical dump; InnoDB plus --single-transaction takes the dump inside one
# repeatable-read snapshot, so a live booking site stays up and the dump is
# still a consistent point in time. mysqldump runs inside the MySQL container
# so MYSQL_ROOT_PASSWORD is expanded there and never reaches a host process
# argument, a log line or an env file (rail 11).
#
# 04:00, not 03:00, so it never overlaps backup-ezbookkeeping.sh: 2GB node.
set -eu

# Debian's cron ignores CRON_TZ (verified on vps01, 2026-08-18), so cron runs
# this hourly in the node's own zone and the schedule lives here instead.
# FORCE_BACKUP=1 runs it now, for manual runs and restore drills.
[ "${FORCE_BACKUP:-}" = "1" ] || [ "$(TZ=Asia/Manila date +%H)" = "04" ] || exit 0

DB_CONTAINER=booking-ptpwn8-mysql-1
DB_NAME=easyappointments
WORK_DIR=/opt/stacks/vps01/backup-booking
ENV_FILE=/opt/stacks/vps01/.r2.env
BUCKET=homelab-backups
R2_ENDPOINT=https://acb24619a369506235663e8cb25e7d1f.r2.cloudflarestorage.com
RCLONE_IMAGE=rclone/rclone:1.68.2

# Weekly copies land under a separate prefix so the two retention lifecycle
# rules in R2 can expire them on different schedules.
if [ "$(date +%u)" = "7" ]; then
    PREFIX=weekly
else
    PREFIX=daily
fi

STAMP=$(date +%Y-%m-%dT%H-%M-%S)
ARCHIVE="booking-mysql-${STAMP}.sql.gz"

log() { printf '%s backup-booking: %s\n' "$(date -Is)" "$1"; }

mkdir -p "$WORK_DIR"

if [ ! -r "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE missing; deploy.yml writes it from GitHub secrets"
    exit 1
fi

log "dumping $DB_NAME from $DB_CONTAINER"
docker exec "$DB_CONTAINER" sh -c \
    'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
        --single-transaction --routines --triggers --databases easyappointments' \
    | gzip -c > "${WORK_DIR}/${ARCHIVE}"

# `set -o pipefail` is not POSIX, so the pipeline above reports gzip's exit
# status and a failed or half-written mysqldump would look like success.
# mysqldump ends a complete dump with "-- Dump completed on ...", so that
# trailer surviving decompression proves both halves of the pipe finished.
if ! gzip -cd "${WORK_DIR}/${ARCHIVE}" | tail -5 | grep -q 'Dump completed'; then
    log "ERROR: dump incomplete (no 'Dump completed' trailer); not uploading"
    rm -f "${WORK_DIR}/${ARCHIVE}"
    exit 1
fi

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
find "$WORK_DIR" -name 'booking-mysql-*.sql.gz' ! -name "$ARCHIVE" -delete
