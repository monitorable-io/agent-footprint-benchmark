#!/usr/bin/env bash
# merge_meta: meta.json + install.json + schedule.json (+ footprint.json) -> the per-cycle meta summarize reads.
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. lib/rotation.sh
. lib/cycle.sh
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
printf '{"name":"none","kind":"none","footnotes":["control"]}' > "$d/meta.json"
printf '{"status":"ok","seconds":1.5,"version":"none","units":[],"disk_bytes":10}' > "$d/install.json"
printf '{"agent":"none","box":"control","installFinished":100,"loadStart":200,"stop":300}' > "$d/schedule-control.json"
printf '{"disk_bytes":20,"journal_bytes":5}' > "$d/footprint.json"
out=$(merge_meta "$d/meta.json" "$d/install.json" "$d/schedule-control.json" "$d/footprint.json")
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; exit 1; fi; }
check "schedule merged" "$(jq -r .schedule.box <<<"$out")" control
check "footprint merged" "$(jq -r .footprint.disk_bytes <<<"$out")" 20
check "install merged" "$(jq -r .install.status <<<"$out")" ok
out2=$(merge_meta "$d/meta.json" "$d/install.json" "$d/schedule-control.json" "$d/missing.json")
check "footprint optional" "$(jq -r '.footprint // "none"' <<<"$out2")" none
check "no world-open ports from cycle" "$(grep -c -- '--ports' lib/cycle.sh)" 0
check "no caller of the old rotation left" "$(grep -c 'box_for\|agent_at' lib/*.sh | awk -F: '{s+=$2} END{print s}')" 0
echo PASS
