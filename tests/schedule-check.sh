#!/usr/bin/env bash
# Runs ON the box after the scheduled load + stop should have fired. Usage: schedule-check.sh <t0>
set -euo pipefail
t0=$1
if tail -1 /var/lib/bench/events.csv | grep -q ",stop,,"; then echo "ok   collector stopped by the on-box timer"; else echo "FAIL no stop event"; tail -3 /var/lib/bench/events.csv; exit 1; fi
if systemctl is-active bench-collector > /dev/null; then echo "FAIL collector still active"; exit 1; else echo "ok   collector inactive"; fi
peak=$(awk -F, -v s="$((t0 + 120))" -v e="$((t0 + 240))" '$2=="box" && $1>=s && $1<e {if ($17>m) m=$17} END{print m+0}' /var/lib/bench/samples.csv)
echo "box_load1 peak in the load window: $peak"
if awk -v p="$peak" 'BEGIN{exit !(p > 0.8)}'; then echo "ok   load window ran (load > 0.8)"; else echo "FAIL load window did not run"; exit 1; fi
journalctl -u bench-load --no-pager -o cat | grep -E "LOAD_(START|END)" | head -2 || true
