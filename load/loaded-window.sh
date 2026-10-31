#!/usr/bin/env bash
# The loaded hour on a box: stress-ng on CPU, memory and disk for 3600 s, plus a short-lived
# container every 10 minutes so container-discovery code paths run. Scheduled by `bench cycle start`.
set -u
DURATION=${1:-3600}
echo "LOAD_START $(date +%s)"
stress-ng --cpu "$(nproc)" --vm 1 --vm-bytes 512M --vm-keep --hdd 1 --hdd-bytes 1G --temp-path /var/tmp --timeout "${DURATION}s" --metrics-brief &
stress_pid=$!
end=$(( $(date +%s) + DURATION ))
while (( $(date +%s) < end )); do
  docker run --rm --name bench-churn alpine:3.20 sleep 30 > /dev/null 2>&1 || true
  sleep 570
done
wait "$stress_pid"
echo "LOAD_END $(date +%s)"
