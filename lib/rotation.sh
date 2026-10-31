#!/usr/bin/env bash
# The fixed agent order and the slot schedule.
#
# The bed is 9 measured boxes (box-0..box-8) plus the sink. The 12 roles (11 agents + "none", the
# control box) each run 3 times = 36 role-runs, in 4 slots of 9 boxes. Sequence index q = 9*slot + box:
# the role is ROLES[q mod 12], the run is q div 12 (0..2), so role r lands on boxes r, r+3, r+6 (mod 9):
# three different boxes. Run n is filed as data/<year>/cycle-<n+1>/, which is what summarize.py reads.

AGENTS=(beszel netdata netdata-cloud glances node-exporter telegraf pulse datadog fivenines hetrixtools monitorable)
# shellcheck disable=SC2034  # AGENT_COUNT, SLOT_COUNT: used by lib/cycle.sh, lib/sink.sh
AGENT_COUNT=${#AGENTS[@]}
ROLES=("${AGENTS[@]}" none)
ROLE_COUNT=${#ROLES[@]}
BOX_COUNT=9
# shellcheck disable=SC2034
SLOT_COUNT=4

# agent_index NAME -> 0..10
agent_index() {
  local i
  for i in "${!AGENTS[@]}"; do
    [[ "${AGENTS[$i]}" == "$1" ]] && { printf '%s\n' "$i"; return 0; }
  done
  die "unknown agent $1"
}

# role_at SLOT BOX -> role name running on box-BOX in that slot
role_at() { printf '%s\n' "${ROLES[$(( (BOX_COUNT * $1 + $2) % ROLE_COUNT ))]}"; }

# run_of SLOT BOX -> 0..2, the n-th run of that role (filed as cycle n+1)
run_of() { printf '%s\n' "$(( (BOX_COUNT * $1 + $2) / ROLE_COUNT ))"; }

# outname_of ROLE -> the file stem in the cycle directory (the control role is "control")
outname_of() { if [[ "$1" == "none" ]]; then printf 'control\n'; else printf '%s\n' "$1"; fi; }

# box_running ROLE SLOT -> box-N if the role runs in that slot, else nothing
box_running() {
  local j
  for j in $(seq 0 $((BOX_COUNT - 1))); do
    [[ "$(role_at "$2" "$j")" == "$1" ]] && { printf 'box-%s\n' "$j"; return 0; }
  done
  return 0
}

# slot_plan SLOT -> one line per box: "SLOT box-J ROLE RUN cycle-N OUTNAME"; BENCH_ONLY_BOXES
# (space-separated box names) restricts the lines, never the assignment.
slot_plan() {
  local s=$1 j role run
  for j in $(seq 0 $((BOX_COUNT - 1))); do
    if [[ -n "${BENCH_ONLY_BOXES:-}" ]] && [[ " $BENCH_ONLY_BOXES " != *" box-$j "* ]]; then continue; fi
    role=$(role_at "$s" "$j"); run=$(run_of "$s" "$j")
    printf '%s box-%s %s %s cycle-%s %s\n' "$s" "$j" "$role" "$run" "$((run + 1))" "$(outname_of "$role")"
  done
}
