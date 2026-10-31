#!/usr/bin/env bash
# bench install <agent> <box>: the documented install, timed and recorded, then the collector.

# agent_env AGENT: the lines of the agent's private env file, from bench.env plus derived sink addresses.
agent_env() {
  local agent=$1 meta="$BENCH_ROOT/agents/$1/meta.json" key sink
  sink=${BOX_SINK_IP:-}
  [[ "$sink" == lxd:* ]] && sink=$(box_addr sink)
  if jq -e '.env | index("SINK_IP") or index("BESZEL_HUB_URL") or index("PULSE_URL")' "$meta" > /dev/null && [[ -z "$sink" ]]; then
    die "agent $agent needs the sink but BOX_SINK_IP is empty (bench vm create sink && bench sink up)"
  fi
  export BESZEL_HUB_URL="${BESZEL_HUB_URL:-http://$sink:8090}"
  # Pulse's agent refuses a plain-HTTP server URL unless the host is loopback or a private address:
  # it reaches the sink over the bed's private network (BOX_SINK_PRIVATE_IP) when there is one.
  export PULSE_URL="${PULSE_URL:-http://${BOX_SINK_PRIVATE_IP:-$sink}:7655}"
  export SINK_IP="$sink"
  # Only upper-case names listed by the agent; never the operator's own credentials.
  while read -r key; do
    [[ -n "$key" ]] || continue
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "agent $agent asks for an odd env key: $key"
    case "$key" in ONIDEL_*|SSH_*|BOX_*) die "agent $agent must not receive $key";; esac
    printf '%s=%q\n' "$key" "${!key:-}"
  done < <(jq -r '.env[]?' "$meta")
}

# collector_globs AGENT: "--globs a --globs b" from meta.json.
collector_globs() {
  jq -r '.cgroupGlobs[] | "--globs " + .' "$BENCH_ROOT/agents/$1/meta.json" | paste -sd' ' -
}

cmd_install() {
  local agent=${1:-} box=${2:-}
  [[ -n "$agent" && -n "$box" ]] || die "usage: bench install <agent> <box>"
  load_env
  local dir="$BENCH_ROOT/agents/$agent"
  [[ -f "$dir/meta.json" ]] || die "unknown agent $agent (agents/*/)"
  local envfile
  envfile=$(mktemp)
  chmod 0600 "$envfile"
  agent_env "$agent" > "$envfile"

  log "$box: staging $agent"
  ssh_box "$box" "mkdir -p /opt/bench/agents"
  scp_box "$box" "$dir" /opt/bench/agents/
  scp_box "$box" "$BENCH_ROOT/base" /opt/bench/
  scp_box "$box" "$BENCH_ROOT/collector" /opt/bench/
  scp_box "$box" "$envfile" "/opt/bench/agents/$agent/env"
  rm -f "$envfile"
  ssh_box "$box" "chmod 0600 /opt/bench/agents/$agent/env"

  # Polled ports open to the sink only: these are unauthenticated endpoints on a public box.
  local port sink=${SINK_IP:-}
  for port in $(jq -r '.ports[]?' "$dir/meta.json"); do
    if [[ -n "$sink" ]]; then
      ssh_box "$box" "ufw allow from $sink to any port $port proto tcp > /dev/null"
    else
      ssh_box "$box" "ufw allow $port/tcp > /dev/null"
    fi
  done

  log "$box: installing $agent (documented command, timed, 30 min cap)"
  ssh_box "$box" "timeout 1800 bash /opt/bench/base/install-runner.sh $agent"

  local net_ports
  net_ports=$(jq -r '.ports | map(tostring) | join(",")' "$dir/meta.json")
  # A fresh box has no collector running; on a redo the unit may be active with old globs (the vendor
  # install's apt run can even restart it through needrestart), so restart it and start the files afresh.
  log "$box: starting the collector"
  ssh_box "$box" "printf 'GLOBS=%s\nNET_PORTS=%s\n' '$(collector_globs "$agent")' '${net_ports:+--net-ports $net_ports}' > /etc/bench-collector.env \
    && cp /opt/bench/collector/bench-collector.service /etc/systemd/system/ \
    && systemctl daemon-reload && systemctl stop bench-collector > /dev/null 2>&1; rm -f /var/lib/bench/samples.csv /var/lib/bench/events.csv \
    && systemctl enable bench-collector > /dev/null 2>&1 && systemctl restart bench-collector && systemctl is-active bench-collector"
  mkdir -p "$BENCH_ROOT/.runs"
  rm -f "${BENCH_ROOT:?}/.runs/$box-$agent-install.json"   # never let a stale record stand in for a failed fetch
  fetch_box "$box" /var/lib/bench/install.json "$BENCH_ROOT/.runs/$box-$agent-install.json"
  jq -r '"\(.agent): \(.status) in \(.seconds)s, version \(.version), units \(.units|join(","))"' "$BENCH_ROOT/.runs/$box-$agent-install.json"
}
