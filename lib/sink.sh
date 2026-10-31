#!/usr/bin/env bash
# bench sink up|down|status: the hub box for the polled agents.

# box_addr NAME: the address other boxes use to reach NAME (lxd: boxes resolve to their first IPv4).
box_addr() {
  local ip
  ip=$(box_ip "$1")
  if [[ "$ip" == lxd:* ]]; then lxc list "${ip#lxd:}" -c 4 --format csv | tr -d '"' | awk 'NF {print $1; exit}'; else printf '%s' "$ip"; fi
}

cmd_sink() {
  load_env
  case "${1:-}" in
    up)
      local node_ip="" glances_ip=""
      [[ -n "${BOX_BOX_0_IP:-}" ]] && node_ip=$(box_addr "$(sink_box_of node-exporter)" 2>/dev/null || true)
      [[ -n "${BOX_BOX_0_IP:-}" ]] && glances_ip=$(box_addr "$(sink_box_of glances)" 2>/dev/null || true)
      log "sink: provisioning (hub ports open to the agent boxes only; UIs over an SSH tunnel)"
      cmd_provision sink
      ssh_box sink "mkdir -p /opt/bench/sink"
      scp_box sink "$BENCH_ROOT/sink" /opt/bench/
      ssh_box sink "bash /opt/bench/sink/up.sh '$node_ip' '$glances_ip'"
      sink_allow_boxes
      log "UIs: ssh -L 8090:127.0.0.1:8090 -L 7655:127.0.0.1:7655 root@$(box_addr sink)  then http://localhost:8090 and :7655";;
    down) ssh_box sink "cd /opt/bench/sink && docker compose down";;
    status) ssh_box sink "cd /opt/bench/sink && docker compose ps && systemctl is-active glances-poller || true";;
    *) die "usage: bench sink up|down|status";;
  esac
}

# sink_allow_boxes: rewrite the sink's DOCKER-USER allow-list with every box that has an address
# (plain `ufw allow` does nothing for Docker-published ports).
sink_allow_boxes() {
  local n addrs=() key a
  for n in $(seq 0 $((AGENT_COUNT - 1))); do
    key="BOX_BOX_${n}_IP"
    [[ -n "${!key:-}" ]] || continue
    a=$(box_addr "box-$n" 2>/dev/null) || continue
    [[ -n "$a" ]] && addrs+=("$a")
  done
  local uniq
  uniq=$(printf '%s\n' "${addrs[@]+"${addrs[@]}"}" | sort -u | paste -sd' ' -)
  ssh_box sink "bash /opt/bench/sink/firewall.sh $uniq"
}

# sink_allow_box BOX: after a box is (re)created, refresh the whole allow-list.
sink_allow_box() { sink_allow_boxes; }

# sink_box_of AGENT [K]: the box that runs AGENT in cycle K (default: CYCLE or 0).
sink_box_of() {
  local idx
  idx=$(agent_index "$1")
  box_for "$idx" "${2:-${CYCLE:-0}}"
}

# sink_retarget K: re-template Prometheus' target and the Glances poller for cycle K's boxes.
sink_retarget() {
  local k=$1 node_ip="" glances_ip=""
  node_ip=$(box_addr "$(sink_box_of node-exporter "$k")" 2>/dev/null || true)
  glances_ip=$(box_addr "$(sink_box_of glances "$k")" 2>/dev/null || true)
  ssh_box sink "bash /opt/bench/sink/up.sh '$node_ip' '$glances_ip'" | grep -E "prometheus:|SINK_UP" || true
  sink_allow_boxes
}

# sink_status: the Prometheus target health and the poller's last line, so an unpolled row is visible.
sink_status() {
  ssh_box sink "printf 'sink: prometheus targets %s; poller %s\n' \
    \"\$(curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c 'import json,sys; print([(t[\"scrapeUrl\"], t[\"health\"]) for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]])' 2>/dev/null)\" \
    \"\$(tail -1 /var/log/glances-poller.log 2>/dev/null)\"" 2>/dev/null || echo "sink: unreachable"
}
