#!/usr/bin/env bash
# Suite 1 (dry-run) + Suite 2 (mock/fault-injection) test runner.
# No TuringPi hardware required. All tests are offline except M04/M05 which need
# a local file:// URL (no external network).
#
# Usage:
#   ./tests/run-ci.sh
#   ./tests/run-ci.sh --suite 1        # dry-run only
#   ./tests/run-ci.sh --suite 2        # mock only

set -uo pipefail
cd "$(dirname "$0")/.."

# Prevent auto-loading of ./bootstrap-config.kv and ./bootstrap-state.kv during
# tests — each test that needs config/state isolation passes its own files explicitly.
export BOOTSTRAP_NO_AUTO_CONFIG=1
export BOOTSTRAP_NO_AUTO_STATE=1

BOOTSTRAP="./bootstrap-turingpi-cluster.exp"
TEARDOWN="./teardown-cluster.exp"
FIXTURES="./tests/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
SUITE="${1:-all}"
if [[ "${1:-}" == "--suite" ]]; then SUITE="${2:-all}"; fi

# ── helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

run_test() {
  # run_test NAME EXPECT_RC MUST_CONTAIN MUST_NOT_CONTAIN [cmd args...]
  # EXPECT_RC: integer, or "any" to skip exit-code check
  # MUST_CONTAIN / MUST_NOT_CONTAIN: grep -q pattern, or "" to skip
  local name="$1" expect_rc="$2" must_have="${3:-}" must_not="${4:-}"
  shift 4

  local out rc=0
  out=$("$@" 2>&1) || rc=$?

  local ok=1
  if [[ "$expect_rc" != "any" && $rc -ne $expect_rc ]]; then
    echo -e "  ${RED}FAIL${NC} [$name]: expected exit $expect_rc, got $rc"; ok=0
  fi
  if [[ -n "$must_have" ]] && ! echo "$out" | grep -q "$must_have"; then
    echo -e "  ${RED}FAIL${NC} [$name]: output missing '$must_have'"; ok=0
  fi
  if [[ -n "$must_not" ]] && echo "$out" | grep -q "$must_not"; then
    echo -e "  ${RED}FAIL${NC} [$name]: output should not contain '$must_not'"; ok=0
  fi

  if [[ $ok -eq 1 ]]; then
    echo -e "  ${GREEN}PASS${NC} [$name]"
    ((PASS++))
  else
    printf '       %.300s\n' "$out"
    ((FAIL++))
  fi
}

# ── shared fixture setup ──────────────────────────────────────────────────────

# Dummy image: 1 MB zeros — used for SHA256 mock tests
dd if=/dev/zero bs=1M count=1 of="$TMP/dummy.img" 2>/dev/null
DUMMY_SHA=$(sha256sum "$TMP/dummy.img" | awk '{print $1}')
DUMMY_URL="file://$TMP/dummy.img"

# Manifests for mock tests
cat > "$TMP/good-manifest.kv" <<EOF
default.description=Test dummy image (correct SHA256)
default.url=$DUMMY_URL
default.sha256=$DUMMY_SHA
EOF

cat > "$TMP/bad-sha-manifest.kv" <<EOF
default.description=Test dummy image (wrong SHA256 in manifest)
default.url=$DUMMY_URL
default.sha256=0000000000000000000000000000000000000000000000000000000000000000
EOF

cat > "$TMP/dead-url-manifest.kv" <<EOF
default.description=Non-existent file
default.url=file:///nonexistent/path/image.img
default.sha256=$DUMMY_SHA
EOF

# State file with bmc_ip already set (for A1 already-known path)
cp "$FIXTURES/bmc-state.kv" "$TMP/bmc-state.kv"

# Config that points STATE_FILE at our test state (for D02)
cat > "$TMP/bmc-config.kv" <<EOF
STATE_FILE=$TMP/bmc-state.kv
EOF

