#!/usr/bin/env bash
# Source: https://github.com/rcourtman/Pulse/blob/main/docs/UNIFIED_AGENT.md (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
# Settings -> Infrastructure -> Install on a host: token in a private file, installer from the Pulse server itself.
install -d -m 0700 /root/.config/pulse
printf '%s' "$PULSE_TOKEN" > /root/.config/pulse/agent-token
chmod 0600 /root/.config/pulse/agent-token
curl -fsSL "$PULSE_URL/install.sh" -o /root/.config/pulse/agent-install.sh
bash /root/.config/pulse/agent-install.sh --url "$PULSE_URL" --token-file /root/.config/pulse/agent-token
bin=$(systemctl show -p ExecStart --value pulse-agent | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
echo "VERSION=$("$bin" --version 2>/dev/null | head -1 || echo unknown)"
echo "UNITS=pulse-agent.service"
