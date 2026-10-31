#!/usr/bin/env bash
# lib/rotation.sh: 12 roles (11 agents + control) x 3 runs = 36 role-runs over 4 slots of 9 boxes.
# Sequence index q = 9*slot + box: role q mod 12, run q div 12; a role lands on boxes r, r+3, r+6 (mod 9).
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. lib/rotation.sh
fail=0
expect() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
expect "ROLE_COUNT" "$ROLE_COUNT" "12"
expect "BOX_COUNT" "$BOX_COUNT" "9"
expect "SLOT_COUNT" "$SLOT_COUNT" "4"
expect "role_at 0 0" "$(role_at 0 0)" "beszel"
expect "role_at 0 8" "$(role_at 0 8)" "fivenines"
expect "role_at 1 0" "$(role_at 1 0)" "hetrixtools"
expect "role_at 1 2" "$(role_at 1 2)" "none"
expect "role_at 1 3" "$(role_at 1 3)" "beszel"
expect "role_at 2 0" "$(role_at 2 0)" "pulse"
expect "role_at 3 8" "$(role_at 3 8)" "none"
expect "run_of 1 2" "$(run_of 1 2)" "0"
expect "run_of 1 3" "$(run_of 1 3)" "1"
expect "run_of 2 6" "$(run_of 2 6)" "2"
expect "run_of 3 0" "$(run_of 3 0)" "2"
expect "outname_of none" "$(outname_of none)" "control"
expect "outname_of telegraf" "$(outname_of telegraf)" "telegraf"
expect "box_running glances 2" "$(box_running glances 2)" ""
expect "box_running node-exporter 1" "$(box_running node-exporter 1)" "box-7"
expect "box_running none 1" "$(box_running none 1)" "box-2"
expect "agent_index monitorable" "$(agent_index monitorable)" "10"
for role in "${ROLES[@]}"; do
  pairs=$(for s in 0 1 2 3; do for j in 0 1 2 3 4 5 6 7 8; do if [[ "$(role_at "$s" "$j")" == "$role" ]]; then echo "$s $j $(run_of "$s" "$j")"; fi; done; done)
  expect "$role: three role-runs" "$(wc -l <<<"$pairs")" "3"
  expect "$role: three distinct boxes" "$(awk '{print $2}' <<<"$pairs" | sort -u | wc -l)" "3"
  expect "$role: runs 0 1 2 in slot order" "$(awk '{print $3}' <<<"$pairs" | paste -sd' ')" "0 1 2"
done
expect "slot_plan 0 has 9 lines" "$(slot_plan 0 | wc -l)" "9"
expect "slot_plan 1 line for box-2" "$(slot_plan 1 | awk '$2=="box-2"')" "1 box-2 none 0 cycle-1 control"
expect "slot_plan 1 line for box-3" "$(slot_plan 1 | awk '$2=="box-3"')" "1 box-3 beszel 1 cycle-2 beszel"
expect "BENCH_ONLY_BOXES filters slot_plan" "$(BENCH_ONLY_BOXES="box-4 box-7" slot_plan 0 | awk '{print $2}' | paste -sd' ')" "box-4 box-7"
expect "box_for removed" "$(declare -F box_for || echo gone)" "gone"
expect "agent_at removed" "$(declare -F agent_at || echo gone)" "gone"
if ((fail == 0)); then echo PASS; else echo FAIL; exit 1; fi
