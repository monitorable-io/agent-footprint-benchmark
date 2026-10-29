#!/usr/bin/env bash
# Source: https://github.com/hetrixtools/agent (installer: hetrixtools_install.sh) (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
# The dashboard's "Install Monitoring Agent" pop-up: SID then 7 options. HETRIX_INSTALL_ARGS holds the
# pop-up's options verbatim (default: hetrixtools user, no extra checks, reboot check on).
wget -q https://raw.githubusercontent.com/hetrixtools/agent/master/hetrixtools_install.sh
# shellcheck disable=SC2086
bash hetrixtools_install.sh "$HETRIX_KEY" ${HETRIX_INSTALL_ARGS:-0 0 0 0 0 0 1}
echo "VERSION=$(grep -m1 -oE '[Vv]ersion[: ]+[0-9.]+' /etc/hetrixtools/hetrixtools_agent.sh | grep -oE '[0-9.]+$' || echo unknown)"
echo "UNITS=$(systemctl list-units 'hetrixtools*' --all --no-legend --plain | awk '{print $1}' | paste -sd, -)"
