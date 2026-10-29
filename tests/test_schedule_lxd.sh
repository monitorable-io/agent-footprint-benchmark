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
lxc exec "$VM" -- bash -c '
  set -e
  tail -1 /var/lib/bench/events.csv | grep -q ",stop,," && echo "ok   collector stopped by the on-box timer" || { echo "FAIL no stop event"; tail -3 /var/lib/bench/events.csv; exit 1; }
  systemctl is-active bench-collector > /dev/null && { echo "FAIL collector still active"; exit 1; } || echo "ok   collector inactive"
  peak=$(awk -F, -v s='"$((now + 120))"' -v e='"$((now + 240))"' '"'"'$2=="box" && $1>=s && $1<e {if ($17>m) m=$17} END{print m+0}'"'"' /var/lib/bench/samples.csv)
  echo "box_load1 peak in the load window: $peak"
  awk -v p="$peak" '"'"'BEGIN{exit !(p > 0.8)}'"'"' && echo "ok   load window ran (load > 0.8)" || { echo "FAIL load window did not run"; exit 1; }
  journalctl -u bench-load --no-pager -o cat | grep -E "LOAD_(START|END)" | head -2
'
echo PASS
