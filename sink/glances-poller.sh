#!/usr/bin/env bash
# Polls the Glances box's REST API at Glances' refresh period so the agent does real work.
# Usage: glances-poller.sh <glances-ip> [period-seconds]
set -u
ip=$1 period=${2:-3}
while true; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:61208/api/4/all")
  echo "$(date -u +%FT%TZ) $code"
  sleep "$period"
done
