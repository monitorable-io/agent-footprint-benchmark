#!/usr/bin/env bash
# bench cycle start <k> | status ; bench collect <k>
# A cycle: reimage the 11 agent boxes + control, provision, install (timed), then on every box a
# systemd timer fires the loaded hour at install+24h and stops the collector at install+25h, so the
# timeline holds even if the operator host disconnects.

YEAR=${YEAR:-$(date +%Y)}
IDLE_SECONDS=${IDLE_SECONDS:-86400}
LOAD_SECONDS=${LOAD_SECONDS:-3600}

# schedule_on BOX INSTALL_FINISHED_EPOCH: timers on the box for the load window and the stop.
schedule_on() {
  local box=$1 t0=$2
  local load_at=$((t0 + IDLE_SECONDS)) stop_at=$((t0 + IDLE_SECONDS + LOAD_SECONDS))
  ssh_box "$box" "systemctl stop bench-load.timer bench-stop.timer 2>/dev/null; \
    systemd-run --unit=bench-load --on-calendar='@$load_at' --timer-property=AccuracySec=1s \
      /usr/bin/env bash /opt/bench/load/loaded-window.sh $LOAD_SECONDS > /dev/null 2>&1; \
    systemd-run --unit=bench-stop --on-calendar='@$stop_at' --timer-property=AccuracySec=1s \
      /usr/bin/systemctl stop bench-collector > /dev/null 2>&1; \
    echo scheduled load=$load_at stop=$stop_at"
}

# cycle_one_box K BOX AGENT OUTNAME OUTDIR: reimage + provision + install + schedule for one box;
# writes schedule-<outname>.json. Polled ports are NOT opened here: cmd_install opens them to the
# sink only. Any failure is recorded in <outdir>/failures.log and does not stop the other boxes.
cycle_one_box() {
  local k=$1 box=$2 agent=$3 outname=$4 outdir=$5
  local flags=""
  [[ "$agent" == "hetrixtools" ]] && flags="--no-cron"
  [[ "$(box_ip "$box")" == lxd:* ]] || vm_reimage "$box"
  # shellcheck disable=SC2086
  cmd_provision "$box" $flags
  [[ -n "${BOX_SINK_IP:-}" ]] && sink_allow_box "$box"
  scp_box "$box" "$BENCH_ROOT/load" /opt/bench/
  cmd_install "$agent" "$box"
  local t0
  t0=$(jq -r '.finished | floor' "$BENCH_ROOT/.runs/$box-$agent-install.json")
  schedule_on "$box" "$t0"
  jq -n --arg agent "$agent" --arg box "$box" --argjson t0 "$t0" --argjson idle "$IDLE_SECONDS" --argjson load "$LOAD_SECONDS" \
    '{agent: $agent, box: $box, installFinished: $t0, loadStart: ($t0 + $idle), stop: ($t0 + $idle + $load)}' \
    > "$outdir/schedule-$outname.json"
  # The sink's Prometheus target and Glances poller follow the rotation: re-template after these rows.
  if [[ "$agent" == "node-exporter" || "$agent" == "glances" ]] && [[ -n "${BOX_SINK_IP:-}" ]]; then
    sink_retarget "$k"
  fi
}

# merge_meta META INSTALL SCHEDULE [FOOTPRINT] > merged meta.json for one agent+cycle.
merge_meta() {
  local meta=$1 install=$2 schedule=$3 footprint=${4:-}
  if [[ -n "$footprint" && -f "$footprint" ]]; then
    jq -s '.[0] * {install: .[1], schedule: .[2], footprint: .[3]}' "$meta" "$install" "$schedule" "$footprint"
  else
    jq -s '.[0] * {install: .[1], schedule: .[2]}' "$meta" "$install" "$schedule"
  fi
}

