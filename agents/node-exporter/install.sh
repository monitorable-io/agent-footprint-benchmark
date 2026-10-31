#!/usr/bin/env bash
# Source: https://prometheus.io/docs/guides/node-exporter/ (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
VER=$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/prometheus/node_exporter/releases/download/$VER/node_exporter-${VER#v}.linux-amd64.tar.gz"
tar xzf "node_exporter-${VER#v}.linux-amd64.tar.gz"
# The repo's examples/systemd units (verbatim): /usr/sbin binary, node_exporter user, socket activation.
install -m 0755 "node_exporter-${VER#v}.linux-amd64/node_exporter" /usr/sbin/node_exporter
id node_exporter > /dev/null 2>&1 || useradd -r -s /usr/sbin/nologin node_exporter
install -d /etc/sysconfig
[[ -f /etc/sysconfig/node_exporter ]] || echo 'OPTIONS=""' > /etc/sysconfig/node_exporter
curl -fsSL "https://raw.githubusercontent.com/prometheus/node_exporter/$VER/examples/systemd/node_exporter.service" -o /etc/systemd/system/node_exporter.service
curl -fsSL "https://raw.githubusercontent.com/prometheus/node_exporter/$VER/examples/systemd/node_exporter.socket" -o /etc/systemd/system/node_exporter.socket
systemctl daemon-reload
systemctl enable --now node_exporter.socket node_exporter.service
echo "VERSION=$VER"
echo "UNITS=node_exporter.service,node_exporter.socket"
