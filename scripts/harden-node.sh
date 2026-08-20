#!/bin/sh
# One-time (idempotent) per-node hardening: UFW (deny-by-default, SSH only),
# sshd (key-only auth), Fail2Ban (aggressive sshd jail), and the DOCKER-USER
# drop rules that make rail 1 true for container-published ports.
#
# SAFETY ORDER MATTERS: the SSH allow rule is added and UFW's policy is set
# *before* UFW is enabled, so enabling it never has a window where the only
# open port is closed. sshd config is syntax-checked (sshd -t) before the
# service is restarted, so a bad drop-in can't lock out further SSH access, and
# the resulting *effective* config is asserted with 'sshd -T' at the very end
# of the run -- after every other control is in place, so that assertion
# failing never costs rail 1.
# SSH is not a container-published port, so it never transits DOCKER-USER --
# the Docker block below cannot close it.
#
# This script never restarts Docker. The /etc/docker/daemon.json default-bind
# it writes takes effect at the next Docker restart or reboot, which the
# operator schedules -- restarting Docker on vps00 restarts the Swarm control
# plane and every container on it.
#
# Usage: scripts/harden-node.sh <host>
#   scripts/harden-node.sh 203.0.113.10
#   Real addresses live in infra/inventory.yaml (gitignored).

set -eu

host="${1:?usage: harden-node.sh <host>}"
ssh_port="${SSH_PORT:-22}"
ssh_user="${SSH_USER:-root}"

echo "Hardening ${ssh_user}@${host}:${ssh_port} ..."

# SC2087: intentional; $ssh_port must expand client-side here.
# shellcheck disable=SC2087
ssh -p "$ssh_port" "${ssh_user}@${host}" 'sh -s' <<EOF
set -eu

echo "-- UFW --"
command -v ufw >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install ufw >/dev/null
}
ufw allow ${ssh_port}/tcp comment 'SSH'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status verbose

echo "-- sshd --"
# Debian 12's /etc/ssh/sshd_config opens with
# 'Include /etc/ssh/sshd_config.d/*.conf', read in lexical order, and sshd
# keeps the FIRST value it obtains for each keyword. A provider-shipped
# 50-cloud-init.conf carrying 'PasswordAuthentication yes' therefore beats a
# 99-* drop-in outright. Sort ahead of everything instead, and delete the old
# 99- name so a node provisioned by the previous version of this script never
# ends up carrying both files.
#
# RECOVERY: because 00- sorts first, a later drop-in can NOT re-enable password
# auth -- adding 10-emergency.conf does nothing. From the provider console,
# edit 00-hardening.conf itself.
#
# Write the replacement BEFORE removing the old name: an interrupted run must
# leave both files (identical content, 00- wins), never neither. Neither means
# a node with no hardening drop-in at all, and Debian's compiled-in default is
# PasswordAuthentication yes.
#
# PermitRootLogin is set here because these nodes are NOT stock Debian: the
# provider image uncomments line 33 of /etc/ssh/sshd_config as
# 'PermitRootLogin yes' (measured on all three, 2026-08-20). Every doc in this
# repo used to say Debian's 'prohibit-password' default applied -- it does not.
# 'prohibit-password' keeps key-based root working, which both these
# provisioning scripts and Dokploy's Remote Server connection need, and drops
# only the password path. Include sits at line 12, ahead of line 33, so the
# drop-in wins.
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
SSHD
rm -f /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t
systemctl restart ssh

echo "-- Docker port exposure (DOCKER-USER) --"
# UFW does not govern container-published ports. Docker's own nat/DOCKER
# rules are evaluated before ufw's chains, so every published port is
# internet-facing regardless of what 'ufw status' says. DOCKER-USER is the
# one chain Docker will not rewrite and it is traversed before Docker's
# accepts, so that is where the drop belongs.
#
# Scope: this covers plain-container and host-mode publishes. A Swarm
# service published in *ingress* mode traverses DOCKER-INGRESS instead and
# is NOT covered -- re-check with
#   docker service inspect <svc> --format '{{json .Endpoint.Ports}}'
# whenever a new Swarm workload lands.
#
# Persistence is a systemd oneshot ordered After=docker.service, not
# iptables-persistent: restoring saved rules at boot races Docker creating
# the DOCKER-USER chain, and a unit that runs after Docker cannot lose that
# race. One mechanism, no package, no fallback to forget about.
if command -v docker >/dev/null 2>&1; then
  install -m 0755 /dev/null /usr/local/sbin/docker-wan-drop.sh
  cat > /usr/local/sbin/docker-wan-drop.sh <<'WANDROP'
