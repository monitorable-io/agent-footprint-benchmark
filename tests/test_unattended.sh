#!/usr/bin/env bash
# bench auto: the decision table, the run-log edits, the init markers, and a tick that collects and
# starts the next slot in one go — or halts instead of starting when the collect left a failure.
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
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; exit 1; fi; }
BENCH_ROOT=$d; YEAR="test"; RUNLOG_DIR="$d/runlog"; AUTO_COLLECT_GRACE=120; AUTO_STATUS_AFTER=3600
mkdir -p "$d/data/test/slots" "$d/runlog/docs"
manifest() {   # manifest SLOT STARTED LAST_STOP
  jq -n --argjson s "$1" --argjson st "$2" --argjson stop "$3" \
    '{slot: $s, startedAt: $st, boxes: [{box: "box-0", stop: ($stop - 60), cpuModel: "X", vcpus: 2}, {box: "box-1", stop: $stop, cpuModel: "X", vcpus: 2}]}' \
    > "$d/data/test/slots/slot-$1.json"
}
samples_for_slot() {   # every row of the slot gets its samples file
  local cyc outname
  while read -r _ _ _ _ cyc outname; do mkdir -p "$d/data/test/$cyc"; : > "$d/data/test/$cyc/$outname.csv.gz"; done < <(slot_plan "$1")
}

# --- decisions
check "no manifest -> none" "$(AUTO_NOW=1000 auto_decide)" "none"
manifest 0 1000 95000
check "measuring, status not due -> wait until last stop + grace" "$(AUTO_NOW=1500 auto_decide)" "wait 95120"
check "+1 h passed, no marker -> status1h" "$(AUTO_NOW=4700 auto_decide)" "status1h 0"
mkdir -p "$d/data/test/auto"; : > "$d/data/test/auto/slot-0.status-1h"
check "status marker -> wait again" "$(AUTO_NOW=4700 auto_decide)" "wait 95120"
check "last stop + grace reached -> collect" "$(AUTO_NOW=95120 auto_decide)" "collect 0"
check "collect wins over a due status check" "$(rm -f "$d/data/test/auto/slot-0.status-1h"; AUTO_NOW=100000 auto_decide)" "collect 0"
samples_for_slot 0
check "every samples file present counts as collected -> start the next slot" "$(AUTO_NOW=100000 auto_decide)" "start 1"
manifest 1 6000 100000
check "a newer manifest is the latest slot" "$(AUTO_NOW=6100 auto_decide)" "wait 100120"
: > "$d/data/test/auto/slot-1.collected"
manifest 2 8000 9000; : > "$d/data/test/auto/slot-2.collected"
manifest 3 10000 11000; : > "$d/data/test/auto/slot-3.collected"
check "the last slot collected -> done" "$(AUTO_NOW=12000 auto_decide)" "done"
: > "$d/data/test/auto/halted"
check "halted wins over everything" "$(AUTO_NOW=12000 auto_decide)" "halted"
rm -f "$d/data/test/auto/halted"; : > "$d/data/test/auto/done"
check "done marker -> done" "$(AUTO_NOW=100 auto_decide)" "done"

# --- run-log edits
rl="$d/runlog/docs/RUN-test.md"
printf '## Slot 2 (s = 1)\n\n- [x] `./bench cycle start 1` at 2026-11-01 15:18Z\n- [ ] `./bench collect 1` at: (after 2026-11-02T16:40:22Z)\n\n## Deviations and incidents\n\n- old line\n' > "$rl"
runlog_mark '`./bench collect 1` at:' "16:45Z (unattended): 9/9"
check "mark replaces the open checklist line" "$(grep -c '^- \[x\] `./bench collect 1` at: 16:45Z (unattended): 9/9$' "$rl")" 1
runlog_after '`./bench cycle start 1` at' "- [x] status line"
check "after inserts right below the anchor" "$(sed -n 4p "$rl")" "- [x] status line"
runlog_append "- halted line"
check "append lands at the end" "$(tail -1 "$rl")" "- halted line"
runlog_mark 'no such anchor' "text"
check "a missing anchor appends instead of losing the line" "$(tail -1 "$rl")" "- [x] no such anchor text"
check "no trailing blank lines pile up" "$(tail -c1 "$rl" | xxd -p)" "0a"
runlog_append "- target http://46.62.144.243:9100/metrics up, box 10.0.0.11 reachable"
check "the run log never gets an address or a URL from automated lines" "$(tail -1 "$rl")" "- target <url> up, box <ip> reachable"
check "sink line becomes counts and a code" "$(auto_sink_summary "sink: prometheus targets [('http://46.62.144.243:9100/metrics', 'up')]; poller 2026-11-01T16:50:36Z 200")" "sink: targets 1/1 up; poller 200"
check "an empty target list is reported as such" "$(auto_sink_summary "sink: prometheus targets []; poller ")" "sink: targets 0/0 up; poller none"
check "an unreachable sink is named" "$(auto_sink_summary "sink: unreachable")" "sink: unreachable"

