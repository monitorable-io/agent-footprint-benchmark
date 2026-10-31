#!/usr/bin/env bash
# Source: https://docs.datadoghq.com/agent/basic_agent_usage/ubuntu/ (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bash -c "$(curl -L https://install.datadoghq.com/scripts/install_script_agent7.sh)"
echo "VERSION=$(datadog-agent version 2>/dev/null | head -1)"
echo "UNITS=$(systemctl list-units 'datadog-agent*' --all --no-legend --plain | awk '{print $1}' | paste -sd, -)"
