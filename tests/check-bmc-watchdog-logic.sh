#!/usr/bin/env bash
# Suite 6: unit tests for the BMC watchdog's guard logic — no hardware, no BMC.
#
# The README's central self-healing safety claim is "no boot loops by
# construction"; that claim lives entirely in guarded_cycle()'s cooldown and
# give-up branches plus cycles_in_24h(). This suite pins it with a stubbed
# clock, a stubbed `tpi`, and a fake state dir. Also covers the two probe
# parsers against canned curl output.
#
# Runs in CI (hardware-free).

set -u

FAILED=0
PASSED=0
pass() { echo "  PASS [$1]"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL [$1] $2"; FAILED=$((FAILED + 1)); }

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# Stub tpi: log invocations, report all nodes On.
mkdir -p "$TESTDIR/bin"
cat > "$TESTDIR/bin/tpi" <<'EOF'
#!/bin/sh
echo "$@" >> "${TPI_CALLS:?}"
case "$1" in
  power) [ "$2" = status ] && printf 'node1: On\nnode2: On\nnode3: On\nnode4: On\n' ;;
esac
exit 0
EOF
chmod +x "$TESTDIR/bin/tpi"
export PATH="$TESTDIR/bin:$PATH"
export TPI_CALLS="$TESTDIR/tpi.calls"
: > "$TPI_CALLS"

# Source the daemon's functions only.
BMC_WATCHDOG_TEST=1
export BMC_WATCHDOG_TEST
# shellcheck source=../scripts/bmc/bmc-watchdog.sh
. "$(dirname "$0")/../scripts/bmc/bmc-watchdog.sh"

# Redirect state/log into the sandbox and stub the clock.
STATE="$TESTDIR/state"; mkdir -p "$STATE"
LOG="$TESTDIR/wd.log"; : > "$LOG"
FAKE_NOW=1000000
now() { echo "$FAKE_NOW"; }
# Shrink the sleep inside cycle_node
sleep() { :; }

echo "Suite 6: BMC watchdog guard logic"

# ── T1: guards pass → cycles, records state, logs ACTION ────────────────
: > "$TPI_CALLS"
if guarded_cycle 2 ssh yes \
   && grep -q "power off -n 2" "$TPI_CALLS" \
   && grep -q "power on -n 2" "$TPI_CALLS" \
   && [ -f "$STATE/cycled.2" ] \
   && [ "$(cat "$STATE/last_cycle.2")" = "$FAKE_NOW" ] \
   && grep -q "ACTION node2" "$LOG"; then
  pass "T1 guards-pass → power-cycle + state + log"
else
  fail "T1" "expected a full cycle"
fi

# ── T2: cooldown holds — no second cycle, HOLD logged once ──────────────
: > "$TPI_CALLS"
FAKE_NOW=$((FAKE_NOW + 60))   # 60s later << COOLDOWN (1800)
if ! guarded_cycle 2 ssh yes \
   && [ ! -s "$TPI_CALLS" ] \
   && [ "$(grep -c "HOLD node2" "$LOG")" = 1 ]; then
  pass "T2 cooldown → HOLD, no power calls"
else
  fail "T2" "cooldown did not hold"
fi
# at=no must not log a second HOLD
guarded_cycle 2 ssh no && fail "T2b" "cycled during cooldown" \
  || { [ "$(grep -c "HOLD node2" "$LOG")" = 1 ] && pass "T2b HOLD logged once, not per-round"; }

# ── T3: 24h cycle cap → GIVE-UP, node stays down ────────────────────────
FAKE_NOW=$((FAKE_NOW + 7200)) # past cooldown
now >> "$STATE/cycles.2"; now >> "$STATE/cycles.2"  # 3 total in 24h with T1's
: > "$TPI_CALLS"
rm -f "$STATE/last_cycle.2"
if ! guarded_cycle 2 ssh yes \
   && [ ! -s "$TPI_CALLS" ] \
   && grep -q "GIVE-UP node2" "$LOG"; then
  pass "T3 cycle cap → GIVE-UP, no boot loop"
else
  fail "T3" "cap did not hold: $(cat "$TPI_CALLS")"
fi

# ── T4: cycles_in_24h ages out old timestamps ───────────────────────────
echo $((FAKE_NOW - 90000)) > "$STATE/cycles.3"   # >24h ago
echo $((FAKE_NOW - 100))  >> "$STATE/cycles.3"   # recent
if [ "$(cycles_in_24h 3)" = "1" ]; then
  pass "T4 cycles_in_24h excludes >24h-old entries"
else
  fail "T4" "got $(cycles_in_24h 3), want 1"
fi

# ── T5: probe_ok parses an SSH banner, rejects everything else ───────────
curl() { printf 'SSH-2.0-OpenSSH_9.6p1 Ubuntu\r\n'; }
probe_ok 192.0.2.1 && pass "T5a probe_ok accepts SSH-2.0 banner" \
  || fail "T5a" "rejected a valid banner"
curl() { printf 'HTTP/1.1 400 Bad Request\r\n'; }
probe_ok 192.0.2.1 && fail "T5b" "accepted a non-SSH banner" \
  || pass "T5b probe_ok rejects non-SSH response"
curl() { return 28; }   # timeout
probe_ok 192.0.2.1 && fail "T5c" "accepted a timeout" \
  || pass "T5c probe_ok rejects timeout/empty"

# ── T6: deep_probe_ok needs the /mnt/ssd mount metric ────────────────────
curl() { printf 'node_filesystem_size_bytes{device="/dev/nvme0n1p1",fstype="ext4",mountpoint="/mnt/ssd"} 2.0e+12\n'; }
deep_probe_ok 192.0.2.1 && pass "T6a deep_probe_ok sees /mnt/ssd metric" \
  || fail "T6a" "missed the metric"
curl() { printf 'node_filesystem_size_bytes{device="/dev/mmcblk0p2",fstype="ext4",mountpoint="/"} 6.0e+10\n'; }
deep_probe_ok 192.0.2.1 && fail "T6b" "accepted metrics without /mnt/ssd" \
  || pass "T6b deep_probe_ok rejects when /mnt/ssd absent"

echo "─────────────────────────────────"
echo "Results: ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
