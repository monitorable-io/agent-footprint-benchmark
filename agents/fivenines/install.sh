#!/usr/bin/env bash
# Source: https://github.com/Five-Nines-io/fivenines_agent#installation (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
wget -T 3 -q -O fivenines_setup.sh https://releases.fivenines.io/latest/fivenines_setup.sh && bash fivenines_setup.sh "$FIVENINES_TOKEN"
bin=$(systemctl show -p ExecStart --value fivenines-agent | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
echo "VERSION=$("$bin" --version 2>/dev/null | head -1 || echo unknown)"
echo "UNITS=fivenines-agent.service"
