#!/usr/bin/env bash
# bench auto init|tick|decide|status|resume|cron-line: the unattended runner for the rest of a run.
#
# A cron entry on this host calls `bench auto tick` every few minutes; no interactive session is
# needed. Each tick derives the state from files on disk (the slot manifests, the collected samples
# and the markers in data/<year>/auto/), does what is due, and stops:
#   - the latest slot's boxes are still measuring        -> nothing (the +1 h status check when due)
#   - its last stop time has passed (+ grace)             -> `collect`; a failure HALTS the runner,
#                                                           because the next start would rebuild the
#                                                           uncollected boxes and lose their data
#   - it is collected and the plan has a later slot      -> `cycle start` of that slot, then
#                                                           `cycle status` + a hub check right away
#   - the last slot is collected                         -> `summarize`, RUN COMPLETE
# Every step goes to the run log (docs/RUN-<year>.md in the RUNLOG_DIR worktree of the data branch),
# committed and pushed, so progress is visible on GitHub without a session on this host. A halt needs
# a human: fix, then `bench auto resume`. Nothing here destroys a box.
#
# Markers (data/<year>/auto/): slot-<s>.collected, slot-<s>.status-1h, halted (the reason), done,
# push-failed, STATUS (one line, rewritten each tick), auto.log (every tick's output), tick.lock.
# Optional: AUTO_NOTIFY_URL (bench.env) gets one POST per event (ntfy-style: Title header + body).
#
# errexit: the actions (auto_collect, auto_start, auto_adopt, auto_finish) are called as plain
# statements and report through the halted marker, never through their exit status. Inside them a
# bench command runs as `set +e; ( set -e; cmd ); rc=$?; set -e`. A `( set -e; … )` inside an `if !`
# or an `||` list would NOT have -e in force (bash ignores -e in those contexts), and with it
# run_isolated's bookkeeping of a failed box would be lost: that is the data-loss path.

AUTO_COLLECT_GRACE=${AUTO_COLLECT_GRACE:-120}   # seconds after a slot's last stop before collecting
AUTO_STATUS_AFTER=${AUTO_STATUS_AFTER:-3600}    # the +1 h status check
AUTO_TICK_MINUTES=${AUTO_TICK_MINUTES:-5}       # for the cron line

auto_dir() { printf '%s/data/%s/auto' "$BENCH_ROOT" "$YEAR"; }
runlog_dir() { printf '%s' "${RUNLOG_DIR:-${BENCH_ROOT}-runlog}"; }
runlog_branch() { printf '%s' "${RUNLOG_BRANCH:-data/run-$YEAR}"; }
runlog_file() { printf '%s/docs/RUN-%s.md' "$(runlog_dir)" "$YEAR"; }
auto_now() { printf '%s' "${AUTO_NOW:-$(date +%s)}"; }   # tests pin the clock
auto_utc() { date -u -d @"$1" +%FT%TZ; }
auto_manifest() { printf '%s/slot-%s.json' "$(slots_dir)" "$1"; }
auto_field() { jq -r "$2" "$(auto_manifest "$1")" 2>/dev/null || true; }
auto_rows() { BENCH_ONLY_BOXES='' slot_plan "$1"; }   # the whole slot, whatever the caller's filter

# auto_latest_slot -> the highest slot with a manifest, or nothing
auto_latest_slot() {
  local s latest=""
  for s in $(seq 0 $((SLOT_COUNT - 1))); do [[ -f "$(auto_manifest "$s")" ]] && latest=$s; done
  printf '%s' "$latest"
}

# auto_samples_present SLOT: every row of the slot has its samples file (collected by hand, or by us)
auto_samples_present() {
  local cyc outname
  while read -r _ _ _ _ cyc outname; do
    [[ -f "$(cycle_dir "$cyc")/$outname.csv.gz" ]] || return 1
  done < <(auto_rows "$1")
  return 0
}