#!/bin/sh
# Drops all NEW inbound traffic arriving on the WAN interface that is
# forwarded to a container-published port. Loopback (cloudflared runs
# network_mode: host and reaches origins over 127.0.0.1) and established
# flows never match. Managed by scripts/harden-node.sh -- edit there.
set -eu
wan_if=\$(ip -o -4 route show default | awk '{print \$5; exit}')
[ -n "\$wan_if" ] || { echo "cannot determine WAN interface" >&2; exit 1; }
# -w 5 on every call: at boot this races Docker's own iptables writes, and
# without a lock wait the first "another app is currently holding the xtables
# lock" exits non-zero under set -eu. A Type=oneshot + RemainAfterExit unit
# never retries after that, so the node would come up with rail 1's only
# active enforcement layer missing.
for ipt in iptables ip6tables; do
  if ! command -v "\$ipt" >/dev/null 2>&1 ||
    ! "\$ipt" -w 5 -S DOCKER-USER >/dev/null 2>&1; then
    # IPv4 is rail 1's enforcement layer: no chain means nothing was applied,
    # and exiting 0 here would leave 'systemctl is-active' green on a node
    # whose published ports are wide open. IPv6 may legitimately have no
    # chain, but say which family was skipped rather than skipping in silence.
    if [ "\$ipt" = iptables ]; then
      echo "no IPv4 DOCKER-USER chain: rail 1 NOT enforced" >&2
      exit 1
    fi
    echo "no ip6tables DOCKER-USER chain, skipping IPv6" >&2
    continue
  fi
  # Idempotent: drop every copy of our rule, then insert exactly one.
  while "\$ipt" -w 5 -D DOCKER-USER -i "\$wan_if" -m conntrack --ctstate NEW \\
    -j DROP 2>/dev/null; do :; done
  "\$ipt" -w 5 -I DOCKER-USER 1 -i "\$wan_if" -m conntrack --ctstate NEW -j DROP
done
WANDROP

  cat > /etc/systemd/system/docker-wan-drop.service <<'WANUNIT'
[Unit]
Description=Drop WAN traffic to Docker-published ports (rail 1)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-wan-drop.sh

[Install]
WantedBy=multi-user.target
WANUNIT

  systemctl daemon-reload
  # enable + restart, not '--now': the unit is RemainAfterExit=yes, so on an
  # already-hardened node '--now' sees it active and re-runs nothing, leaving
  # the updated payload on disk unapplied while the run looks like it worked.
  systemctl enable docker-wan-drop.service
  systemctl restart docker-wan-drop.service
  iptables -w 5 -S DOCKER-USER
  ip6tables -w 5 -S DOCKER-USER || echo "(no ip6tables DOCKER-USER chain)"

  # Second layer: stop Docker binding new published ports to 0.0.0.0 in the
  # first place. Weaker on its own than the drop rules above (a container
  # that explicitly asks for 0.0.0.0:PORT:PORT still gets it, and Dokploy's
  # UI can generate exactly that), which is why both are in place.
  mkdir -p /etc/docker
  if [ ! -e /etc/docker/daemon.json ]; then
    printf '{\n  "ip": "127.0.0.1"\n}\n' > /etc/docker/daemon.json
    echo "wrote /etc/docker/daemon.json -- takes effect at next Docker restart"
  elif grep -q '"ip"' /etc/docker/daemon.json; then
    echo "daemon.json already sets \"ip\", leaving it alone"
  else
    echo "WARNING: /etc/docker/daemon.json exists without an \"ip\" key --" >&2
    echo "merge '\"ip\": \"127.0.0.1\"' by hand, not clobbering it." >&2
  fi
else
  echo "docker not installed, skipping DOCKER-USER rules"
fi

# After the DOCKER-USER block on purpose: fail2ban's own start can fail on a
# node whose journal or jail config it dislikes (see the failure log), and
# under 'set -eu' that abort would take rail 1's enforcement with it. Rail 1
# first, defence-in-depth second, assertions last.
echo "-- Fail2Ban --"
command -v fail2ban-client >/dev/null 2>&1 || {
  apt-get -qq update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq install fail2ban >/dev/null
}
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<'F2B'
[sshd]
enabled = true
mode = aggressive
backend = systemd
F2B
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client status sshd || true

# Last on purpose: a failed assertion here must never skip the rail 1
# enforcement above. 'sshd -t' only parses; it cannot say which drop-in won.
# 'sshd -T' prints the config sshd will actually use, so assert against that
# and leave the proof in the run's output.
echo "-- sshd effective config --"
eff=\$(sshd -T) || { echo "FATAL: sshd -T failed; check host keys" >&2; exit 1; }
printf '%s\n' "\$eff" | grep -E \
  '^(passwordauthentication|permitrootlogin|permitemptypasswords|usepam) ' || true
bad=
for want in 'passwordauthentication no' 'permitemptypasswords no' 'usepam no' \
  'permitrootlogin prohibit-password'; do
  printf '%s\n' "\$eff" | grep -qx "\$want" || bad="\$bad [\$want]"
done
if [ -n "\$bad" ]; then
  echo "FATAL: sshd effective config is not what this script wrote." >&2
  echo "FATAL: missing:\$bad -- check for an earlier-sorting drop-in in" >&2
  echo "FATAL: /etc/ssh/sshd_config.d/ (50-cloud-init.conf is the usual one)." >&2
  exit 1
fi

echo "Hardening complete on \$(hostname)"
EOF

echo "Done."
