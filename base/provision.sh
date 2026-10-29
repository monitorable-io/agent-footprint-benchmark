#!/usr/bin/env bash
# Base provisioning of one benchmark box (Ubuntu 26.04, run as root). Idempotent.
# Usage: provision.sh --name <hostname> [--no-cron] [--ports a,b,...]
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NAME="" NO_CRON=0 PORTS=""
while (($#)); do
  case "$1" in
    --name) NAME=$2; shift 2;;
    --no-cron) NO_CRON=1; shift;;
    --ports) PORTS=$2; shift 2;;
    *) echo "unknown flag $1" >&2; exit 2;;
  esac
done
[[ -n "$NAME" ]] || { echo "--name required" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }

log() { printf '%s provision: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

log "hostname $NAME"
hostnamectl set-hostname "$NAME"
grep -q "[[:space:]]$NAME$" /etc/hosts || printf '127.0.1.1 %s\n' "$NAME" >> /etc/hosts

log "apt"
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg nftables jq python3 stress-ng ufw

# Docker Engine from Docker's apt repository, as docs.docker.com/engine/install/ubuntu says.
if ! command -v docker > /dev/null; then
  log "docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  if ! curl -fsSI "https://download.docker.com/linux/ubuntu/dists/$codename/Release" > /dev/null; then
    echo "docker has no repository for $codename yet; using noble (24.04) packages" >&2
    codename=noble
  fi
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$codename" > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker > /dev/null

# Two idle containers for the whole cycle (what the agents are watching).
docker ps -a --format '{{.Names}}' | grep -qx bench-nginx || docker run -d --restart unless-stopped --name bench-nginx nginx:alpine > /dev/null
docker ps -a --format '{{.Names}}' | grep -qx bench-valkey || docker run -d --restart unless-stopped --name bench-valkey valkey/valkey:alpine > /dev/null
docker start bench-nginx bench-valkey > /dev/null

if ((NO_CRON)); then
  log "no cron on this box"
  if dpkg -s cron > /dev/null 2>&1; then apt-get purge -y -q cron; fi
  apt-mark hold cron > /dev/null
fi

log "sshd key-only"
printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/90-bench.conf
systemctl reload ssh 2> /dev/null || systemctl reload sshd 2> /dev/null || true

log "ufw"
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow 22/tcp > /dev/null
if [[ -n "$PORTS" ]]; then
  IFS=',' read -ra ports <<<"$PORTS"
  for p in "${ports[@]}"; do ufw allow "$p/tcp" > /dev/null; done
fi
ufw --force enable > /dev/null

log "bench dirs and collector unit"
install -d -m 0755 /var/lib/bench /opt/bench
if [[ -f /opt/bench/collector/bench-collector.service ]]; then
  cp /opt/bench/collector/bench-collector.service /etc/systemd/system/bench-collector.service
  systemctl daemon-reload
fi

echo "PROVISION_DONE $(date +%s)"
