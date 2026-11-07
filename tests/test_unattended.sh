#!/usr/bin/env bash
# bench auto: the decision table, the run-log edits, the init markers, a tick that collects and
# starts the next slot in one go, and the halts: a collect that leaves a failure (through the REAL
# cmd_collect, with one fetch failing), a malformed manifest, an unknown decision. Plus the running-slot
# guard of cycle start, and the sink/hub summaries.
# shellcheck disable=SC2016  # the run-log anchors are literal backtick lines
set -euo pipefail
cd "$(dirname "$0")/.."
export BENCH_ROOT=$PWD
. lib/common.sh
. lib/rotation.sh
. lib/cycle.sh
. lib/unattended.sh
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; [[ -f "$d/tick.log" ]] && { echo "--- last tick:"; cat "$d/tick.log"; }; exit 1; fi; }
BENCH_ROOT=$d; YEAR="test"; RUNLOG_DIR="$d/runlog"; AUTO_COLLECT_GRACE=120; AUTO_STATUS_AFTER=3600
BENCH_ENV="$d/bench.env"; printf 'SSH_KEY_PATH=/dev/null\n' > "$BENCH_ENV"; chmod 600 "$BENCH_ENV"
mkdir -p "$d/data/test/slots" "$d/runlog/docs" "$d/data/test/auto"
manifest() {   # manifest SLOT STARTED LAST_STOP
  jq -n --argjson s "$1" --argjson st "$2" --argjson stop "$3" \
    '{slot: $s, startedAt: $st, boxes: [{box: "box-0", stop: ($stop - 60), cpuModel: "X", vcpus: 2}, {box: "box-1", stop: $stop, cpuModel: "X", vcpus: 2}]}' \
    > "$d/data/test/slots/slot-$1.json"
}
samples_for_slot() {   # every row of the slot gets a fresh, non-empty samples file
  local cyc outname
  while read -r _ _ _ _ cyc outname; do mkdir -p "$d/data/test/$cyc"; echo x | gzip > "$d/data/test/$cyc/$outname.csv.gz"; done < <(slot_plan "$1")
}
rl="$d/runlog/docs/RUN-test.md"

# --- decisions
check "no manifest -> none" "$(AUTO_NOW=1000 auto_decide)" "none"
manifest 0 1000 95000
check "measuring, status not due -> wait until last stop + grace" "$(AUTO_NOW=1500 auto_decide)" "wait 95120"
check "+1 h passed, no marker -> status1h" "$(AUTO_NOW=4700 auto_decide)" "status1h 0"
: > "$d/data/test/auto/slot-0.status-1h"
check "status marker -> wait again" "$(AUTO_NOW=4700 auto_decide)" "wait 95120"
check "last stop + grace reached -> collect" "$(AUTO_NOW=95120 auto_decide)" "collect 0"
check "collect wins over a due status check" "$(rm -f "$d/data/test/auto/slot-0.status-1h"; AUTO_NOW=100000 auto_decide)" "collect 0"
samples_for_slot 0
check "every samples file present without our marker -> adopt" "$(AUTO_NOW=100000 auto_decide)" "adopt 0"
: > "$d/data/test/auto/slot-0.collected"
check "collected marker -> start the next slot" "$(AUTO_NOW=100000 auto_decide)" "start 1"
manifest 1 6000 100000
check "a newer manifest is the latest slot" "$(AUTO_NOW=6100 auto_decide)" "wait 100120"
: > "$d/data/test/slots/slot-1.json"
check "an empty manifest is flagged, never collected" "$(AUTO_NOW=200000 auto_decide)" "bad-manifest 1"
echo '{"slot":1,"startedAt":6000,"boxes":[]}' > "$d/data/test/slots/slot-1.json"
check "a manifest without boxes is flagged" "$(AUTO_NOW=200000 auto_decide)" "bad-manifest 1"
manifest 1 6000 100000
: > "$d/data/test/auto/slot-1.collected"
manifest 2 8000 9000; : > "$d/data/test/auto/slot-2.collected"
manifest 3 10000 11000; : > "$d/data/test/auto/slot-3.collected"
check "the last slot collected -> done" "$(AUTO_NOW=12000 auto_decide)" "done"
: > "$d/data/test/auto/halted"
check "halted wins over everything" "$(AUTO_NOW=12000 auto_decide)" "halted"
rm -f "$d/data/test/auto/halted"; : > "$d/data/test/auto/done"
check "done marker -> done" "$(AUTO_NOW=100 auto_decide)" "done"