# Config for D09 (unknown image type, download mode)
cat > "$TMP/type-override.kv" <<EOF
FLASH_MODE=download
IMAGE_1_TYPE=nonexistent_type
EOF

# Config for D22 (explicit BMC_SDCARD_DEV)
cat > "$TMP/bmc-sdcard-override.kv" <<EOF
BMC_SDCARD_DEV=/dev/mmcblk0p1
EOF

# Config for D23 (unknown image type, bmc mode)
cat > "$TMP/bmc-type-override.kv" <<EOF
IMAGE_1_TYPE=nonexistent_type
EOF

# Stub tpi on PATH for mock tests so they don't hang waiting for a real BMC
export PATH_WITH_STUB="$FIXTURES/bin:$PATH"

# ── Suite 1 — Dry-run ────────────────────────────────────────────────────────

if [[ "$SUITE" == "all" || "$SUITE" == "1" ]]; then
  echo ""
  echo "Suite 1 — Dry-run (no hardware)"
  echo "────────────────────────────────"

  run_test "D01 phase-A dry-run (flash=skip)" \
    0 "A3: Flash mode: skip" "" \
    $BOOTSTRAP --dry-run --phase A

  run_test "D02 A1 already-known path" \
    0 "already known" "" \
    $BOOTSTRAP --dry-run --phase A --config "$TMP/bmc-config.kv"

  run_test "D03 A3 local dry-run" \
    0 "tpi flash -n 1 --local" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional --flash local

  run_test "D04 A3 image + per-node override" \
    0 "server.img" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash image --image worker.img --image-1 server.img

  run_test "D05 A3 image no path → die" \
    1 "No image for node" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional --flash image

  run_test "D06 A3 download dry-run cache-miss" \
    0 "would download" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest images-manifest.kv.example

  # D07: cache-hit path — pre-populate cache with a dummy file
  mkdir -p "$TMP/cache-d07"
  cp "$TMP/dummy.img" "$TMP/cache-d07/ubuntu-22.04-preinstalled-server-arm64+rk1.img.xz"
  run_test "D07 A3 download dry-run cache-hit" \
    0 "cache hit" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest images-manifest.kv.example \
      --cache-dir "$TMP/cache-d07"

  run_test "D08 A3 download missing manifest → die" \
    1 "Manifest file not found" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest /nonexistent.kv

  run_test "D09 A3 download unknown type → die" \
    1 "Unknown image type" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest images-manifest.kv.example \
      --config "$TMP/type-override.kv"

  run_test "D10 A3 invalid FLASH_MODE → die" \
    1 "Unknown FLASH_MODE" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional --flash bogus

  run_test "D11 --rediscover dry-run" \
    0 "Rediscover mode" "" \
    $BOOTSTRAP --dry-run --rediscover

  run_test "D12 --config loads values" \
    0 "10.99.0.0/24" "" \
    $BOOTSTRAP --dry-run --phase A --config "$FIXTURES/test-config.kv"

  run_test "D13 --config missing file → die" \
    1 "not found" "" \
    $BOOTSTRAP --config /nonexistent/config.kv

  run_test "D14 --from unknown stage → die" \
    1 "Unknown --from" "" \
    $BOOTSTRAP --dry-run --from BOGUS_STAGE

  run_test "D15 teardown dry-run (state present)" \
    0 "T8" "" \
    $TEARDOWN --dry-run

  run_test "D16 teardown dry-run (no state file)" \
    0 "No state file" "" \
    $TEARDOWN --dry-run --from T1_load_state --to T1_load_state \
      --state-file "$TMP/nonexistent-state.kv"

  run_test "D17 teardown --keep-hostname --remove-docker" \
    0 "keep-hostname" "T5: Reset hostnames" \
    $TEARDOWN --dry-run --keep-hostname --remove-docker

  run_test "D18 A0 skip (default)" \
    0 "Skipping BMC firmware check" "" \
    $BOOTSTRAP --dry-run --from A0_bmc_firmware --to A0_bmc_firmware

  run_test "D19 A0 check dry-run" \
    0 "check version against" "" \
    $BOOTSTRAP --dry-run --from A0_bmc_firmware --to A0_bmc_firmware --bmc-firmware check

  run_test "D20 A0 upgrade dry-run" \
    0 "download + verify SHA256" "" \
    $BOOTSTRAP --dry-run --from A0_bmc_firmware --to A0_bmc_firmware --bmc-firmware upgrade

  run_test "D21 A3 bmc dry-run (auto-detect)" \
    0 "auto-detect" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash bmc --manifest images-manifest.kv.example

  run_test "D22 A3 bmc dry-run (explicit BMC_SDCARD_DEV)" \
    0 "/dev/mmcblk0p1" "auto-detect" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash bmc --manifest images-manifest.kv.example \
      --config "$TMP/bmc-sdcard-override.kv"

  run_test "D23 A3 bmc unknown type → die" \
    1 "Unknown image type" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash bmc --manifest images-manifest.kv.example \
      --config "$TMP/bmc-type-override.kv"

  run_test "D24 A3 bmc missing manifest → die" \
    1 "Manifest file not found" "" \
    $BOOTSTRAP --dry-run --from A3_flash_optional --to A3_flash_optional \
      --flash bmc --manifest /nonexistent.kv
