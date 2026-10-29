#!/usr/bin/env bash
# Source: https://learn.netdata.cloud/docs/netdata-agent/installation/linux (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh && \
  sh /tmp/netdata-kickstart.sh --non-interactive --disable-telemetry --stable-channel
echo "VERSION=$(netdata -v 2>/dev/null | awk '{print $2}')"
echo "UNITS=netdata.service"