# --- a fresh run (data/<year>/ holds only run.json, no slots/): the tick says so and does nothing
YEAR=fresh; mkdir -p "$d/data/fresh/auto"; echo '{}' > "$d/data/fresh/run.json"
check "fresh run: no slots dir -> none" "$(AUTO_NOW=1000 auto_decide)" "none"
AUTO_NOW=1000 auto_tick > /dev/null 2>&1
check "fresh run: the tick reports nothing to do" "$(grep -c 'nothing to do' "$d/data/fresh/auto/STATUS")" 1
check "fresh run: no marker written" "$(find "$d/data/fresh/auto" -mindepth 1 ! -name STATUS ! -name tick.lock | wc -l)" 0
# --- markers left by an earlier run in the same data/<year>/auto/ (the pilot's, on the cron host) are
# older than the new run's manifests and count for nothing
stale=1600000000; started=1700000000   # both before any marker this test writes for real
for m in "done" slot-0.collected slot-0.status-1h slot-1.collected; do : > "$d/data/fresh/auto/$m"; touch -d "@$stale" "$d/data/fresh/auto/$m"; done
check "stale done marker without a manifest -> none" "$(AUTO_NOW=$started auto_decide)" "none"
mkdir -p "$d/data/fresh/slots"
jq -n --argjson st "$started" '{slot: 0, startedAt: $st, boxes: [{box: "box-0", stop: ($st + 93600), cpuModel: "X", vcpus: 2}]}' > "$d/data/fresh/slots/slot-0.json"
check "stale collected marker -> still measuring" "$(AUTO_NOW=$((started + 60)) auto_decide)" "wait $((started + 93600 + 120))"
check "stale status marker -> the +1 h check is due" "$(AUTO_NOW=$((started + 3700)) auto_decide)" "status1h 0"
touch -d "@$((started + 3700))" "$d/data/fresh/auto/slot-0.status-1h"
check "a status marker newer than the manifest counts" "$(AUTO_NOW=$((started + 3800)) auto_decide)" "wait $((started + 93600 + 120))"
touch -d "@$((started + 93800))" "$d/data/fresh/auto/slot-0.collected"
check "a collected marker newer than the manifest counts" "$(AUTO_NOW=$((started + 93900)) auto_decide)" "start 1"
YEAR="test"

# --- the running-slot guard of cycle start
rm -f "$d/data/test/auto/done"; manifest 1 6000 4102444800   # the guard reads the real clock: a stop in 2100
check "cycle start is refused while a slot's boxes still measure" "$( (cycle_start_guard 2) 2>&1 | grep -c 'refused: slot-1.json runs until')" 1
check "a BENCH_ONLY_BOXES redo passes the guard" "$(BENCH_ONLY_BOXES=box-4 cycle_start_guard 2 && echo ok)" "ok"
manifest 1 6000 7000
check "with every stop in the past the guard passes" "$(cycle_start_guard 2 && echo ok)" "ok"
check "cycle start calls the guard before anything else" "$(grep -c 'cycle_start_guard "\$s"' lib/cycle.sh)" 1
check "the manifest is written atomically" "$(grep -o 'slot-\$s.json.tmp' lib/cycle.sh | wc -l)" 2

