#!/usr/bin/env bash
# Runs on the sink box as root: templates the configs, starts the hubs, prints what the operator needs.
# Usage: up.sh <node-exporter-ip-or-empty> <glances-ip-or-empty>
set -euo pipefail
node_ip=${1:-} glances_ip=${2:-}
cd /opt/bench/sink
sed "s/@NODE_EXPORTER_IP@/${node_ip:-127.0.0.1}/" prometheus.yml.tmpl > prometheus.yml
docker compose pull -q
docker compose up -d --remove-orphans
if [[ -n "$glances_ip" ]]; then
  sed "s/@GLANCES_IP@/$glances_ip/" glances-poller.service.tmpl > /etc/systemd/system/glances-poller.service
  systemctl daemon-reload
  systemctl enable --now glances-poller
  systemctl restart glances-poller
fi
echo "SINK_UP"
echo "beszel hub:   port 8090, reachable from the agent boxes and over an SSH tunnel only (first visit creates the admin: do it through the tunnel; Add system -> binary -> KEY/TOKEN into bench.env)"
echo "pulse:        port 7655, same reach (bootstrap token: docker exec pulse /app/pulse bootstrap-token; Settings -> Infrastructure -> Install on a host -> token into bench.env)"
echo "influxdb 1.x: :8086 (Telegraf's stock output creates its database)"
echo "prometheus:   scraping ${node_ip:-<unset>}:9100 every 1m"