fi

# ── Suite 2 — Mock / fault injection ─────────────────────────────────────────

if [[ "$SUITE" == "all" || "$SUITE" == "2" ]]; then
  echo ""
  echo "Suite 2 — Mock / fault injection (no hardware)"
  echo "────────────────────────────────────────────────"
  echo "  (stub tpi binary injected; download uses file:// URLs)"

  # Inject stub tpi so the script doesn't hang trying to connect to a real BMC
  export PATH="$PATH_WITH_STUB"

  run_test "M01 download correct SHA256 → reaches tpi flash, stub exits 1" \
    any "SHA256 OK" "mismatch" \
    $BOOTSTRAP --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest "$TMP/good-manifest.kv" \
      --cache-dir "$TMP/cache-m01"

  # M02: pre-populate cache so it's a cache-hit run
  mkdir -p "$TMP/cache-m02"
  cp "$TMP/dummy.img" "$TMP/cache-m02/dummy.img"
  run_test "M02 cache hit correct SHA256 → reaches tpi flash" \
    any "Cache hit" "re-downloading" \
    $BOOTSTRAP --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest "$TMP/good-manifest.kv" \
      --cache-dir "$TMP/cache-m02"

  # M03: put a corrupted file in cache (wrong content → SHA256 mismatch)
  mkdir -p "$TMP/cache-m03"
  echo "corrupted" > "$TMP/cache-m03/dummy.img"
  run_test "M03 cache hit wrong SHA256 → re-download + verify" \
    any "re-downloading" "" \
    $BOOTSTRAP --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest "$TMP/good-manifest.kv" \
      --cache-dir "$TMP/cache-m03"

  run_test "M04 dead URL → download fails → die" \
    1 "Download failed" "" \
    $BOOTSTRAP --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest "$TMP/dead-url-manifest.kv" \
      --cache-dir "$TMP/cache-m04"

  run_test "M05 wrong SHA256 in manifest → MitM die" \
    1 "mismatch after download" "" \
    $BOOTSTRAP --from A3_flash_optional --to A3_flash_optional \
      --flash download --manifest "$TMP/bad-sha-manifest.kv" \
      --cache-dir "$TMP/cache-m05"

  run_test "M06 config SUBNET override applied" \
    0 "10.99.0.0/24" "" \
    $BOOTSTRAP --dry-run --phase A --config "$FIXTURES/test-config.kv"

  run_test "M07 state bmc_ip → A1 skip" \
    0 "already known at 192.168.99.1" "" \
    $BOOTSTRAP --dry-run --phase A --config "$TMP/bmc-config.kv"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} of $TOTAL tests"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
