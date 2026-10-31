#!/usr/bin/env bash
# run_isolated: a failing step inside a box's setup must stop that box's remaining steps and be
# recorded, even though the caller keeps going. `( ... ) || log` does NOT do that: bash ignores
# set -e inside any command of an || list, so later steps ran on a half-provisioned box.
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; exit 1; fi; }
step_fails_midway() { false; echo "leaked"; }
step_ok() { echo "ran"; }
# Called as a plain statement, as cycle.sh does: inside an || or && list bash would suspend set -e again.
out=$(run_isolated "$d/failures.log" "box-1: setup failed" step_fails_midway 2>&1)
check "later commands of a failed step do not run" "$out" ""
check "the failure is recorded" "$(cat "$d/failures.log")" "box-1: setup failed"
out=$(run_isolated "$d/failures.log" "box-2: setup failed" step_ok)
check "a good step runs and prints" "$out" "ran"
check "a good step records nothing" "$(wc -l < "$d/failures.log")" 1
check "the caller survives a failed step" "$(run_isolated "$d/failures.log" "x" false; echo survived)" "survived"
check "cycle.sh uses it for every box" "$(grep -c 'run_isolated' lib/cycle.sh)" 2
check "no bare ( ... ) || left in cycle.sh" "$(grep -cE '^\s*\( (cycle_one_box|collect_box) .*\) \|\|' lib/cycle.sh)" 0
echo PASS
