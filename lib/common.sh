#!/usr/bin/env bash
# Shared helpers for the bench CLI. Sourced, never executed.

BENCH_ROOT="${BENCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BENCH_ENV="${BENCH_ENV:-$BENCH_ROOT/bench.env}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# require_env NAME...: every named variable must be set and non-empty.
require_env() {
  local n
  for n in "$@"; do
    [[ -n "${!n:-}" ]] || die "$n is not set (see bench.env.example)"
  done
}

# load_env: source bench.env. It holds secrets, so it must exist and be 0600.
load_env() {
  [[ -f "$BENCH_ENV" ]] || die "bench.env missing (copy bench.env.example)"
  local mode
  mode=$(stat -c %a "$BENCH_ENV")
  [[ "$mode" == "600" ]] || die "bench.env must be mode 0600 (is $mode)"
  set -a
  # shellcheck disable=SC1090
  . "$BENCH_ENV"
  set +a
}

# box_ip NAME: the BOX_<NAME>_IP value for a box name like "box-3" or "sink".
box_ip() {
  local key
  key="BOX_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")_IP"
  [[ -n "${!key:-}" ]] || die "$key is not set: rent the box first (bench vm create $1)"
  printf '%s' "${!key}"
}

ssh_opts() {
  printf '%s' "-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -i ${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
}

# ssh_box NAME CMD...: run a command on the box as root.
ssh_box() {
  local name=$1; shift
  # shellcheck disable=SC2046,SC2029
  ssh $(ssh_opts) "root@$(box_ip "$name")" "$@"
}

# scp_box NAME SRC DST: copy a local path (recursively) to the box.
scp_box() {
  local name=$1 src=$2 dst=$3
  # shellcheck disable=SC2046
  scp -q -r $(ssh_opts) "$src" "root@$(box_ip "$name"):$dst"
}
