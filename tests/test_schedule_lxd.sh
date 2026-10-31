#!/usr/bin/env bash
# Dry run of the on-box timeline (Review Focus 3): the loaded window and the stop are systemd timers
# on the box, so they fire even with no operator connected. Schedules load at +2 min and stop at
# +4 min on a provisioned LXD VM with a running collector, disconnects, waits, then checks.
set -euo pipefail
cd "$(dirname "$0")/.."
VM=${1:-bench-dry}
export BENCH_ROOT=$PWD
. lib/common.sh
. lib/rotation.sh
. lib/cycle.sh
load_env
export IDLE_SECONDS=120 LOAD_SECONDS=120
lxc file push -r -q load "$VM/opt/bench/"
lxc exec "$VM" -- bash -c "systemctl is-active bench-collector > /dev/null || systemctl start bench-collector; : > /var/lib/bench/events.csv; systemctl restart bench-collector"
now=$(date +%s)
schedule_on "$VM" "$now"
echo "scheduled at $now; no session is kept open to the box. waiting 5 min ..."
sleep 300
lxc file push -q tests/schedule-check.sh "$VM/opt/bench/schedule-check.sh"
lxc exec "$VM" -- bash /opt/bench/schedule-check.sh "$now"
echo PASS
