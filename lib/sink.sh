#!/usr/bin/env bash
# bench sink up|down|status|reset: the hub box for the polled agents (reset: see sink_reset_hubs).

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
      node_ip=$(sink_addr_of node-exporter)
      glances_ip=$(sink_addr_of glances)
      log "sink: provisioning (hub ports open to the agent boxes only; UIs over an SSH tunnel)"
      cmd_provision sink
      ssh_box sink "mkdir -p /opt/bench/sink"
      scp_box sink "$BENCH_ROOT/sink" /opt/bench/
      ssh_box sink "bash /opt/bench/sink/up.sh '$node_ip' '$glances_ip'"
      sink_allow_boxes
      log "UIs: ssh -L 8090:127.0.0.1:8090 -L 7655:127.0.0.1:7655 root@$(box_addr sink)  then http://localhost:8090 and :7655";;
    down) ssh_box sink "cd /opt/bench/sink && docker compose down";;
    reset) shift; sink_reset_guard "$@"; sink_reset_hubs "$@";;
    status) ssh_box sink "cd /opt/bench/sink && docker compose ps && systemctl is-active glances-poller || true";;
    *) die "usage: bench sink up|down|status|reset [--dry-run] [--pulse-token NAME] (--all | box...)";;
  esac
}

# sink_allow_boxes: rewrite the sink's DOCKER-USER allow-list with every box that has an address
# (plain `ufw allow` does nothing for Docker-published ports), plus SINK_ALLOW_EXTRA (bench.env:
# the bed's private subnet, which Pulse's agent uses to reach its server).
sink_allow_boxes() {
  local n addrs=() key a
  # shellcheck disable=SC2206
  [[ -n "${SINK_ALLOW_EXTRA:-}" ]] && addrs=($SINK_ALLOW_EXTRA)
  for n in $(seq 0 $((BOX_COUNT - 1))); do
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

# sink_box_of AGENT [S]: the box that runs AGENT in slot S (default: SLOT or 0), or nothing.
sink_box_of() { box_running "$1" "${2:-${SLOT:-0}}"; }

# sink_addr_of AGENT [S]: that box's address, or empty when the agent has no box in the slot.
sink_addr_of() {
  local box
  box=$(sink_box_of "$@")
  [[ -n "$box" ]] || return 0
  box_addr "$box" 2>/dev/null || true
}

# sink_retarget S: re-template Prometheus' target and the Glances poller for slot S's boxes (a slot
# without node-exporter or glances blanks the target and stops the poller). The repo's sink/ is copied
# first, so the sink always runs the checked-out scripts.
sink_retarget() {
  local s=$1 node_ip="" glances_ip=""
  node_ip=$(sink_addr_of node-exporter "$s")
  glances_ip=$(sink_addr_of glances "$s")
  scp_box sink "$BENCH_ROOT/sink" /opt/bench/
  ssh_box sink "bash /opt/bench/sink/up.sh '$node_ip' '$glances_ip'" | grep -E "prometheus:|SINK_UP" || true
  sink_allow_boxes
}

# sink_reset_hubs [--dry-run] [--pulse-token NAME] (--all | BOX...): the hubs forget the named boxes
# (sink/reset-hubs.py explains why), Beszel's universal token stays permanent and, with --pulse-token, a
# scoped Pulse agent token for this slot is created and exported as PULSE_TOKEN for the installs that
# follow in this process. Hub admin credentials travel on stdin, never in argv; the token line never
# reaches the logs. Any failure aborts the caller.
sink_reset_hubs() {
  local a args=() out rc=0 line tok
  for a in "$@"; do args+=("$(printf '%q' "$a")"); done
  scp_box sink "$BENCH_ROOT/sink/reset-hubs.py" /opt/bench/sink/reset-hubs.py
  out=$(printf '%s\n' "${BESZEL_ADMIN_EMAIL:-}" "${BESZEL_ADMIN_PASSWORD:-}" "${BESZEL_TOKEN:-}" "${PULSE_ADMIN_USER:-}" "${PULSE_ADMIN_PASSWORD:-}" \
    | ssh_box_stdin sink "python3 /opt/bench/sink/reset-hubs.py ${args[*]}") || rc=$?
  while IFS= read -r line; do
    [[ "$line" == PULSE_TOKEN=* ]] && continue
    [[ -n "$line" ]] && log "sink: $line"
  done <<<"$out"
  [[ "$rc" == 0 ]] || die "sink: reset-hubs failed (exit $rc; hub admin credentials in bench.env? sink reachable?)"
  # A slot without a Pulse role returns no token line: grep's exit 1 must not trip errexit via pipefail.
  tok=$(grep '^PULSE_TOKEN=' <<<"$out" | tail -1 | cut -d= -f2- || true)
  if [[ -n "$tok" ]]; then
    export PULSE_TOKEN="$tok"
    log "sink: this slot's Pulse agent token is exported for the install (bench.env's PULSE_TOKEN is not used)"
  fi
}

# sink_reset_guard ARGS...: `bench sink reset --all` must not run while a slot's boxes are still measuring:
# it would forget the live systems/agents (and Pulse would revoke the token of the last one).
sink_reset_guard() {
  local all=0 dry=0 a f last now
  for a in "$@"; do [[ "$a" == --all ]] && all=1; [[ "$a" == --dry-run ]] && dry=1; done
  ((all && !dry)) || return 0
  now=$(date +%s)
  for f in "$BENCH_ROOT"/data/*/slots/slot-*.json; do
    [[ -f "$f" ]] || continue
    last=$(jq -r '[.boxes[].stop] | max // 0' "$f")
    ((last > now)) && die "sink reset --all refused: $(basename "$f") runs until $(date -u -d @"$last" +%FT%TZ); name the boxes instead"
  done
  return 0
}

# sink_status: the Prometheus target health and the poller's last line, so an unpolled row is visible.
sink_status() {
  ssh_box sink "printf 'sink: prometheus targets %s; poller %s\n' \
    \"\$(curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c 'import json,sys; print([(t[\"scrapeUrl\"], t[\"health\"]) for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]])' 2>/dev/null)\" \
    \"\$(tail -1 /var/log/glances-poller.log 2>/dev/null)\"" 2>/dev/null || echo "sink: unreachable"
}