# --- init markers
rm -rf "$d/data/test/auto"; rm -f "$d/data/test/slots/slot-2.json" "$d/data/test/slots/slot-3.json"
RUNLOG_DIR="$d/runlog" AUTO_NOW=9700 auto_init > /dev/null 2>&1
check "init marks the slot whose samples are all there" "$(test -f "$d/data/test/auto/slot-0.collected" && echo yes)" "yes"
check "init does not mark the running slot collected" "$(test -f "$d/data/test/auto/slot-1.collected" || echo no)" "no"
check "init takes an old +1 h check as done by hand" "$(test -f "$d/data/test/auto/slot-1.status-1h" && echo yes)" "yes"
check "init leaves the decision at the running slot" "$(AUTO_NOW=9700 auto_decide)" "wait 100120"

# --- a tick: collect, then start the next slot, in one go (bench commands stubbed)
calls="$d/calls"; : > "$calls"
cmd_collect() { echo "collect $1" >> "$calls"; : > "$d/data/test/slots/slot-$1.collect-failures.log"; samples_for_slot "$1"; }
cmd_summarize() { echo summarize >> "$calls"; }
cmd_cycle() { echo "cycle $1 $2" >> "$calls"; if [[ "$1" == start ]]; then manifest "$2" 200000 290000; : > "$d/data/test/slots/slot-$2.failures.log"; else echo "x box-0 cycle-1 active rows=1"; echo "sink: prometheus targets [('http://1.2.3.4:9100/metrics', 'up')]; poller 2026-11-01T16:50:36Z 200"; fi; }
sink_reset_hubs() { echo "sink: beszel: would forget box-6 (1.2.3.4, up)"; echo "sink: pulse: would forget box-0 (abc…)"; } >&2
auto_notify() { echo "notify $1" >> "$calls"; }
AUTO_NOW=100120 auto_tick > /dev/null 2>&1
check "tick collected slot 1 then started slot 2, with the immediate status" "$(paste -sd' ' "$calls")" "collect 1 summarize notify bench: slot 2 collected cycle start 2 cycle status 2 notify bench: slot 3 started"
check "the collect line reached the run log" "$(grep -c 'collect 1` at: .*unattended runner' "$rl")" 1
check "the start line reached the run log with the hub check" "$(grep -c 'cycle start 2` at: .*beszel box-6 up; pulse box-0 registered' "$rl")" 1
check "the start line carries derived sink states, no address" "$(grep -c 'cycle start 2` at: .*sink: targets 1/1 up; poller 200; hubs' "$rl")" 1
check "no address reached the run log at all" "$(grep -c '1\.2\.3\.4' "$rl")" 0
sink_reset_hubs() { echo "sink: beszel: would forget box-6 (1.2.3.4, down)"; } >&2
check "a down Beszel box is flagged with its state only" "$(auto_hubcheck 2)" "hubs: ATTENTION beszel box-6 is down; ATTENTION pulse box-0 not registered"
sink_reset_hubs() { echo "sink: beszel: would forget box-6 (1.2.3.4, up)"; echo "sink: pulse: would forget box-0 (abc…)"; } >&2
check "a second tick while measuring only waits" "$(AUTO_NOW=200100 auto_tick 2>&1 >/dev/null | grep -c 'measuring; collect at')" 1
# --- a collect failure halts; the next slot is NOT started
: > "$calls"
cmd_collect() { echo "collect $1" >> "$calls"; echo "beszel on box-6: not collected" > "$d/data/test/slots/slot-$1.collect-failures.log"; }
AUTO_NOW=290120 auto_tick > /dev/null 2>&1
check "a failed collect halts instead of starting the next slot" "$(paste -sd' ' "$calls")" "collect 2 notify bench: HALTED"
check "the halt is recorded" "$(grep -c 'unattended runner halted.*beszel on box-6' "$rl")" 1
check "after a halt nothing runs" "$(AUTO_NOW=300000 auto_decide)" "halted"
check "no slot 3 manifest was written" "$(test -f "$d/data/test/slots/slot-3.json" || echo no)" "no"
echo PASS
