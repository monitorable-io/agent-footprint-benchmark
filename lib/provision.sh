#!/usr/bin/env bash
# bench provision <box> [--no-cron] [--ports a,b]: stage base/, collector/, load/ on the box and run
# base/provision.sh there (idempotent).

cmd_provision() {
  local box=${1:-}
  [[ -n "$box" ]] || die "usage: bench provision <box> [--no-cron] [--ports a,b]"
  shift
  load_env
  ssh_box "$box" "mkdir -p /opt/bench"
  local d
  for d in base collector load; do
    scp_box "$box" "$BENCH_ROOT/$d" /opt/bench/
  done
  ssh_box "$box" "bash /opt/bench/base/provision.sh --name $box $*"
}
