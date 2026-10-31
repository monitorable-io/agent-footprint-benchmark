#!/usr/bin/env bash
# lib/rotation.sh: agent i runs on box (i + k) mod 11 in cycle k; three cycles = three distinct boxes.
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. lib/rotation.sh
fail=0
expect() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
expect "box_for 0 0" "$(box_for 0 0)" "box-0"
expect "box_for 10 1" "$(box_for 10 1)" "box-0"
expect "box_for 3 2" "$(box_for 3 2)" "box-5"
expect "agent_index monitorable" "$(agent_index monitorable)" "10"
expect "agent_index beszel" "$(agent_index beszel)" "0"
expect "agent_at 0 0" "$(agent_at 0 0)" "beszel"
expect "agent_at 0 1" "$(agent_at 0 1)" "monitorable"
for i in $(seq 0 10); do
  seen=$(for k in 0 1 2; do box_for "$i" "$k"; done | sort -u | wc -l)
  expect "agent $i sees three boxes" "$seen" "3"
done
if ((fail == 0)); then echo PASS; else echo FAIL; exit 1; fi
