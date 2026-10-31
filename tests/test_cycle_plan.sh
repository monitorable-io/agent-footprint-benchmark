#!/usr/bin/env bash
# bench cycle plan: the slot table the run follows, from a minimal env (no network).
set -euo pipefail
cd "$(dirname "$0")/.."
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
printf 'BENCH_PROVIDER=hcloud\nHCLOUD_TOKEN=fixture\n' > "$d/bench.env"
chmod 0600 "$d/bench.env"
export BENCH_ENV="$d/bench.env"
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; exit 1; fi; }
check "plan 1 has 9 lines" "$(./bench cycle plan 1 | wc -l)" 9
check "plan 1 box-2 is the control run 0 -> cycle-1" "$(./bench cycle plan 1 | awk '$2=="box-2"')" "1 box-2 none 0 cycle-1 control"
check "plan 1 box-3 is beszel run 1 -> cycle-2" "$(./bench cycle plan 1 | awk '$2=="box-3"')" "1 box-3 beszel 1 cycle-2 beszel"
check "plan 3 box-8 is the control run 2 -> cycle-3" "$(./bench cycle plan 3 | awk '$2=="box-8"')" "3 box-8 none 2 cycle-3 control"
check "BENCH_ONLY_BOXES restricts the plan" "$(BENCH_ONLY_BOXES=box-4 ./bench cycle plan 1 | wc -l)" 1
check "plan with no slot prints all four" "$(./bench cycle plan | wc -l)" 36
check "slot 4 is refused" "$(./bench cycle plan 4 2>&1 >/dev/null | grep -c 'usage')" 1
check "cycle start 4 is refused" "$(./bench cycle start 4 2>&1 >/dev/null | grep -c '0|1|2|3')" 1
check "collect 4 is refused" "$(./bench collect 4 2>&1 >/dev/null | grep -c '0|1|2|3')" 1
echo PASS
