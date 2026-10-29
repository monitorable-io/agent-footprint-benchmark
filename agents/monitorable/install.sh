#!/usr/bin/env bash
# Source: https://monitorable.io/docs/install/ (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
curl --proto '=https' --tlsv1.2 -fsSL "${MONITORABLE_INSTALLER_URL:-https://get.monitorable.net/install.sh}" | sh -s -- --api-key="$MONITORABLE_API_KEY" ${MONITORABLE_ENDPOINT:+--endpoint="$MONITORABLE_ENDPOINT"}
ver=$(/opt/monitorable/monitorable-agent --version 2>/dev/null | head -1 || true)
[[ -n "$ver" ]] || ver=$(journalctl -u monitorable-agent --no-pager -o cat 2>/dev/null | grep -oE 'service.version[=:" ]+[0-9.]+' | head -1 | grep -oE '[0-9.]+$' || echo unknown)
echo "VERSION=$ver"
echo "UNITS=monitorable-agent.service"
