#!/usr/bin/env bash
# sink_reset_hubs through a stubbed ssh/scp: credentials go to the remote script's stdin (never argv),
# ssh is called without -n, the PULSE_TOKEN line is exported but never logged, and a remote failure
# aborts the caller.
set -euo pipefail
BENCH_ROOT=$(cd "$(dirname "$0")/.." && pwd); export BENCH_ROOT
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_DIR/ssh.args"
cat > "$STUB_DIR/ssh.stdin"
echo "beszel: forgot box-3 (192.0.2.13, down)"
echo "pulse: forgot box-3 (agent-3…)"
echo "pulse: created agent token 'bench slot-1 box-3'"
echo "PULSE_TOKEN=raw-slot-token-value"
exit "${STUB_EXIT:-0}"
STUB
cat > "$tmp/bin/scp" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$tmp/bin/ssh" "$tmp/bin/scp"
export PATH="$tmp/bin:$PATH" STUB_DIR="$tmp"
export BOX_SINK_IP=192.0.2.9 SSH_KEY_PATH=/dev/null
export BESZEL_ADMIN_EMAIL=admin@example.test BESZEL_ADMIN_PASSWORD=beszel-pw BESZEL_TOKEN=universal-token-value
export PULSE_ADMIN_USER=pulse-admin PULSE_ADMIN_PASSWORD=pulse-pw PULSE_TOKEN=setup-day-token
cd "$BENCH_ROOT"
. lib/common.sh
. lib/sink.sh

fail() { echo "FAIL: $*" >&2; exit 1; }

sink_reset_hubs --pulse-token "bench slot-1 box-3" box-3 2> "$tmp/log"
[[ "$(cat "$tmp/ssh.stdin")" == $'admin@example.test\nbeszel-pw\nuniversal-token-value\npulse-admin\npulse-pw' ]] || fail "stdin: $(cat "$tmp/ssh.stdin")"
grep -qx -- '-n' "$tmp/ssh.args" && fail "ssh called with -n (stdin closed)"
grep -q 'beszel-pw\|pulse-pw\|universal-token-value' "$tmp/ssh.args" && fail "credentials in ssh argv"
grep -q "reset-hubs.py --pulse-token bench\\\\ slot-1\\\\ box-3 box-3" "$tmp/ssh.args" || fail "remote command: $(tail -1 "$tmp/ssh.args")"
grep -q "sink: pulse: forgot box-3" "$tmp/log" || fail "forget line not logged"
grep -q "raw-slot-token-value" "$tmp/log" && fail "token line reached the log"
[[ "$PULSE_TOKEN" == raw-slot-token-value ]] || fail "PULSE_TOKEN not exported: $PULSE_TOKEN"
grep -q "token is exported" "$tmp/log" || fail "export not announced"

# A remote failure aborts the caller (die), in a subshell so this test survives.
if (STUB_EXIT=3 sink_reset_hubs box-3 2> "$tmp/log2"); then fail "remote exit 3 did not abort"; fi
grep -q "reset-hubs failed (exit 3" "$tmp/log2" || fail "die message missing: $(cat "$tmp/log2")"

# --all is refused by the guard while a slot manifest's last stop is in the future (dry-run passes).
export BENCH_ROOT="$tmp/root"; mkdir -p "$BENCH_ROOT/data/2026/slots"
future=$(( $(date +%s) + 3600 ))
printf '{"slot":0,"boxes":[{"stop":%s}]}\n' "$future" > "$BENCH_ROOT/data/2026/slots/slot-0.json"
if (sink_reset_guard --all 2> "$tmp/log3"); then fail "--all not refused while a slot runs"; fi
grep -q "refused" "$tmp/log3" || fail "guard message: $(cat "$tmp/log3")"
sink_reset_guard --all --dry-run || fail "--all --dry-run should pass the guard"
sink_reset_guard box-3 || fail "named boxes should pass the guard"
printf '{"slot":0,"boxes":[{"stop":%s}]}\n' "$(( $(date +%s) - 60 ))" > "$BENCH_ROOT/data/2026/slots/slot-0.json"
sink_reset_guard --all || fail "--all should pass once the slot is over"
echo "test_sink_reset: ok"
