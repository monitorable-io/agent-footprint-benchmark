#!/usr/bin/env bash
# Source: https://beszel.dev/guide/agent-installation (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
# The hub's "Add system" dialog (binary, WebSocket) supplies KEY, TOKEN and the hub URL.
curl -sL https://get.beszel.dev -o /tmp/install-agent.sh && chmod +x /tmp/install-agent.sh && \
  /tmp/install-agent.sh -k "$BESZEL_KEY" -t "$BESZEL_TOKEN" -url "$BESZEL_HUB_URL" --auto-update false
bin=$(systemctl show -p ExecStart --value beszel-agent | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
echo "VERSION=$("$bin" --version 2>/dev/null | head -1 || echo unknown)"
echo "UNITS=beszel-agent.service"