# --- run-log edits
printf '## Slot 2 (s = 1)\n\n- [x] `./bench cycle start 1` at 2026-11-01 15:18Z\n- [ ] `./bench collect 1` at: (after 2026-11-02T16:40:22Z)\n\n## Deviations and incidents\n\n- old line\n' > "$rl"
runlog_mark '`./bench collect 1` at:' "16:45Z (unattended): 9/9"
check "mark replaces the open checklist line" "$(grep -c '^- \[x\] `./bench collect 1` at: 16:45Z (unattended): 9/9$' "$rl")" 1
runlog_mark '`./bench collect 1` at:' "AGAIN"
check "mark is idempotent once the line is checked" "$(grep -c 'collect 1' "$rl")" 1
runlog_after '`./bench cycle start 1` at' "- [x] status line"
check "after inserts right below the anchor" "$(sed -n 4p "$rl")" "- [x] status line"
runlog_append "- halted line"
check "append lands at the end" "$(tail -1 "$rl")" "- halted line"
runlog_mark 'no such anchor' "text"
check "a missing anchor appends instead of losing the line" "$(tail -1 "$rl")" "- [x] no such anchor text"
check "no trailing blank lines pile up" "$(tail -c1 "$rl" | xxd -p)" "0a"
runlog_append "- target http://46.62.144.243:9100/metrics up, box 10.0.0.11 reachable, netdata v2.12.2, 2026-11-02"
check "automated lines never carry an address or a URL" "$(tail -1 "$rl")" "- target <url> up, box <ip> reachable, netdata v2.12.2, 2026-11-02"

# --- sink and hub summaries
line="sink: prometheus targets [('http://46.62.144.243:9100/metrics', 'up')]; poller 2026-11-01T16:50:36Z 200"
check "slot 1: targets and poller summarised, no address" "$(auto_sink_summary 0 "$line")" "sink: targets 1/1 up; poller 200"
check "slot 3 has no sink row: n/a, never ATTENTION" "$(auto_sink_summary 2 "sink: prometheus targets []; poller ")" "sink: n/a this slot (no node-exporter/glances row)"
check "a down target where node-exporter runs is flagged" "$(auto_sink_summary 1 "sink: prometheus targets [('http://1.2.3.4:9100/metrics', 'down')]; poller 2026-11-01T16:50:36Z 200")" "ATTENTION sink: targets 0/1 up; poller 200"
check "an unreachable sink is flagged when a row needs it" "$(auto_sink_summary 0 "sink: unreachable")" "ATTENTION sink: unreachable"
sink_reset_hubs() { echo "sink: beszel: would forget box-6 (1.2.3.4, down)"; } >&2
check "a down Beszel box and a missing Pulse box are flagged with states only" "$(auto_hubcheck 2)" "hubs: ATTENTION beszel box-6 is down; ATTENTION pulse box-0 not registered"
sink_reset_hubs() { echo "sink: beszel: nothing to forget"; echo "sink: pulse: would forget box-0 (abc…)"; } >&2
check "a Beszel box the hub never saw is flagged" "$(auto_hubcheck 2)" "hubs: ATTENTION beszel box-6 not on the hub; pulse box-0 registered"
sink_reset_hubs() { echo "sink: beszel: would forget box-6 (1.2.3.4, up)"; echo "sink: pulse: would forget box-0 (abc…)"; } >&2

# --- init markers
rm -rf "$d/data/test/auto"; rm -f "$d/data/test/slots/slot-2.json" "$d/data/test/slots/slot-3.json"; manifest 1 6000 100000
RUNLOG_DIR="$d/runlog" AUTO_NOW=9700 auto_init > /dev/null 2>&1
check "init marks the slot whose samples are all there" "$(test -f "$d/data/test/auto/slot-0.collected" && echo yes)" "yes"
check "init does not mark the running slot collected" "$(test -f "$d/data/test/auto/slot-1.collected" || echo no)" "no"
check "init takes an old +1 h check as done by hand" "$(test -f "$d/data/test/auto/slot-1.status-1h" && echo yes)" "yes"
check "init leaves the decision at the running slot" "$(AUTO_NOW=9700 auto_decide)" "wait 100120"

