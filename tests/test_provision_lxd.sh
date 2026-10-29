#!/usr/bin/env bash
# Dry run of base/provision.sh in a local LXD VM (not part of tests/run.sh: needs LXD + network).
# Leaves the VM running for the next tasks' dry runs. Usage: tests/test_provision_lxd.sh [vm-name]
set -euo pipefail
cd "$(dirname "$0")/.."
VM=${1:-bench-dry}
if ! lxc info "$VM" > /dev/null 2>&1; then
  lxc launch images:ubuntu/26.04 "$VM" --vm -c limits.cpu=1 -c limits.memory=2GiB
fi
echo "waiting for $VM ..."
for _ in $(seq 1 60); do
  lxc exec "$VM" -- systemctl is-system-running --wait > /dev/null 2>&1 && break
  sleep 5
done
lxc exec "$VM" -- mkdir -p /opt/bench
for d in base collector load; do
  [[ -d "$d" ]] && lxc file push -r -q "$d" "$VM/opt/bench/"
done
lxc exec "$VM" -- bash /opt/bench/base/provision.sh --name "$VM" --no-cron --ports 9100

fail=0
check() { if lxc exec "$VM" -- bash -c "$2" > /dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "two containers running" "docker ps --format '{{.Names}}' | grep -qx bench-nginx && docker ps --format '{{.Names}}' | grep -qx bench-valkey"
check "stress-ng installed" "stress-ng --version"
check "cron absent" "! systemctl is-enabled cron"
check "ufw allows 22 and 9100" "ufw status | grep -q '^22/tcp' && ufw status | grep -q '^9100/tcp' && ufw status | grep -q 'Status: active'"
check "hostname set" "[ \"\$(hostname)\" = $VM ]"
check "nft and python3 present" "nft --version && python3 --version"
check "password ssh off" "sshd -T | grep -q '^passwordauthentication no'"
check "bench dirs" "test -d /var/lib/bench"
if ((fail == 0)); then echo PASS; else echo FAIL; exit 1; fi