# auto_verify_collected SLOT -> the rows whose samples are missing, empty or older than the slot's
# start ("" when every row is fine). Independent of the collect's own bookkeeping.
auto_verify_collected() {
  local s=$1 started cyc outname f bad=()
  started=$(auto_field "$s" '.startedAt // 0')
  while read -r _ _ _ _ cyc outname; do
    f="$(cycle_dir "$cyc")/$outname.csv.gz"
    if [[ ! -s "$f" ]]; then bad+=("$outname: no samples file")
    elif (( $(stat -c %Y "$f") < started )); then bad+=("$outname: samples older than the slot start"); fi
  done < <(auto_rows "$s")
  ((${#bad[@]})) && printf '%s; ' "${bad[@]}" | sed 's/; $//'
  return 0
}

# auto_decide -> one line:
#   halted | done | none | bad-manifest S | wait EPOCH | collect S | adopt S | status1h S | start S
auto_decide() {
  local now s last started
  now=$(auto_now)
  [[ -f "$(auto_dir)/halted" ]] && { echo halted; return 0; }
  [[ -f "$(auto_dir)/done" ]] && { echo "done"; return 0; }
  s=$(auto_latest_slot)
  [[ -n "$s" ]] || { echo none; return 0; }
  if [[ ! -f "$(auto_dir)/slot-$s.collected" ]]; then
    last=$(auto_field "$s" '[.boxes[].stop] | max // empty')
    started=$(auto_field "$s" '.startedAt // empty')
    if ! [[ "$last" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]]; then echo "bad-manifest $s"; return 0; fi
    if auto_samples_present "$s"; then echo "adopt $s"; return 0; fi
    if ((now >= last + AUTO_COLLECT_GRACE)); then echo "collect $s"; return 0; fi
    if [[ ! -f "$(auto_dir)/slot-$s.status-1h" ]] && ((now >= started + AUTO_STATUS_AFTER)); then echo "status1h $s"; return 0; fi
    echo "wait $((last + AUTO_COLLECT_GRACE))"; return 0
  fi
  if ((s < SLOT_COUNT - 1)); then echo "start $((s + 1))"; return 0; fi
  echo "done"
}

auto_write_status() {
  local extra=""
  [[ -f "$(auto_dir)/push-failed" ]] && extra=" [run-log push failing since $(cat "$(auto_dir)/push-failed")]"
  printf '%s %s%s\n' "$(date -u +%FT%TZ)" "$1" "$extra" > "$(auto_dir)/STATUS"
  log "auto: $1$extra"
}

auto_notify() {   # auto_notify TITLE BODY (no-op without AUTO_NOTIFY_URL)
  [[ -n "${AUTO_NOTIFY_URL:-}" ]] || return 0
  curl -fsS -m 20 -H "Title: $1" -d "$2" "$AUTO_NOTIFY_URL" > /dev/null 2>&1 || log "auto: notify failed"
  return 0
}

auto_code_ref() {
  printf '%s %s' "$(git -C "$BENCH_ROOT" branch --show-current 2>/dev/null)" "$(git -C "$BENCH_ROOT" rev-parse --short HEAD 2>/dev/null)"
}

# --- run log ----------------------------------------------------------------------------------------
# The run log is pushed: the automated lines carry derived states, never raw box output, and any
# IPv4 address or URL that still reaches them is redacted here (the local auto.log keeps the full text).
runlog_redact() { sed -E 's#https?://[^ )>]+#<url>#g; s#\b([0-9]{1,3}\.){3}[0-9]{1,3}\b#<ip>#g'; }

# runlog_edit MODE PREFIX LINE: mark = replace the line "- [ ] PREFIX…" with LINE (nothing to do when
# a "- [x] PREFIX…" line already exists); after = insert LINE after the line "- [x] PREFIX…";
# append = add LINE at the end. A missing anchor appends LINE instead. The file is replaced atomically.
runlog_edit() {
  local f line; f=$(runlog_file)
  line=$(runlog_redact <<<"$3")
  [[ -f "$f" ]] || { log "auto: no run log at $f (bench auto init adds the worktree); not recorded: $line"; return 0; }
  python3 -I - "$f" "$1" "$2" "$line" <<'PY'
import os, sys
path, mode, prefix, line = sys.argv[1:5]
lines = open(path).read().split("\n")
hit = False
if mode == "mark" and any(l.startswith("- [x] " + prefix) for l in lines):
    sys.exit(0)   # already recorded (by a hand collect, or an earlier tick)
for i, l in enumerate(lines):
    if mode == "mark" and l.startswith("- [ ] " + prefix):
        lines[i] = line; hit = True; break
    if mode == "after" and l.startswith("- [x] " + prefix):
        lines.insert(i + 1, line); hit = True; break
if not hit:
    while lines and lines[-1] == "":
        lines.pop()
    lines += [line, ""]
tmp = path + ".tmp"
open(tmp, "w").write("\n".join(lines))
os.replace(tmp, path)
PY
}
runlog_mark() { runlog_edit mark "$1" "- [x] $1 $2"; }      # runlog_mark PREFIX TEXT
runlog_after() { runlog_edit after "$1" "$2"; }            # runlog_after PREFIX LINE
runlog_append() { runlog_edit append "" "$1"; }            # runlog_append LINE

# runlog_commit MESSAGE: commit the run log in its worktree and push its branch. Only that file is
# added (a human's other edits there stay theirs); the branch is rebased on origin first so a push
# from elsewhere does not block every later push; a failing push is shown in STATUS until one works.
runlog_commit() {
  local d b; d=$(runlog_dir); b=$(runlog_branch)
  [[ -e "$d/.git" ]] || return 0
  git -C "$d" add "docs/RUN-$YEAR.md"
  git -C "$d" diff --cached --quiet && { log "auto: run log unchanged"; return 0; }
  git -C "$d" commit -q -m "$1" || { log "auto: run log commit failed"; return 0; }
  if ! git -C "$d" pull -q --rebase origin "$b" > /dev/null 2>&1; then
    git -C "$d" rebase --abort > /dev/null 2>&1 || true
    log "auto: run log pull --rebase failed; pushing without it"
  fi
  if git -C "$d" push -q origin "HEAD:$b" > /dev/null 2>&1; then
    rm -f "$(auto_dir)/push-failed"; log "auto: run log pushed"
  else
    [[ -f "$(auto_dir)/push-failed" ]] || date -u +%FT%TZ > "$(auto_dir)/push-failed"
    log "auto: run log push failed (next commit retries)"
  fi
  return 0
}

# --- actions (plain statements only; they report through the halted marker) -------------------------
auto_halt() {   # auto_halt REASON: nothing runs until `bench auto resume`
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" > "$(auto_dir)/halted"
  log "auto: HALTED: $1"
  runlog_append "- $(date -u +%FT%TZ), **unattended runner halted**: $1. Nothing runs until \`bench auto resume\`."
  runlog_commit "docs(run): unattended runner halted"
  auto_notify "bench: HALTED" "$1"
  auto_write_status "halted: $1"
}

# auto_sink_summary SLOT LINE -> "sink: targets U/T up; poller CODE" from sink_status's line, with an
# ATTENTION prefix when a row that feeds the sink is in this slot and its side is not healthy; "n/a"
# when the slot has neither a node-exporter nor a glances row. Never a URL or an address.
auto_sink_summary() {
  local s=$1 line=$2 ne gl t u code warn=""
  ne=$(box_running node-exporter "$s"); gl=$(box_running glances "$s")
  [[ -n "$ne$gl" ]] || { printf 'sink: n/a this slot (no node-exporter/glances row)'; return 0; }
  [[ -n "$line" ]] || { printf 'ATTENTION sink: no status line'; return 0; }
  [[ "$line" == *unreachable* ]] && { printf 'ATTENTION sink: unreachable'; return 0; }
  t=$(grep -o "'http" <<<"$line" | wc -l || true); u=$(grep -o "'up')" <<<"$line" | wc -l || true)
  code=$(grep -oE 'poller .*' <<<"$line" | awk '{print $NF}' || true)
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="none"
  [[ -n "$ne" ]] && ((u < t || t == 0)) && warn=1
  [[ -n "$gl" && "$code" != 200 ]] && warn=1
  printf '%ssink: targets %s/%s up; poller %s' "${warn:+ATTENTION }" "$u" "$t" "$code"
}

# auto_hubcheck SLOT -> "hubs: …": the slot's Beszel box is `up` on the hub and its Pulse box is
# registered, read through a dry-run hub reset (which lists and changes nothing). States only.
auto_hubcheck() {
  local s=$1 b p names=() out res=() state
  b=$(box_running beszel "$s"); p=$(box_running pulse "$s")
  [[ -n "$b" ]] && names+=("$b")
  [[ -n "$p" ]] && names+=("$p")
  ((${#names[@]})) || { printf 'hubs: no beszel/pulse row in this slot'; return 0; }
  if ! out=$( ( sink_reset_hubs --dry-run "${names[@]}" ) 2>&1 ); then
    printf '%s\n' "$out" >&2
    printf 'hubs: ATTENTION hub check failed (see auto.log)'; return 0
  fi
  if [[ -n "$b" ]]; then
    state=$(grep -oE "beszel: would forget $b \([^)]*\)" <<<"$out" | sed -E 's/.*, ([^,)]*)\)$/\1/' | head -1 || true)
    case "$state" in
      up) res+=("beszel $b up");;
      "") res+=("ATTENTION beszel $b not on the hub");;
      *) res+=("ATTENTION beszel $b is $state");;
    esac
  fi
  if [[ -n "$p" ]]; then
    if grep -q "pulse: would forget $p (" <<<"$out"; then res+=("pulse $p registered"); else res+=("ATTENTION pulse $p not registered"); fi
  fi
  printf 'hubs: %s' "$(printf '%s; ' "${res[@]}" | sed 's/; $//')"
}

# auto_status SLOT LABEL -> a one-line summary on stdout; the full output goes to the log (stderr).
# LABEL "+1 h" also writes the marker and the run-log line.
auto_status() {
  local s=$1 label=$2 out hub n active t summary
  t=$(date +%s)
  out=$( ( cmd_cycle status "$s" ) 2>&1 ) || true
  printf '%s cycle status %s (%s):\n%s\n' "$(auto_utc "$t")" "$s" "$label" "$out" >&2
  n=$(auto_rows "$s" | wc -l)
  active=$(grep -c ' active rows=' <<<"$out" || true)
  hub=$(auto_hubcheck "$s")
  summary="$active/$n rows active; $(auto_sink_summary "$s" "$(grep '^sink:' <<<"$out" | head -1 || true)"); $hub"
  if [[ "$label" == "+1 h" ]]; then
    date -u +%FT%TZ > "$(auto_dir)/slot-$s.status-1h"
    runlog_after "\`./bench cycle start $s\` at:" "- [x] \`./bench cycle status $s\` at $(auto_utc "$t") (+1 h, unattended runner): $summary"
    runlog_commit "docs(run): slot $((s + 1)) +1 h status (unattended)"
    if ((active < n)) || [[ "$summary" == *ATTENTION* ]]; then auto_notify "bench: slot $((s + 1)) +1 h needs a look" "$summary"; fi
  fi
  printf '%s' "$summary"
}

auto_collect() {   # auto_collect SLOT (plain statement; see the errexit note on top)
  local s=$1 t0 t1 f n rc bad
  t0=$(date +%s)
  log "auto: collect $s"
  set +e; ( set -e; cmd_collect "$s" ); rc=$?; set -e
  ((rc == 0)) || { auto_halt "collect $s exited $rc (see auto.log)"; return 0; }
  f="$(slots_dir)/slot-$s.collect-failures.log"
  if [[ -s "$f" ]]; then
    auto_halt "collect $s: $(paste -sd';' "$f"). The next slot start would rebuild those boxes: collect them by hand (BENCH_ONLY_BOXES=\"box-N\" ./bench collect $s), then bench auto resume"
    return 0
  fi
  bad=$(auto_verify_collected "$s")
  [[ -z "$bad" ]] || { auto_halt "collect $s reported no failure, but: $bad. Collect by hand, then bench auto resume"; return 0; }
  set +e; ( set -e; cmd_summarize ) > "$(auto_dir)/summarize-$s.out" 2>&1; rc=$?; set -e
  ((rc == 0)) || { auto_halt "summarize failed after collect $s (auto/summarize-$s.out)"; return 0; }
  t1=$(date +%s)
  n=$(auto_rows "$s" | wc -l)
  date -u +%FT%TZ > "$(auto_dir)/slot-$s.collected"
  runlog_mark "\`./bench collect $s\` at:" "$(auto_utc "$t0")–$(auto_utc "$t1") (unattended runner, $(auto_code_ref)): $n/$n rows collected, \`slot-$s.collect-failures.log\` empty, every samples file verified, \`summarize.py\` ran clean (auto/summarize-$s.out)."
  runlog_commit "docs(run): slot $((s + 1)) collected (unattended)"
  auto_notify "bench: slot $((s + 1)) collected" "$n/$n rows, no failures"
  auto_write_status "slot $s collected"
}

auto_adopt() {   # auto_adopt SLOT: every samples file is there without our marker = collected by hand
  local s=$1 bad
  bad=$(auto_verify_collected "$s")
  [[ -z "$bad" ]] || { auto_halt "slot $s looks collected by hand, but: $bad. Collect by hand, then bench auto resume"; return 0; }
  printf 'by hand, adopted %s\n' "$(date -u +%FT%TZ)" > "$(auto_dir)/slot-$s.collected"
  runlog_mark "\`./bench collect $s\` at:" "(collected by hand; every samples file verified by the unattended runner $(date -u +%FT%TZ))."
  runlog_commit "docs(run): slot $((s + 1)) collected by hand (adopted by the unattended runner)"
  auto_write_status "slot $s collected by hand, adopted"
}

auto_start() {   # auto_start SLOT (plain statement; see the errexit note on top)
  local s=$1 t0 t1 f last st fails cpus rc
  t0=$(date +%s)
  log "auto: cycle start $s"
  set +e; ( set -e; cmd_cycle start "$s" ); rc=$?; set -e
  if ((rc != 0)) || [[ ! -f "$(auto_manifest "$s")" ]]; then
    auto_halt "cycle start $s exited $rc before its manifest was written (see auto.log); the boxes may be half set up"
    return 0
  fi
  t1=$(date +%s)
  f="$(slots_dir)/slot-$s.failures.log"
  fails=$( [[ -s "$f" ]] && paste -sd';' "$f" || echo empty )
  last=$(auto_field "$s" '[.boxes[].stop] | max // empty')
  [[ "$last" =~ ^[0-9]+$ ]] || { auto_halt "cycle start $s left a manifest without stop times (see auto.log)"; return 0; }
  cpus=$(auto_field "$s" '[.boxes[] | "\(.cpuModel) / \(.vcpus) vCPU"] | unique | join(", ")')
  st=$(auto_status "$s" "right after the start")
  runlog_mark "\`./bench cycle start $s\` at:" "$(auto_utc "$t0") → $(auto_utc "$t1") (unattended runner, $(auto_code_ref)). Failures log: $fails. $(auto_field "$s" '.boxes | length') boxes in the manifest, $cpus. Collect after $(auto_utc "$last"). \`cycle status $s\` right after: $st."
  if [[ "$fails" != empty ]]; then
    runlog_commit "docs(run): slot $((s + 1)) started with failures (unattended)"
    auto_halt "cycle start $s: $fails. The other boxes are measuring; redo the failed ones (BENCH_ONLY_BOXES=\"box-N\" ./bench cycle start $s), then bench auto resume"
    return 0
  fi
  runlog_commit "docs(run): slot $((s + 1)) started (unattended)"
  auto_notify "bench: slot $((s + 1)) started" "collect after $(auto_utc "$last"); $st"
  auto_write_status "slot $s started; collect after $(auto_utc "$last")"
}

auto_finish() {
  local rc
  if [[ -f "$(auto_dir)/done" ]]; then auto_write_status "run complete ($(cat "$(auto_dir)/done"))"; return 0; fi
  set +e; ( set -e; cmd_summarize ) > "$(auto_dir)/summarize-final.out" 2>&1; rc=$?; set -e
  ((rc == 0)) || log "auto: final summarize failed (auto/summarize-final.out)"
  date -u +%FT%TZ > "$(auto_dir)/done"
  runlog_after "\`./bench collect $((SLOT_COUNT - 1))\` at:" "- [x] RUN COMPLETE $(date -u +%FT%TZ) (unattended runner): every slot collected; \`summarize.py\` output in data/$YEAR/auto/summarize-final.out. The boxes stay rented until the founder says otherwise."
  runlog_commit "docs(run): run complete (unattended)"
  auto_notify "bench: RUN COMPLETE" "every slot collected; the boxes are still rented"
  auto_write_status "run complete"
}

auto_tick() {   # one tick under the lock; ticks never overlap (a collect or a start takes minutes)
  exec 9> "$(auto_dir)/tick.lock"
  if flock -n 9; then auto_tick_body; else log "auto: another tick holds the lock"; fi
  exec 9>&-
}

auto_halted() { [[ -f "$(auto_dir)/halted" ]]; }

auto_tick_body() {
  local action i
  for i in 1 2 3 4; do
    action=$(auto_decide)
    case "$action" in
      halted) auto_write_status "halted: $(cat "$(auto_dir)/halted")"; return 0;;
      done) auto_finish; return 0;;
      none) auto_write_status "no slot manifest in $(slots_dir); nothing to do"; return 0;;
      bad-manifest\ *) auto_halt "slot ${action#bad-manifest } manifest is empty or malformed (data/$YEAR/slots); repair it, then bench auto resume"; return 0;;
      wait\ *) auto_write_status "slot $(auto_latest_slot) measuring; collect at $(auto_utc "${action#wait }")"; return 0;;
      collect\ *) auto_collect "${action#collect }"; if auto_halted; then return 0; fi;;
      adopt\ *) auto_adopt "${action#adopt }"; if auto_halted; then return 0; fi;;
      status1h\ *) auto_status "${action#status1h }" "+1 h" > /dev/null;;
      start\ *) auto_start "${action#start }"; if auto_halted; then return 0; fi;;
      *) auto_halt "unknown decision '$action'"; return 0;;
    esac
  done
  log "auto: tick did $i actions; the next tick continues"
}

