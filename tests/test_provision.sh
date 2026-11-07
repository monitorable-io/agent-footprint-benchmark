#!/usr/bin/env bash
# base/apt-timers.sh (run by base/provision.sh) through a stubbed systemctl: Ubuntu's apt-daily timers
# are masked and stopped, unattended-upgrades is stopped, a second run (a redo on a provisioned box)
# succeeds whatever `mask` says about an already-masked unit, and a timer left unmasked fails it.
set -euo pipefail
BENCH_ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/masked"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$1" in
  mask)
    shift; [[ "$1" == --now ]] && shift
    rc=0
    for u in "$@"; do
      if [[ -e "$STUB_DIR/masked/$u" ]]; then echo "Unit $u is already masked." >&2; rc=${STUB_MASK_AGAIN_RC:-0}; fi
      [[ -n "${STUB_MASK_BROKEN:-}" ]] || touch "$STUB_DIR/masked/$u"
    done
    exit "$rc";;
  stop) echo "Failed to stop $2: Unit $2 not loaded." >&2; exit 5;;
  is-enabled) if [[ -e "$STUB_DIR/masked/$2" ]]; then echo masked; exit 1; else echo enabled; exit 0; fi;;
esac
exit 0
STUB
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH" STUB_DIR="$tmp"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { bash "$BENCH_ROOT/base/apt-timers.sh" > "$tmp/out" 2>&1; }

run || fail "first run: $(cat "$tmp/out")"
grep -qx 'mask --now apt-daily.timer apt-daily-upgrade.timer' "$tmp/calls" || fail "timers not masked: $(cat "$tmp/calls")"
grep -qx 'stop unattended-upgrades.service' "$tmp/calls" || fail "unattended-upgrades not stopped: $(cat "$tmp/calls")"
[[ -e "$tmp/masked/apt-daily.timer" && -e "$tmp/masked/apt-daily-upgrade.timer" ]] || fail "stub state"

# Review Focus 4: a redo on a box whose timers are already masked, even if mask complains.
STUB_MASK_AGAIN_RC=1 run || fail "second run on masked timers: $(cat "$tmp/out")"

# A timer that did not end up masked is a provisioning failure (the method depends on it).
rm -f "$tmp/masked/"*
STUB_MASK_BROKEN=1 run && fail "unmasked timer passed: $(cat "$tmp/out")"
grep -q 'apt-daily.timer is enabled, not masked' "$tmp/out" || fail "no reason given: $(cat "$tmp/out")"

grep -qF "bash \"\$here/apt-timers.sh\"" "$BENCH_ROOT/base/provision.sh" || fail "provision.sh does not run apt-timers.sh"
echo "PASS"
