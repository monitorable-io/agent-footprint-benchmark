#!/usr/bin/env bash
# bench cycle plan [<s>] | start <s> | status [<s>] ; bench collect <s>
# A slot (s = 0..3): rebuild the 9 boxes in place, provision, install the slot's roles (timed), then on
# every box a systemd timer fires the loaded hour at install+24h and stops the collector at install+25h,
# so the timeline holds even if the operator host disconnects. Which role a box gets, and which run of
# that role it is, comes from lib/rotation.sh; the box's schedule is filed under the cycle directory of
# that run (run n -> data/<year>/cycle-<n+1>/), and bench collect <s> fetches the slot's boxes into the
# same places, so summarize.py reads three cycles per role as before. A slot manifest goes to
# data/<year>/slots/slot-<s>.json.

YEAR=${YEAR:-$(date +%Y)}
IDLE_SECONDS=${IDLE_SECONDS:-86400}
LOAD_SECONDS=${LOAD_SECONDS:-3600}

slots_dir() { printf '%s/data/%s/slots' "$BENCH_ROOT" "$YEAR"; }
cycle_dir() { printf '%s/data/%s/%s' "$BENCH_ROOT" "$YEAR" "$1"; }   # $1 = cycle-N

# schedule_on BOX INSTALL_FINISHED_EPOCH: timers on the box for the load window and the stop. Leftovers
# of an earlier run are cleared first (tolerant); the two systemd-run calls and a check that both timers
# exist are chained, so a refused timer fails the step instead of leaving a box with no load hour.
schedule_on() {
  local box=$1 t0=$2
  local load_at=$((t0 + IDLE_SECONDS)) stop_at=$((t0 + IDLE_SECONDS + LOAD_SECONDS))
  ssh_box "$box" "systemctl stop bench-load.timer bench-stop.timer bench-load.service bench-stop.service 2>/dev/null; \
    systemctl reset-failed bench-load.service bench-stop.service 2>/dev/null; \
    systemd-run --unit=bench-load --on-calendar='@$load_at' --timer-property=AccuracySec=1s \
      /usr/bin/env bash /opt/bench/load/loaded-window.sh $LOAD_SECONDS > /dev/null && \
    systemd-run --unit=bench-stop --on-calendar='@$stop_at' --timer-property=AccuracySec=1s \
      /usr/bin/systemctl stop bench-collector > /dev/null && \
    [ \"\$(systemctl list-timers --all bench-load.timer bench-stop.timer --no-legend | grep -c .)\" = 2 ] && \
    echo scheduled load=$load_at stop=$stop_at"
}

# reset_log_unless_filtered FILE: a full slot starts its failure log afresh; a BENCH_ONLY_BOXES redo appends.
reset_log_unless_filtered() {
  if [[ -z "${BENCH_ONLY_BOXES:-}" ]]; then : > "$1"; else touch "$1"; fi
}

# cycle_one_box SLOT BOX ROLE RUN OUTNAME OUTDIR: rebuild + provision + install + schedule for one box;
# writes OUTDIR/schedule-<outname>.json. Polled ports are NOT opened here: cmd_install opens them to the
# sink only. Any failure is recorded by the caller and does not stop the other boxes.
cycle_one_box() {
  local s=$1 box=$2 agent=$3 run=$4 outname=$5 outdir=$6
  local flags=""
  [[ "$agent" == "hetrixtools" ]] && flags="--no-cron"
  [[ "$(box_ip "$box")" == lxd:* ]] || vm_reimage "$box"
  # shellcheck disable=SC2086
  cmd_provision "$box" $flags
  [[ -n "${BOX_SINK_IP:-}" ]] && sink_allow_box "$box"
  scp_box "$box" "$BENCH_ROOT/load" /opt/bench/
  cmd_install "$agent" "$box"
  local rec="$BENCH_ROOT/.runs/$box-$agent-install.json" t0
  t0=$(jq -r '.finished | floor' "$rec")
  schedule_on "$box" "$t0"
  jq -n --arg agent "$agent" --arg box "$box" --argjson slot "$s" --argjson run "$run" --argjson t0 "$t0" \
    --argjson idle "$IDLE_SECONDS" --argjson load "$LOAD_SECONDS" \
    --arg cpu "$(jq -r '.cpu_model // "unknown"' "$rec")" --argjson vcpus "$(jq -r '.vcpus // 0' "$rec")" \
    '{agent: $agent, box: $box, slot: $slot, run: $run, installFinished: $t0, loadStart: ($t0 + $idle),
      stop: ($t0 + $idle + $load), cpuModel: $cpu, vcpus: $vcpus}' > "$outdir/schedule-$outname.json"
  # The sink's Prometheus target and Glances poller follow the schedule: re-template after these rows.
  if [[ "$agent" == "node-exporter" || "$agent" == "glances" ]] && [[ -n "${BOX_SINK_IP:-}" ]]; then
    sink_retarget "$s"
  fi
}

