#!/usr/bin/env bash
# Runs ON the box at collect time: on-disk footprint now (not right after install) and the bytes the
# agent's units handed to journald during the idle window (agents that log to stdout are otherwise
# charged nothing for their logs, while agents with their own log files are).
# Usage: footprint.sh <agent> <idle_start_epoch> <idle_end_epoch>   -> /var/lib/bench/footprint.json
set -uo pipefail
agent=$1 s=$2 e=$3
state=${BENCH_STATE:-/var/lib/bench}
dir=${BENCH_AGENTS:-/opt/bench/agents}/$agent
meta=$dir/meta.json
disk=0
while read -r p; do
  [[ -n "$p" && -e "$p" ]] && disk=$((disk + $(du -sb "$p" 2>/dev/null | cut -f1)))
done < <(jq -r '.diskPaths[]?' "$meta" 2>/dev/null)
pkg=$(jq -r '.package // empty' "$meta" 2>/dev/null)
if [[ -n "$pkg" ]] && command -v dpkg-query > /dev/null; then
  kb=$(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null || echo 0)
  disk=$((disk + kb * 1024))
fi
journal=0
if command -v journalctl > /dev/null && [[ -f "$state/install.json" ]]; then
  while read -r u; do
    [[ -n "$u" ]] || continue
    n=$(journalctl -u "$u" --since "@$s" --until "@$e" -o export 2>/dev/null | wc -c)
    journal=$((journal + n))
  done < <(jq -r '.units[]?' "$state/install.json")
fi
umask 077
jq -n --argjson disk "$disk" --argjson journal "$journal" --argjson s "$s" --argjson e "$e" \
  '{disk_bytes: $disk, journal_bytes: $journal, window: {start: $s, end: $e}, measured: now | floor}' > "$state/footprint.json"
echo "FOOTPRINT $agent disk=$disk journal=$journal"
