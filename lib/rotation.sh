#!/usr/bin/env bash
# The fixed agent order and the box rotation: agent i runs on box (i + k) mod 11 in cycle k.

AGENTS=(beszel netdata netdata-cloud glances node-exporter telegraf pulse datadog fivenines hetrixtools monitorable)
AGENT_COUNT=${#AGENTS[@]}

# agent_index NAME -> 0..10
agent_index() {
  local i
  for i in "${!AGENTS[@]}"; do
    [[ "${AGENTS[$i]}" == "$1" ]] && { printf '%s\n' "$i"; return 0; }
  done
  die "unknown agent $1"
}

# box_for INDEX CYCLE -> box-N
box_for() {
  printf 'box-%s\n' "$(( ($1 + $2) % AGENT_COUNT ))"
}

# agent_at BOX_NUMBER CYCLE -> agent name running on box-N in that cycle
agent_at() {
  printf '%s\n' "${AGENTS[$(( ($1 - $2 + AGENT_COUNT) % AGENT_COUNT ))]}"
}
