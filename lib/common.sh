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
  printf '%s' "-n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -i ${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
}

# ssh_box NAME CMD...: run a command on the box as root. A BOX_<NAME>_IP of the form
# lxd:<instance> addresses a local LXD instance instead (dry runs), through lxc exec.
ssh_box() {
  local name=$1; shift
  local ip
  ip=$(box_ip "$name")
  if [[ "$ip" == lxd:* ]]; then
    lxc exec "${ip#lxd:}" -- bash -c "$*"
  else
    # shellcheck disable=SC2046,SC2029
    ssh $(ssh_opts) "root@$ip" "$@"
  fi
}

# scp_box NAME SRC DST: copy a local path (recursively) to the box.
scp_box() {
  local name=$1 src=$2 dst=$3
  local ip
  ip=$(box_ip "$name")
  if [[ "$ip" == lxd:* ]]; then
    if [[ -d "$src" ]]; then lxc file push -r -q "$src" "${ip#lxd:}$dst"; else lxc file push -q "$src" "${ip#lxd:}$dst"; fi
  else
    # shellcheck disable=SC2046
    scp -q -r $(ssh_opts | sed 's/^-n //') "$src" "root@$ip:$dst"
  fi
}

# fetch_box NAME SRC DST: copy a file from the box to a local path.
fetch_box() {
  local name=$1 src=$2 dst=$3
  local ip
  ip=$(box_ip "$name")
  if [[ "$ip" == lxd:* ]]; then
    lxc file pull -q "${ip#lxd:}$src" "$dst"
  else
    # shellcheck disable=SC2046
    scp -q $(ssh_opts | sed 's/^-n //') "root@$ip:$src" "$dst"
  fi
}

# --- VM provider dispatch -------------------------------------------------------------------------
# BENCH_PROVIDER (bench.env) names the client: lib/hcloud.sh (Hetzner Cloud) or lib/onidel.sh.
# Every provider defines <provider>_vm_list|quote|create|destroy|reimage; the vm_* names below are
# what the rest of bench calls (cycle start reimages through vm_reimage).
export BENCH_FIXTURES=""   # read by lib/hcloud.sh and lib/onidel.sh

# strip_fixtures ARGS...: consumes a leading or trailing `--fixtures DIR` (recorded API responses
# instead of the network), leaves the rest in REST[].
strip_fixtures() {
  REST=()
  while (($#)); do
    if [[ "$1" == "--fixtures" ]]; then BENCH_FIXTURES=$2; shift 2; else REST+=("$1"); shift; fi
  done
}

provider() {
  require_env BENCH_PROVIDER
  case "$BENCH_PROVIDER" in
    hcloud|onidel) printf '%s' "$BENCH_PROVIDER";;
    *) die "BENCH_PROVIDER must be hcloud or onidel (is '$BENCH_PROVIDER')";;
  esac
}
# vm_dispatch VERB [ARGS]: <provider>_vm_VERB; a missing or odd BENCH_PROVIDER stops the command.
vm_dispatch() { local p; p=$(provider) || exit 1; "${p}_vm_$1" "${@:2}"; }
vm_list()    { vm_dispatch list; }
vm_quote()   { vm_dispatch quote; }
vm_create()  { vm_dispatch create "$@"; }
vm_destroy() { vm_dispatch destroy "$@"; }
vm_reimage() { vm_dispatch reimage "$@"; }

# write_env_var KEY VALUE: set KEY in bench.env in place (keeps mode 0600).
write_env_var() {
  local key=$1 value=$2
  if grep -q "^$key=" "$BENCH_ENV"; then
    sed -i "s|^$key=.*|$key=$value|" "$BENCH_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >> "$BENCH_ENV"
  fi
}

env_key_for() { printf 'BOX_%s' "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"; }

# box_name_of_ip IP: the box whose BOX_<NAME>_IP is IP (box-3, sink, ...), or "-".
box_name_of_ip() {
  local v n
  for v in $(compgen -A variable | grep -E '^BOX_[A-Z0-9_]+_IP$'); do
    [[ "${!v}" == "$1" ]] || continue
    n=${v#BOX_}; n=${n%_IP}
    tr '[:upper:]_' '[:lower:]-' <<<"$n"
    return 0
  done
  printf -- '-\n'
}

cmd_quote() { strip_fixtures "$@"; load_env; vm_quote; }

cmd_vm() {
  strip_fixtures "$@"
  load_env
  local sub=${REST[0]:-} name=${REST[1]:-}
  case "$sub" in
    list) vm_list;;
    rebuild|reimage) [[ -n "$name" ]] || die "usage: bench vm $sub <box>"; vm_reimage "$name";;
    create|destroy) [[ -n "$name" ]] || die "usage: bench vm $sub <box>"; "vm_$sub" "$name";;
    *) die "usage: bench vm list|rebuild|create|destroy <box>";;
  esac
}
