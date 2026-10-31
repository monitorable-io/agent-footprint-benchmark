#!/usr/bin/env bash
# write_slot_manifest: the manifest always covers the whole slot, even when BENCH_ONLY_BOXES redoes
# one box; a filtered start appends to the failures log instead of truncating it.
set -euo pipefail
cd "$(dirname "$0")/.."
export BENCH_ROOT=$PWD
. lib/common.sh
. lib/rotation.sh
. lib/cycle.sh
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; exit 1; fi; }
BENCH_ROOT=$d; YEAR="test"
mkdir -p "$d/data/test/cycle-1" "$d/data/test/slots"
printf '{"agent":"beszel","box":"box-0","slot":0,"run":0,"installFinished":100,"loadStart":200,"stop":300}' > "$d/data/test/cycle-1/schedule-beszel.json"
printf '{"agent":"node-exporter","box":"box-4","slot":0,"run":0,"installFinished":110,"loadStart":210,"stop":310}' > "$d/data/test/cycle-1/schedule-node-exporter.json"
BENCH_ONLY_BOXES="box-4" write_slot_manifest 0 999
check "manifest covers every box with a schedule, not only the filtered one" "$(jq -r '.boxes | length' "$d/data/test/slots/slot-0.json")" 2
check "manifest keeps the slot number" "$(jq -r .slot "$d/data/test/slots/slot-0.json")" 0
unset BENCH_ONLY_BOXES
write_slot_manifest 0 999
check "unfiltered manifest is the same" "$(jq -r '[.boxes[].box] | join(" ")' "$d/data/test/slots/slot-0.json")" "box-0 box-4"
printf 'old line\n' > "$d/f.log"
BENCH_ONLY_BOXES="box-4" reset_log_unless_filtered "$d/f.log"
check "a filtered start/collect keeps the earlier failure lines" "$(cat "$d/f.log")" "old line"
unset BENCH_ONLY_BOXES
reset_log_unless_filtered "$d/f.log"
check "an unfiltered start/collect starts the log afresh" "$(wc -c < "$d/f.log")" 0
check "both logs go through reset_log_unless_filtered" "$(grep -c 'reset_log_unless_filtered "' lib/cycle.sh)" 2
check "no bare truncation of a failures log remains" "$(grep -cE '^\s*: > .*failures' lib/cycle.sh)" 0
# schedule_on: the remote chain must fail when a timer is not armed (systemd-run refused), not just on an SSH error.
check "schedule_on chains its systemd-run calls with &&" "$(grep -A10 '^schedule_on()' lib/cycle.sh | grep -c 'systemd-run.*\\$')" 2
check "schedule_on verifies both timers exist before reporting" "$(grep -A12 '^schedule_on()' lib/cycle.sh | grep -c 'list-timers.*bench-load.timer bench-stop.timer')" 1
check "an empty filtered plan is refused" "$(grep -c 'no box in slot' lib/cycle.sh)" 1
echo PASS