# --- a tick: collect, then start the next slot, in one go (bench commands stubbed)
printf '## Slot 2 (s = 1)\n\n- [x] `./bench cycle start 1` at 2026-11-01 15:18Z\n- [ ] `./bench collect 1` at: (after 2026-11-02T16:40:22Z)\n\n## Deviations and incidents\n\n- old line\n' > "$rl"
calls="$d/calls"; : > "$calls"
cmd_collect() { echo "collect $1" >> "$calls"; : > "$d/data/test/slots/slot-$1.collect-failures.log"; samples_for_slot "$1"; }
cmd_summarize() { echo summarize >> "$calls"; }
cmd_cycle() { echo "cycle $1 $2" >> "$calls"; if [[ "$1" == start ]]; then manifest "$2" 200000 290000; : > "$d/data/test/slots/slot-$2.failures.log"; else echo "x box-0 cycle-1 active rows=1"; echo "sink: prometheus targets [('http://1.2.3.4:9100/metrics', 'up')]; poller 2026-11-01T16:50:36Z 200"; fi; }
auto_notify() { echo "notify $1" >> "$calls"; }
AUTO_NOW=100120 auto_tick > /dev/null 2>&1
check "tick collected slot 1 then started slot 2, with the immediate status" "$(paste -sd' ' "$calls")" "collect 1 summarize notify bench: slot 2 collected cycle start 2 cycle status 2 notify bench: slot 3 started"
check "the collect line reached the run log" "$(grep -c 'collect 1` at: .*unattended runner' "$rl")" 1
check "the start line carries derived sink/hub states, no address" "$(grep -c 'cycle start 2` at: .*sink: n/a this slot (no node-exporter/glances row); hubs: beszel box-6 up; pulse box-0 registered' "$rl")" 1
check "no address reached the run log at all" "$(grep -c '1\.2\.3\.4' "$rl")" 0
check "a second tick while measuring only waits" "$(AUTO_NOW=200100 auto_tick 2>&1 >/dev/null | grep -c 'measuring; collect at')" 1

# --- a collect that leaves a failure halts; the next slot is NOT started (stubbed collect)
: > "$calls"
cmd_collect() { echo "collect $1" >> "$calls"; echo "beszel on box-6: not collected" > "$d/data/test/slots/slot-$1.collect-failures.log"; }
AUTO_NOW=290120 auto_tick > /dev/null 2>&1
check "a failed collect halts instead of starting the next slot" "$(paste -sd' ' "$calls")" "collect 2 notify bench: HALTED"
check "the halt is recorded" "$(grep -c 'unattended runner halted.*beszel on box-6' "$rl")" 1
check "after a halt nothing runs" "$(AUTO_NOW=300000 auto_decide)" "halted"
check "no slot 3 manifest was written" "$(test -f "$d/data/test/slots/slot-3.json" || echo no)" "no"

# --- the REAL cmd_collect with one failing fetch (the data-loss path): run_isolated's bookkeeping
# must survive the way the tick calls auto_collect, so the failure is recorded and the runner halts.
. lib/cycle.sh   # the real cmd_collect back (stubs below stay)
cmd_summarize() { echo summarize >> "$calls"; }
cmd_cycle() { echo "cycle $1 $2" >> "$calls"; if [[ "$1" == start ]]; then manifest "$2" 400000 490000; : > "$d/data/test/slots/slot-$2.failures.log"; else echo "x box-0 cycle-1 active rows=1"; fi; }
rm -f "$d/data/test/auto/halted"; : > "$calls"
while read -r _ box role _ cyc outname; do
  mkdir -p "$d/data/test/$cyc"
  jq -n --arg a "$role" --arg b "$box" '{agent: $a, box: $b, slot: 2, run: 0, installFinished: 200100, loadStart: 286400, stop: 290000}' > "$d/data/test/$cyc/schedule-$outname.json"