auto_init() {   # markers for work already done by hand, the run-log worktree, the cron line
  local s now started d
  now=$(auto_now); mkdir -p "$(auto_dir)"
  for s in $(seq 0 $((SLOT_COUNT - 1))); do
    [[ -f "$(auto_manifest "$s")" ]] || continue
    if auto_samples_present "$s" && [[ ! -f "$(auto_dir)/slot-$s.collected" ]]; then
      printf 'by hand, before %s\n' "$(date -u +%FT%TZ)" > "$(auto_dir)/slot-$s.collected"
      log "auto: slot $s is collected (every row has its samples)"
    fi
    started=$(auto_field "$s" '.startedAt // 0')
    if ((now >= started + AUTO_STATUS_AFTER)) && [[ ! -f "$(auto_dir)/slot-$s.status-1h" ]]; then
      printf 'by hand, before %s\n' "$(date -u +%FT%TZ)" > "$(auto_dir)/slot-$s.status-1h"
      log "auto: slot $s +1 h status taken as done by hand (started $(auto_utc "$started"))"
    fi
  done
  d=$(runlog_dir)
  if [[ ! -e "$d" ]]; then
    git -C "$BENCH_ROOT" worktree add -q "$d" "$(runlog_branch)" && log "auto: run-log worktree $d on $(runlog_branch)"
  fi
  [[ -f "$(runlog_file)" ]] || die "no run log at $(runlog_file)"
  log "auto: next action: $(auto_decide)"
  log "auto: cron line (crontab -e on this host):"
  auto_cron_line
}

