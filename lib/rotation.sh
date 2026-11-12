#!/usr/bin/env bash
# The fixed agent order and the slot schedule.
#
# The bed is 9 measured boxes (box-0..box-8) plus the sink. The 12 roles (11 agents + "none", the
# control box) each run 3 times = 36 role-runs, in 4 slots of 9 boxes. Sequence index q = 9*slot + box:
# the role is ROLES[q mod 12], the run is q div 12 (0..2), so role r lands on boxes r, r+3, r+6 (mod 9):
# three different boxes. Run n is filed as data/<year>/cycle-<n+1>/, which is what summarize.py reads.
#
# A slot plan file, data/<year>/slots/slot-<s>.plan, replaces the rotation for that slot: one line per
# box, "box-J ROLE RUN" (RUN 0..2; '#' comments). The instrumented retest slot uses one: chosen roles,
# three boxes with the same role, each filed as the run it stands for. BENCH_SLOT_COUNT (environment or
# bench.env) is the number of slots of the run, 4 unless set: the unattended runner stops after the last.
# A run that has any plan file has no rotation slots at all: a slot without a file has no roles there,
# so a wrong slot count cannot start a rotation slot over the planned slot's files.

AGENTS=(beszel netdata netdata-cloud glances node-exporter telegraf pulse datadog fivenines hetrixtools monitorable)
# shellcheck disable=SC2034  # AGENT_COUNT, SLOT_COUNT: used by lib/cycle.sh, lib/sink.sh
AGENT_COUNT=${#AGENTS[@]}
ROLES=("${AGENTS[@]}" none)
ROLE_COUNT=${#ROLES[@]}
BOX_COUNT=9
# shellcheck disable=SC2034
SLOT_COUNT=${BENCH_SLOT_COUNT:-4}

slot_plan_file() { printf '%s/data/%s/slots/slot-%s.plan' "$BENCH_ROOT" "${YEAR:-$(date +%Y)}" "$1"; }

# plan_driven: this run's data root has a plan file for some slot
plan_driven() { compgen -G "$BENCH_ROOT/data/${YEAR:-$(date +%Y)}/slots/slot-*.plan" > /dev/null; }

# plan_field SLOT BOX N -> field N (2 = role, 3 = run) of the plan file's line for box-BOX; nothing if none
plan_field() { awk -v b="box-$2" -v n="$3" '{ sub(/\r$/, "") } !/^[[:space:]]*(#|$)/ && $1 == b { print $n; exit }' "$(slot_plan_file "$1")"; }

# plan_check SLOT: dies on a plan file that names an unknown role or box, a run outside 0..2, a box
# twice, or the same role and run twice (both would be filed as the same cycle file). No file: fine in
# a rotation run, refused in a plan-driven one.
plan_check() {
  local f line box role run n=0 seen=" " filed=" "
  f=$(slot_plan_file "$1")
  if [[ ! -f "$f" ]]; then
    if plan_driven; then die "slot $1 has no plan file ($f) and this run is plan-driven: it has no rotation slots"; fi
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do   # the last line counts even without a newline
    line=${line%$'\r'}
    read -r box role run _ <<<"$line" || true
    [[ -z "$box" || "$box" == \#* ]] && continue
    if ! [[ "$box" =~ ^box-(0|[1-9][0-9]*)$ ]] || (( ${box#box-} >= BOX_COUNT )); then die "$f: no such box: $box"; fi
    [[ " ${ROLES[*]} " == *" $role "* ]] || die "$f: unknown role: $role"
    [[ "$run" =~ ^[0-2]$ ]] || die "$f: $box $role: run must be 0, 1 or 2 (got '$run')"
    [[ "$seen" != *" $box "* ]] || die "$f: $box is named twice"
    [[ "$filed" != *" $role/$run "* ]] || die "$f: $role run $run is named twice (both would be filed as cycle-$((run + 1)))"
    seen+="$box "; filed+="$role/$run "; n=$((n + 1))
  done < "$f"
  ((n > 0)) || die "$f: no box in the plan"
  # What will run is what was checked: every checked line, and nothing else, comes out of slot_plan.
  [[ "$(BENCH_ONLY_BOXES='' slot_plan "$1" | wc -l)" == "$n" ]] || die "$f: $n lines checked, but slot_plan reads a different number"
}

# agent_index NAME -> 0..10
agent_index() {
  local i
  for i in "${!AGENTS[@]}"; do
    [[ "${AGENTS[$i]}" == "$1" ]] && { printf '%s\n' "$i"; return 0; }
  done
  die "unknown agent $1"
}

# role_at SLOT BOX -> role name running on box-BOX in that slot (empty: the slot's plan file has no line for it)
role_at() {
  if [[ -f "$(slot_plan_file "$1")" ]]; then plan_field "$1" "$2" 2; return 0; fi
  if plan_driven; then return 0; fi
  printf '%s\n' "${ROLES[$(( (BOX_COUNT * $1 + $2) % ROLE_COUNT ))]}"
}

# run_of SLOT BOX -> 0..2, the n-th run of that role (filed as cycle n+1)
run_of() {
  if [[ -f "$(slot_plan_file "$1")" ]]; then plan_field "$1" "$2" 3; return 0; fi
  if plan_driven; then return 0; fi
  printf '%s\n' "$(( (BOX_COUNT * $1 + $2) / ROLE_COUNT ))"
}

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
    [[ -n "$role" ]] || continue   # a plan file that leaves this box out
    printf '%s box-%s %s %s cycle-%s %s\n' "$s" "$j" "$role" "$run" "$((run + 1))" "$(outname_of "$role")"
  done
}
