#!/usr/bin/env bash
# Suite 3 — Hardware verification runner (Phase A bootstrap/teardown cycles).
# Requires a live TuringPi 2 with 4× RK1 nodes and a reachable BMC.
#
# For Phase B cluster health checks (k3s, registry, pod pull) use Suite 4:
#   ./tests/check-cluster.sh          # full health check
#   ./tests/check-cluster.sh --quick  # skip per-node pod pull
#
# Usage:
#   ./tests/run-hardware.sh [OPTIONS]
#
# Options:
#   --cycles N           Number of bootstrap→teardown cycles (default: 2)
#   --password PASS      Node password set during bootstrap (prompted if omitted)
#   --flash-cycle        Run one extra cycle using --flash download (first cycle only)
#   --bmc-check          Include A0 BMC firmware version check in each cycle
#   --bmc-upgrade        Include A0 BMC firmware upgrade if outdated
#   --skip-rediscover    Skip the rediscover test scenario
#   --dry-run            Print what would be done without touching hardware

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BOOTSTRAP="./scripts/bootstrap-turingpi-cluster.exp"
TEARDOWN="./scripts/teardown-cluster.exp"

CYCLES=2
NODE_PASS=""
FLASH_CYCLE=0
BMC_MODE="skip"
SKIP_REDISCOVER=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles)        CYCLES="$2";    shift 2 ;;
    --password)      NODE_PASS="$2"; shift 2 ;;
    --flash-cycle)   FLASH_CYCLE=1;  shift ;;
    --bmc-check)     BMC_MODE="check"; shift ;;
    --bmc-upgrade)   BMC_MODE="upgrade"; shift ;;
    --skip-rediscover) SKIP_REDISCOVER=1; shift ;;
    --dry-run)       DRY=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

PASS=0; FAIL=0; SKIP=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

DR_FLAG=""
[[ $DRY -eq 1 ]] && DR_FLAG="--dry-run"

PASS_FLAG=""
[[ -n "$NODE_PASS" ]] && PASS_FLAG="--password $NODE_PASS"

log()  { echo -e "\n${YELLOW}===${NC} $*"; }
ok()   { echo -e "  ${GREEN}PASS${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC} $*"; ((FAIL++)); }

# ── prerequisite checks ───────────────────────────────────────────────────────

log "Prerequisite checks"

if command -v tpi &>/dev/null; then
  ok "tpi CLI found: $(tpi --version 2>/dev/null | head -1)"
else
  fail "tpi CLI not found"; exit 1
fi

BMC_HOST_CFG=$(grep -s '^BMC_HOST=' bootstrap-config.kv ~/.turingpi/bootstrap-config.kv 2>/dev/null | head -1 | cut -d= -f2)
if ping -c 1 -W 2 turingpi.local &>/dev/null 2>&1 || \
   grep -q turingpi.local /etc/hosts; then
  ok "BMC reachable (turingpi.local)"
elif [[ -n "$BMC_HOST_CFG" ]] && ping -c 1 -W 2 "$BMC_HOST_CFG" &>/dev/null 2>&1; then
  ok "BMC reachable ($BMC_HOST_CFG from config)"
else
  fail "BMC not reachable (tried turingpi.local and BMC_HOST_CFG=${BMC_HOST_CFG:-unset})"
  exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────

verify_cluster_up() {
  local cycle="$1"
  log "Cycle $cycle: verifying cluster state"
  local ok_count=0
  for n in 1 2 3 4; do
    local host="rk1-node$n"
    # Nodes use password auth so BatchMode=yes can't verify hostname. Instead:
    # confirm /etc/hosts has the entry (A6 worked) and port 22 is open (node is up).
    if grep -q "$host" /etc/hosts 2>/dev/null && \
       timeout 5 bash -c "echo >/dev/tcp/$host/22" 2>/dev/null; then
      ok "$host: /etc/hosts entry present and SSH port open"
      ((ok_count++))
    else
      fail "$host: /etc/hosts entry missing or SSH port not reachable"
    fi
  done

  # Phase A registry is HTTP and unauthenticated (Docker container, --restart=always).
  # Phase B replaces this; run ./tests/check-cluster.sh for Phase B registry checks.
  if curl -sf --connect-timeout 5 http://rk1-node1:5000/v2/_catalog 2>/dev/null | grep -q repositories; then
    ok "Phase A registry HTTP up on rk1-node1:5000"
  else
    fail "Phase A registry not reachable on rk1-node1:5000"
  fi
}

