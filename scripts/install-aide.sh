#!/bin/sh
# Idempotent. Installs AIDE, builds the baseline once, and replaces
# Debian's daily timer (which emails root on a box with no mail) with a
# cron job that runs `aide --update`, pipes the report into the journal
# under SYSLOG_IDENTIFIER=aide, then adopts the new database. Every
# change is therefore reported exactly once, in OpenObserve, and becomes
# tomorrow's baseline: this is a change log, not a tamper lock.
#
# Usage: scripts/install-aide.sh <host>
#   scripts/install-aide.sh 203.0.113.10
#   Real addresses live in infra/inventory.yaml (gitignored).
#
# First run builds the database: a few minutes of CPU on a 2 vCPU node.

set -eu

host="${1:?usage: install-aide.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Installing AIDE on ${ssh_user}@${host}:${ssh_port} ..."

# shellcheck disable=SC2087
ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<'EOF'
set -eu

if command -v aide >/dev/null 2>&1; then
  echo "aide already installed, leaving it alone"
else
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install aide aide-common >/dev/null
  echo "installed aide"
fi

# Debian's own daily check mails root; nothing here delivers mail.
if systemctl is-enabled dailyaidecheck.timer >/dev/null 2>&1; then
  systemctl disable --now dailyaidecheck.timer >/dev/null 2>&1
  echo "disabled dailyaidecheck.timer (mails root, no mail here)"
else
  echo "dailyaidecheck.timer already disabled, leaving it alone"
fi

if [ -f /var/lib/aide/aide.db ]; then
  echo "aide.db exists, leaving the baseline alone"
else
  echo "building the AIDE baseline (minutes) ..."
  nice -n 19 aideinit -y -f >/dev/null
  echo "built /var/lib/aide/aide.db"
fi

runner='#!/bin/sh
# Written by scripts/install-aide.sh. Check, log, adopt.
set -u
nice -n 19 aide.wrapper --update 2>&1 | logger -t aide
if [ -f /var/lib/aide/aide.db.new ]; then
  mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
fi'
if [ -f /usr/local/sbin/aide-daily ] && [ "$(cat /usr/local/sbin/aide-daily)" = "$runner" ]; then
  echo "/usr/local/sbin/aide-daily already set, leaving it alone"
else
  printf '%s\n' "$runner" > /usr/local/sbin/aide-daily
  chmod 755 /usr/local/sbin/aide-daily
  echo "wrote /usr/local/sbin/aide-daily"
fi

cron_line='30 4 * * * root /usr/local/sbin/aide-daily'
if [ -f /etc/cron.d/aide-daily ] && grep -qF "$cron_line" /etc/cron.d/aide-daily; then
  echo "/etc/cron.d/aide-daily already set, leaving it alone"
else
  printf '%s\n' "$cron_line" > /etc/cron.d/aide-daily
  chmod 644 /etc/cron.d/aide-daily
  echo "wrote /etc/cron.d/aide-daily -- daily 04:30"
fi

echo "AIDE setup complete on $(hostname)"
EOF

echo "Done."
