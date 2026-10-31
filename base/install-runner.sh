#!/usr/bin/env bash
# Runs one agent's documented install on this box, timed, and records the outcome as JSON.
# Never fails the caller: a failed install is a row with status "failed" (the cycle goes on).
# Usage: install-runner.sh <agent>     (env: BENCH_STATE=/var/lib/bench, BENCH_AGENTS=/opt/bench/agents)
set -uo pipefail
agent=$1
state=${BENCH_STATE:-/var/lib/bench}
dir=${BENCH_AGENTS:-/opt/bench/agents}/$agent
log=$state/install.log
meta=$dir/meta.json

command -v apt-get > /dev/null && apt-get clean > /dev/null 2>&1   # cold package cache, as on a fresh box
# The runner's own files are root-only (vendor output may echo keys); the vendor install itself runs
# under the default umask, as it would for any admin (a 077 umask breaks apt keyrings, for one).
install -m 0600 /dev/null "$log"
started=$(date +%s.%N)
bash "$dir/install.sh" > "$log" 2>&1
rc=$?
finished=$(date +%s.%N)
sleep 5   # daemons that bind late (Glances) show their port
seconds=$(awk -v a="$started" -v b="$finished" 'BEGIN{printf "%.1f", b-a}')

version=$(grep -m1 '^VERSION=' "$log" | cut -d= -f2-)
units=$(grep -m1 '^UNITS=' "$log" | cut -d= -f2- | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)
[[ -n "$units" ]] || units='[]'
if command -v ss > /dev/null; then
  ports=$(ss -Hltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | jq -R 'tonumber? // empty' | jq -s .)
else
  ports='[]'
fi
disk=0
while read -r p; do
  [[ -n "$p" && -e "$p" ]] && disk=$((disk + $(du -sb "$p" 2>/dev/null | cut -f1)))
done < <(jq -r '.diskPaths[]?' "$meta" 2>/dev/null)
pkg=$(jq -r '.package // empty' "$meta" 2>/dev/null)
if [[ -n "$pkg" ]] && command -v dpkg-query > /dev/null; then
  kb=$(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null || echo 0)
  disk=$((disk + kb * 1024))
fi
[[ $rc -eq 0 ]] && status=ok || status=failed
umask 077

# Redact every secret value the agent's env file carries (vendor installers echo keys) before the
# tail is recorded: install.json ends up in the published raw data. The file is %q-quoted, so the
# decoded values come from sourcing it in a subshell, never from re-parsing it. Keys named like a
# secret are masked whatever their length; other values when 8+ chars.
redacted=$(tail -n 50 "$log")
if [[ -f "$dir/env" ]]; then
  values=()
  while read -r k; do
    [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    # shellcheck disable=SC1091
    v=$(. "$dir/env" 2>/dev/null; printf '%s' "${!k:-}")
    [[ -n "$v" ]] || continue
    if [[ "$k" =~ (KEY|TOKEN|SECRET|PASS) || ${#v} -ge 8 ]]; then values+=("$v"); fi
  done < <(cut -d= -f1 "$dir/env")
  # Longest value first, so a secret containing another secret leaves no fragment behind.
  while IFS= read -r v; do
    [[ -n "$v" ]] && redacted=${redacted//"$v"/***}
  done < <(printf '%s\n' "${values[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
fi

kernel=$(uname -r)
jq -n --arg agent "$agent" --arg kernel "$kernel" --arg started "$started" --arg finished "$finished" --arg seconds "$seconds" \
  --arg status "$status" --argjson rc "$rc" --arg version "$version" --argjson units "$units" \
  --argjson ports "$ports" --argjson disk "$disk" --arg logtail "$redacted" \
  '{agent: $agent, kernel: $kernel, started: ($started|tonumber), finished: ($finished|tonumber), seconds: ($seconds|tonumber),
    status: $status, exit_code: $rc, version: $version, units: $units, listening_ports: $ports,
    disk_bytes: $disk, tail: ($logtail | split("\n") | map(select(length > 0)))}' > "$state/install.json"
echo "INSTALL_$status $agent ${seconds}s rc=$rc version=$version"
exit 0