verify_cluster_down() {
  local cycle="$1"
  log "Cycle $cycle: verifying clean teardown"

  if [[ -f bootstrap-state.kv ]]; then
    fail "bootstrap-state.kv still present after teardown"
  else
    ok "bootstrap-state.kv removed (renamed to .bak.*)"
  fi

  for name in rk1-node1 rk1-node2 rk1-node3 rk1-node4 turingpi.local; do
    if grep -q "$name" /etc/hosts 2>/dev/null; then
      fail "/etc/hosts still contains '$name'"
    else
      ok "/etc/hosts clean: no $name"
    fi
  done

  if tpi power status 2>/dev/null | grep -qiE "on|1"; then
    fail "Some nodes still powered on after teardown"
  else
    ok "tpi power status: all nodes off"
  fi
}

# ── optional: BMC firmware check ──────────────────────────────────────────────

if [[ "$BMC_MODE" != "skip" ]]; then
  log "BMC firmware check (mode=$BMC_MODE)"
  if $BOOTSTRAP $DR_FLAG \
      --from A0_bmc_firmware --to A0_bmc_firmware \
      --bmc-firmware "$BMC_MODE" --bmc-manifest bmc-manifest.kv; then
    ok "A0 BMC firmware $BMC_MODE: passed"
  else
    fail "A0 BMC firmware $BMC_MODE: failed"
  fi
fi

# ── optional: flash cycle (cycle 0) ──────────────────────────────────────────

if [[ $FLASH_CYCLE -eq 1 ]]; then
  log "Flash cycle (--flash download)"
  if [[ ! -f images-manifest.kv ]]; then
    echo -e "  ${YELLOW}SKIP${NC} [flash cycle]: images-manifest.kv not found; copy from images-manifest.kv.example"
    ((SKIP++))
  else
    if $BOOTSTRAP $DR_FLAG --phase A --flash download; then
      ok "Flash cycle bootstrap: passed"
      verify_cluster_up "flash"
      if $TEARDOWN $DR_FLAG $PASS_FLAG; then
        ok "Flash cycle teardown: passed"
        verify_cluster_down "flash"
      else
        fail "Flash cycle teardown: failed"
      fi
    else
      fail "Flash cycle bootstrap: failed"
    fi
  fi
fi

# ── standard cycles ───────────────────────────────────────────────────────────

for ((cycle=1; cycle<=CYCLES; cycle++)); do
  log "Standard cycle $cycle / $CYCLES"

  if $BOOTSTRAP $DR_FLAG --phase A; then
    ok "Cycle $cycle bootstrap: passed"
  else
    fail "Cycle $cycle bootstrap: failed (stopping cycle)"
    continue
  fi

  [[ $DRY -eq 0 ]] && verify_cluster_up "$cycle"

  if $TEARDOWN $DR_FLAG $PASS_FLAG; then
    ok "Cycle $cycle teardown: passed"
  else
    fail "Cycle $cycle teardown: failed"
  fi

  [[ $DRY -eq 0 ]] && verify_cluster_down "$cycle"
done

# ── rediscover scenario ───────────────────────────────────────────────────────

if [[ $SKIP_REDISCOVER -eq 0 ]]; then
  log "Rediscover scenario"
  echo "  NOTE: This test requires a DHCP reassignment or manual IP change."
  echo "        Bootstrap one cycle first, then trigger IP drift, then run:"
  echo "        $BOOTSTRAP --rediscover"
  echo "        Skipping automated run — perform manually and verify /etc/hosts updated."
  echo -e "  ${YELLOW}MANUAL${NC} [rediscover]"
  ((SKIP++))
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP manual/skipped${NC} of $TOTAL automated checks"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
