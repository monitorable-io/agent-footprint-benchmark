#!/usr/bin/env bash
# Docker publishes ports past ufw (DNAT happens before INPUT), so the sink's hub ports are gated in
# DOCKER-USER instead: new connections to them are dropped unless the source is an allowed box.
# Usage: firewall.sh <allowed-ip> [<allowed-ip> ...]   (idempotent; rewrites the allow-list)
set -euo pipefail
PORTS=8090,8086,7655
ext=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$ext" ]] || { echo "no default interface" >&2; exit 1; }

iptables -N BENCH-SINK 2>/dev/null || true
iptables -F BENCH-SINK
for ip in "$@"; do
  [[ "$ip" =~ ^[0-9.]+$ ]] || { echo "bad address $ip" >&2; exit 2; }
  iptables -A BENCH-SINK -s "$ip" -j RETURN
done
iptables -A BENCH-SINK -p tcp -m multiport --dports "$PORTS" -m conntrack --ctstate NEW -j DROP
iptables -C DOCKER-USER -i "$ext" -j BENCH-SINK 2>/dev/null || iptables -I DOCKER-USER 1 -i "$ext" -j BENCH-SINK
echo "BENCH-SINK: ports $PORTS open to: ${*:-nobody}"
