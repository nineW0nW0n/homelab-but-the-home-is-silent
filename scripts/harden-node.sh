#!/bin/sh
# One-time (idempotent) per-node hardening: UFW (deny-by-default, SSH only),
# sshd (key-only auth), Fail2Ban (aggressive sshd jail), and the DOCKER-USER
# drop rules that make rail 1 true for container-published ports.
#
# SAFETY ORDER MATTERS: the SSH allow rule is added and UFW's policy is set
# *before* UFW is enabled, so enabling it never has a window where the only
# open port is closed. sshd config is syntax-checked (sshd -t) before the
# service is restarted, so a bad drop-in can't lock out further SSH access.
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

# SC2087: intentional — $ssh_port must expand client-side here.
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
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
SSHD
sshd -t
systemctl restart ssh

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
for ipt in iptables ip6tables; do
  command -v "\$ipt" >/dev/null 2>&1 || continue
  "\$ipt" -S DOCKER-USER >/dev/null 2>&1 || continue
  # Idempotent: drop every copy of our rule, then insert exactly one.
  while "\$ipt" -D DOCKER-USER -i "\$wan_if" -m conntrack --ctstate NEW -j DROP \\
    2>/dev/null; do :; done
  "\$ipt" -I DOCKER-USER 1 -i "\$wan_if" -m conntrack --ctstate NEW -j DROP
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
  systemctl enable --now docker-wan-drop.service
  iptables -S DOCKER-USER
  ip6tables -S DOCKER-USER

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

echo "Hardening complete on \$(hostname)"
EOF

echo "Done."