done < <(slot_plan 2)
ssh_box() { return 0; }
fetch_box() { if [[ "$1" == box-3 && "$2" == */samples.csv ]]; then return 1; fi; echo "t,v" > "$3"; }
merge_meta() { echo '{}'; }
AUTO_NOW=290120 auto_tick > "$d/tick.log" 2>&1
check "a failed samples fetch is recorded by the real collect" "$(cat "$d/data/test/slots/slot-2.collect-failures.log")" "hetrixtools on box-3: not collected"
check "the runner halted on it" "$(AUTO_NOW=290121 auto_decide)" "halted"
check "no collected marker was written" "$(test -f "$d/data/test/auto/slot-2.collected" || echo no)" "no"
check "the next slot was not started" "$(grep -c 'cycle start' "$calls")" 0
check "the halt names the row" "$(grep -c 'halted.*hetrixtools on box-3' "$rl")" 1

# --- the independent verification: a collect that reports nothing but leaves an empty samples file halts
rm -f "$d/data/test/auto/halted"; : > "$calls"
cmd_collect() { : > "$d/data/test/slots/slot-$1.collect-failures.log"; samples_for_slot "$1"; : > "$d/data/test/cycle-2/datadog.csv.gz"; }
AUTO_NOW=290120 auto_tick > /dev/null 2>&1
check "an empty samples file halts even when the collect reported no failure" "$(grep -c 'halted.*datadog: no samples file' "$rl")" 1
check "still no collected marker" "$(test -f "$d/data/test/auto/slot-2.collected" || echo no)" "no"

# --- a hand collect is adopted, then the next slot starts
rm -f "$d/data/test/auto/halted"; : > "$calls"
samples_for_slot 2
AUTO_NOW=290120 auto_tick > /dev/null 2>&1
check "samples collected by hand are adopted and the next slot starts" "$(paste -sd' ' "$calls")" "cycle start 3 cycle status 3 notify bench: slot 4 started"
check "the adopted marker says so" "$(grep -c 'by hand, adopted' "$d/data/test/auto/slot-2.collected")" 1

# --- an unknown decision halts instead of looping
rm -f "$d/data/test/auto/halted"
auto_decide() { echo bogus; }
auto_tick > /dev/null 2>&1
check "an unknown decision halts" "$(grep -c "halted.*unknown decision 'bogus'" "$rl")" 1

# --- a stale done marker (an earlier run's) does not skip the final summarize of this run
YEAR=fresh; : > "$calls"; printf -- '- [ ] `./bench collect 3` at:\n' > "$d/runlog/docs/RUN-fresh.md"
cmd_summarize() { echo summarize >> "$calls"; }
touch -d "@$stale" "$d/data/fresh/auto/done"
AUTO_NOW=$((started + 400000)) auto_finish > /dev/null 2>&1
check "a stale done marker: the final summarize runs" "$(paste -sd' ' "$calls")" "summarize notify bench: RUN COMPLETE"
check "and done is rewritten" "$(( $(stat -c %Y "$d/data/fresh/auto/done") > stale ))" 1
: > "$calls"; auto_finish > /dev/null 2>&1
check "a fresh done marker: finish only reports" "$(paste -sd' ' "$calls")" ""

# --- init ignores an earlier run's markers: the slot is marked by hand afresh
rm -f "$d/data/fresh/auto/slot-0.collected"; : > "$d/data/fresh/auto/slot-0.collected"; touch -d "@$stale" "$d/data/fresh/auto/slot-0.collected"
while read -r _ _ _ _ cyc outname; do mkdir -p "$d/data/fresh/$cyc"; echo x | gzip > "$d/data/fresh/$cyc/$outname.csv.gz"; done < <(slot_plan 0)
AUTO_NOW=$((started + 100000)) auto_init > /dev/null 2>&1 || true
check "init re-marks a slot whose marker was stale" "$(grep -c 'by hand' "$d/data/fresh/auto/slot-0.collected")" 1
echo PASS