auto_cron_line() {
  printf '*/%s * * * * PATH=/usr/local/bin:/usr/bin:/bin %s/bench auto tick >> %s/cron.log 2>&1\n' "$AUTO_TICK_MINUTES" "$BENCH_ROOT" "$(auto_dir)"
}

auto_show_status() {
  local d; d=$(auto_dir)
  if [[ -f "$d/STATUS" ]]; then printf 'STATUS: %s' "$(cat "$d/STATUS")"; echo; else echo "STATUS: no tick has run yet"; fi
  printf 'next:   %s\n' "$(auto_decide)"
  [[ -f "$d/halted" ]] && printf 'HALTED: %s\n' "$(cat "$d/halted")"
  [[ -f "$d/done" ]] && printf 'done:   %s\n' "$(cat "$d/done")"
  [[ -f "$d/push-failed" ]] && printf 'push:   failing since %s\n' "$(cat "$d/push-failed")"
  find "$d" -maxdepth 1 \( -name 'slot-*.collected' -o -name 'slot-*.status-1h' \) -printf 'marker: %f\n' 2>/dev/null | sort
  printf 'cron:   %s line(s)\n' "$( (crontab -l 2>/dev/null | grep -c 'bench auto tick') || true)"
  [[ -f "$d/auto.log" ]] && { echo "--- auto.log (last 12 lines)"; tail -12 "$d/auto.log"; }
  return 0
}

cmd_auto() {
  local sub=${1:-}
  case "$sub" in
    tick) load_env; mkdir -p "$(auto_dir)"; auto_tick >> "$(auto_dir)/auto.log" 2>&1; cat "$(auto_dir)/STATUS" 2>/dev/null || true;;
    decide) auto_decide;;
    status) auto_show_status;;
    init) load_env; auto_init;;
    resume) rm -f "$(auto_dir)/halted"; log "auto: resumed; the next tick does: $(auto_decide)";;
    cron-line) auto_cron_line;;
    *) die "usage: bench auto init|tick|decide|status|resume|cron-line";;
  esac
}
