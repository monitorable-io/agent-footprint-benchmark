#!/usr/bin/env bash
# Docker publishes ports past ufw (DNAT happens before INPUT), so the sink's hub ports are gated in
# DOCKER-USER instead: new connections to them are dropped unless the source is an allowed box.
# Usage: firewall.sh <allowed-ip-or-cidr> [...]     (idempotent; rewrites the allow-list atomically)
#        firewall.sh --restore                          (replay the saved list; used by the systemd unit)
set -euo pipefail
PORTS=8090,8086,7655
SAVED=/etc/bench-sink-allow

restore=0
if [[ "${1:-}" == "--restore" ]]; then
  restore=1
  mapfile -t raw < <(grep -v '^[[:space:]]*$' "$SAVED" 2>/dev/null || true)
else
  raw=("$@")
fi
# Validate everything before any firewall state changes. A bad operator argument aborts; a bad
# saved entry on --restore is dropped so the gate still goes up (fail closed, never open).
addrs=()
for ip in "${raw[@]}"; do
  if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/([0-9]|[12][0-9]|3[012]))?$ ]]; then
    addrs+=("$ip")
  elif ((restore)); then
    echo "ignoring bad saved address $ip" >&2
  else
    echo "bad address $ip" >&2; exit 2
  fi
done

# The chain, rebuilt atomically: iptables-restore -n redefines only the chains it names.
{
  echo '*filter'
  echo ':BENCH-SINK - [0:0]'
  echo '-A BENCH-SINK -i lo -j RETURN'
  echo '-A BENCH-SINK -i docker0 -j RETURN'
  echo '-A BENCH-SINK -i br-+ -j RETURN'
  for ip in "${addrs[@]+"${addrs[@]}"}"; do echo "-A BENCH-SINK -s $ip -j RETURN"; done
  echo "-A BENCH-SINK -p tcp -m multiport --dports $PORTS -m conntrack --ctstate NEW -j DROP"
  echo 'COMMIT'
} | iptables-restore -n
# Docker never flushes an existing DOCKER-USER chain, so creating it here (before Docker starts at
# boot) means the gate is in place before any port is published.
iptables -N DOCKER-USER 2>/dev/null || true
iptables -C DOCKER-USER -j BENCH-SINK 2>/dev/null || iptables -I DOCKER-USER 1 -j BENCH-SINK

if ((!restore)); then
  umask 077
  : > "$SAVED"
  for ip in "${addrs[@]+"${addrs[@]}"}"; do printf '%s\n' "$ip" >> "$SAVED"; done
fi
echo "BENCH-SINK: ports $PORTS open to: ${addrs[*]+"${addrs[*]}"}"