cmd_cycle() {
  load_env
  local sub=${1:-}
  case "$sub" in
    start)
      local k=${2:-}
      [[ "$k" =~ ^[0-2]$ ]] || die "usage: bench cycle start <0|1|2>"
      local outdir="$BENCH_ROOT/data/$YEAR/cycle-$((k + 1))"
      mkdir -p "$outdir"
      export CYCLE=$k
      : > "$outdir/failures.log"
      log "cycle $((k + 1)): control box"
      ( cycle_one_box "$k" control none control "$outdir" ) || echo "control: setup failed (see output above)" >> "$outdir/failures.log"
      local i
      for i in $(seq 0 $((AGENT_COUNT - 1))); do
        local agent box
        agent=${AGENTS[$i]}; box=$(box_for "$i" "$k")
        log "cycle $((k + 1)): $agent on $box"
        ( cycle_one_box "$k" "$box" "$agent" "$agent" "$outdir" ) || echo "$agent on $box: setup failed" >> "$outdir/failures.log"
      done
      jq -s '{cycle: '"$((k + 1))"', boxes: .}' "$outdir"/schedule-*.json > "$outdir/schedule.json"
      [[ -s "$outdir/failures.log" ]] && log "FAILURES: $(paste -sd';' "$outdir/failures.log")"
      log "cycle $((k + 1)) running; collect after $(date -u -d @"$(jq -r '[.boxes[].stop] | max' "$outdir/schedule.json")" +%FT%TZ)";;
    status)
      local k=${2:-${CYCLE:-0}} i
      for i in $(seq 0 $((AGENT_COUNT - 1))); do
        local box; box=$(box_for "$i" "$k")
        printf '%-14s %-8s ' "${AGENTS[$i]}" "$box"
        ssh_box "$box" "printf '%s rows=%s next=%s\n' \"\$(systemctl is-active bench-collector)\" \"\$(wc -l < /var/lib/bench/samples.csv 2>/dev/null)\" \"\$(systemctl list-timers bench-load.timer --no-legend | awk '{print \$1, \$2}')\"" 2>/dev/null || echo unreachable
      done
      printf '%-14s %-8s ' control control
      ssh_box control "printf '%s rows=%s\n' \"\$(systemctl is-active bench-collector)\" \"\$(wc -l < /var/lib/bench/samples.csv 2>/dev/null)\"" 2>/dev/null || echo unreachable
      [[ -n "${BOX_SINK_IP:-}" ]] && sink_status;;
    *) die "usage: bench cycle start <k> | status [<k>]";;
  esac
}

# collect_box BOX AGENT OUTNAME OUTDIR: footprint + journal volume now, then fetch samples/events/
# install from the box, merge the meta, gzip the samples. OUTNAME names the files (control = agent none).
collect_box() {
  local box=$1 agent=$2 outname=$3 outdir=$4
  local sched="$outdir/schedule-$outname.json"
  [[ -f "$sched" ]] || die "$outname: no $sched (was the cycle started?)"
  local s e
  s=$(jq -r '.installFinished + 3600' "$sched"); e=$(jq -r '.loadStart' "$sched")
  ssh_box "$box" "bash /opt/bench/base/footprint.sh $agent $s $e" || log "$outname: footprint not measured"
  fetch_box "$box" /var/lib/bench/samples.csv "$outdir/$outname.csv"
  fetch_box "$box" /var/lib/bench/events.csv "$outdir/$outname.events.csv"
  fetch_box "$box" /var/lib/bench/install.json "$outdir/$outname.install.json"
  fetch_box "$box" /var/lib/bench/footprint.json "$outdir/$outname.footprint.json" 2>/dev/null || true
  merge_meta "$BENCH_ROOT/agents/$agent/meta.json" "$outdir/$outname.install.json" "$sched" "$outdir/$outname.footprint.json" \
    > "$outdir/$outname.meta.json"
  rm -f "$outdir/$outname.install.json" "$outdir/$outname.footprint.json"
  gzip -f "$outdir/$outname.csv"
  log "$outname: $(zcat "$outdir/$outname.csv.gz" | wc -l) rows"
}

cmd_collect() {
  load_env
  local k=${1:-}
  [[ "$k" =~ ^[0-2]$ ]] || die "usage: bench collect <0|1|2>"
  local outdir="$BENCH_ROOT/data/$YEAR/cycle-$((k + 1))" i
  [[ -d "$outdir" ]] || die "no $outdir: was the cycle started?"
  ( collect_box control none control "$outdir" ) || log "control: not collected"
  for i in $(seq 0 $((AGENT_COUNT - 1))); do
    ( collect_box "$(box_for "$i" "$k")" "${AGENTS[$i]}" "${AGENTS[$i]}" "$outdir" ) || log "${AGENTS[$i]}: not collected"
  done
}

cmd_summarize() {
  local year=${1:-$YEAR}
  python3 "$BENCH_ROOT/summarize.py" "$BENCH_ROOT/data/$year"
}
