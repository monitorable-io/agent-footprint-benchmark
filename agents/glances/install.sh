#!/usr/bin/env bash
# Source: https://github.com/nicolargo/glances#installation (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
# pipx is the documented route on Ubuntu (apt's glances is a stale 3.x); [web] adds the REST/web server.
apt-get install -y -q pipx
pipx install 'glances[web]'
# Glances ships no unit: this minimal one runs the documented web-server mode (glances -w).
cat > /etc/systemd/system/glances.service <<'UNIT'
[Unit]
Description=Glances (web server mode)
After=network.target

[Service]
ExecStart=/root/.local/bin/glances -w
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now glances
echo "VERSION=$(/root/.local/bin/glances -V 2>/dev/null | head -1 | awk '{print $NF}')"
echo "UNITS=glances.service"