# regen_cycle_schedule CYCLE_DIR: schedule.json = every schedule-*.json filed there so far.
regen_cycle_schedule() {
  local cdir=$1 n=${1##*-}
  compgen -G "$cdir/schedule-*.json" > /dev/null || return 0
  jq -s --argjson c "$n" '{cycle: $c, boxes: .}' "$cdir"/schedule-*.json > "$cdir/schedule.json"
}

# write_slot_manifest SLOT STARTED_EPOCH: data/<year>/slots/slot-<s>.json from the slot's schedule files.
# Always the whole slot (BENCH_ONLY_BOXES is ignored here): a one-box redo must not shrink the manifest.
write_slot_manifest() {
  local s=$1 started=$2 box role run cyc outname f files=()
  while read -r _ box role run cyc outname; do
    f="$(cycle_dir "$cyc")/schedule-$outname.json"
    [[ -f "$f" ]] && files+=("$f")
  done < <(unset BENCH_ONLY_BOXES; slot_plan "$s")
  if ((${#files[@]})); then
    jq -s --argjson s "$s" --argjson st "$started" '{slot: $s, startedAt: $st, boxes: [.[] | select(.slot == $s)]}' "${files[@]}"
  else
    jq -n --argjson s "$s" --argjson st "$started" '{slot: $s, startedAt: $st, boxes: []}'
  fi > "$(slots_dir)/slot-$s.json"
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
  local sub=${1:-} s=${2:-}
  case "$sub" in
    plan)
      if [[ -z "$s" ]]; then
        for s in $(seq 0 $((SLOT_COUNT - 1))); do slot_plan "$s"; done
      else
        [[ "$s" =~ ^[0-3]$ ]] || die "usage: bench cycle plan [<0|1|2|3>]"
        slot_plan "$s"
      fi;;
    start)
      load_env
      [[ "$s" =~ ^[0-3]$ ]] || die "usage: bench cycle start <0|1|2|3>"
      local sd; sd=$(slots_dir); mkdir -p "$sd"
      local failures="$sd/slot-$s.failures.log" started line box role run cyc outname outdir touched=()
      local lines; mapfile -t lines < <(slot_plan "$s")
      ((${#lines[@]})) || die "no box in slot $s matches BENCH_ONLY_BOXES='${BENCH_ONLY_BOXES:-}' (space-separated box names, e.g. \"box-4 box-7\")"
      [[ -z "${BENCH_ONLY_BOXES:-}" ]] || log "slot $s: redoing only ${BENCH_ONLY_BOXES} (failures log appended, manifest covers the whole slot)"
      reset_log_unless_filtered "$failures"
      started=$(date +%s)
      export SLOT=$s
      # The hubs must forget the boxes being rebuilt first (full slot: every record; redo: those boxes).
      # shellcheck disable=SC2086
      [[ -n "${BOX_SINK_IP:-}" ]] && sink_reset_hubs ${BENCH_ONLY_BOXES:-}
      [[ -n "${BOX_SINK_IP:-}" ]] && sink_retarget "$s"
      for line in "${lines[@]}"; do
        read -r _ box role run cyc outname <<<"$line"
        outdir=$(cycle_dir "$cyc"); mkdir -p "$outdir"; touched+=("$outdir")
        log "slot $s: $role run $((run + 1)) ($cyc) on $box"
        run_isolated "$failures" "$role on $box: setup failed (run $((run + 1)), $cyc)" cycle_one_box "$s" "$box" "$role" "$run" "$outname" "$outdir"
      done
      for outdir in $(printf '%s\n' "${touched[@]}" | sort -u); do regen_cycle_schedule "$outdir"; done
      write_slot_manifest "$s" "$started"
      [[ -s "$failures" ]] && log "FAILURES: $(paste -sd';' "$failures")"
      local last; last=$(jq -r '[.boxes[].stop] | max // empty' "$sd/slot-$s.json")
      [[ -n "$last" ]] && log "slot $s running; collect after $(date -u -d @"$last" +%FT%TZ)"
      return 0;;
    status)
      load_env
      s=${s:-${SLOT:-0}}
      [[ "$s" =~ ^[0-3]$ ]] || die "usage: bench cycle status [<0|1|2|3>]"
      local box role run cyc outname
      while read -r _ box role run cyc outname; do
        printf '%-14s %-8s %-8s ' "$outname" "$box" "$cyc"
        ssh_box "$box" "printf '%s rows=%s next=%s\n' \"\$(systemctl is-active bench-collector)\" \"\$(wc -l < /var/lib/bench/samples.csv 2>/dev/null)\" \"\$(systemctl list-timers bench-load.timer --no-legend | awk '{print \$1, \$2}')\"" 2>/dev/null || echo unreachable
      done < <(slot_plan "$s")
      [[ -n "${BOX_SINK_IP:-}" ]] && sink_status
      return 0;;
    *) die "usage: bench cycle plan [<s>] | start <s> | status [<s>]";;
  esac
}

# collect_box BOX AGENT OUTNAME OUTDIR: footprint + journal volume now, then fetch samples/events/
# install from the box, merge the meta, gzip the samples. OUTNAME names the files (control = agent none).
collect_box() {
  local box=$1 agent=$2 outname=$3 outdir=$4
  local sched="${outdir:?}/schedule-${outname:?}.json"
  [[ -f "$sched" ]] || die "$outname: no $sched (was the slot started?)"
  local s e
  s=$(jq -r '.installFinished + 3600' "$sched"); e=$(jq -r '.loadStart' "$sched")
  ssh_box "$box" "bash /opt/bench/base/footprint.sh $agent $s $e" || log "$outname: footprint not measured"
  fetch_box "$box" /var/lib/bench/samples.csv "$outdir/$outname.csv"
  fetch_box "$box" /var/lib/bench/events.csv "$outdir/$outname.events.csv"
  fetch_box "$box" /var/lib/bench/install.json "$outdir/$outname.install.json"
  fetch_box "$box" /var/lib/bench/footprint.json "$outdir/$outname.footprint.json" 2>/dev/null || true
  merge_meta "$BENCH_ROOT/agents/$agent/meta.json" "$outdir/$outname.install.json" "$sched" "$outdir/$outname.footprint.json" \
    > "$outdir/$outname.meta.json"
  rm -f "${outdir:?}/${outname:?}.install.json" "${outdir:?}/${outname:?}.footprint.json"
  gzip -f "$outdir/$outname.csv"
  log "$outname: $(zcat "$outdir/$outname.csv.gz" | wc -l) rows -> $outdir"
}

cmd_collect() {
  load_env
  local s=${1:-}
  [[ "$s" =~ ^[0-3]$ ]] || die "usage: bench collect <0|1|2|3>"
  local lines line box role run cyc outname outdir
  mkdir -p "$(slots_dir)"; reset_log_unless_filtered "$(slots_dir)/slot-$s.collect-failures.log"
  mapfile -t lines < <(slot_plan "$s")
  for line in "${lines[@]}"; do
    read -r _ box role run cyc outname <<<"$line"
    outdir=$(cycle_dir "$cyc")
    [[ -d "$outdir" ]] || { log "$outname: no $outdir (was slot $s started?)"; continue; }
    run_isolated "$(slots_dir)/slot-$s.collect-failures.log" "$outname on $box: not collected" collect_box "$box" "$role" "$outname" "$outdir"
  done
  local f; f="$(slots_dir)/slot-$s.collect-failures.log"
  [[ -s "$f" ]] && log "NOT COLLECTED: $(paste -sd';' "$f")"
  return 0
}

cmd_summarize() {
  local year=${1:-$YEAR}
  python3 "$BENCH_ROOT/summarize.py" "$BENCH_ROOT/data/$year"
}
