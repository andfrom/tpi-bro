#!/usr/bin/env bash
# Self-healing layers 2+4 (docs/SELF-HEALING.md): install the BMC-resident node watchdog.
#
# Pushes scripts/bmc/bmc-watchdog.sh + its init script onto the BMC's
# persistent overlay (/etc), writes /etc/bmc-watchdog.conf, and starts it.
# The daemon power-cycles a node only after FAIL_THRESHOLD consecutive
# failed SSH-banner probes, with power-state check, boot grace, per-node
# cooldown, and a per-24h cycle cap (details in the daemon header).
#
# The BMC overlay may be reset by firmware updates — re-run this after any
# BMC update (same caveat as setStaticNet.sh from setup-static-ips.sh).
#
# Usage:
#   ./install-bmc-watchdog.sh                 # install/refresh + start
#   ./install-bmc-watchdog.sh --test-mode     # short thresholds (~1 min trip)
#   ./install-bmc-watchdog.sh --verify        # daemon status + recent log
#   ./install-bmc-watchdog.sh --uninstall
#
# BMC address/password: BMC_HOST / BMC_PASS env vars (defaults below).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BMC_HOST="${BMC_HOST:-192.168.1.10}"
BMC_PASS="${BMC_PASS:-turing}"
MODE=install
TEST_MODE=0

say()  { echo "==> $*"; }
info() { echo "    $*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --test-mode) TEST_MODE=1;      shift ;;
    --verify)    MODE=verify;      shift ;;
    --uninstall) MODE=uninstall;   shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

bmc() {
  sshpass -p "$BMC_PASS" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "root@$BMC_HOST" "$@" 2>/dev/null
}

bmc_push() { # src dst
  sshpass -p "$BMC_PASS" scp \
    -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "$1" "root@$BMC_HOST:$2" 2>/dev/null
}

command -v sshpass >/dev/null || { echo "sshpass required"; exit 1; }

case $MODE in
  verify)
    say "bmc-watchdog status on $BMC_HOST"
    bmc "/etc/init.d/S94bmcwatchdog status; echo '--- config:'; cat /etc/bmc-watchdog.conf 2>/dev/null; echo '--- recent log:'; tail -n 12 /mnt/sdcard/bmc-watchdog.log 2>/dev/null"
    ;;
  uninstall)
    say "Removing bmc-watchdog from $BMC_HOST"
    bmc "/etc/init.d/S94bmcwatchdog stop 2>/dev/null; rm -f /etc/init.d/S94bmcwatchdog /etc/bmc-watchdog.sh /etc/bmc-watchdog.conf; echo removed"
    ;;
  install)
    say "Installing bmc-watchdog on $BMC_HOST (test-mode=$TEST_MODE)"
    bmc_push "$SCRIPT_DIR/bmc/bmc-watchdog.sh" /etc/bmc-watchdog.sh
    bmc_push "$SCRIPT_DIR/bmc/S94bmcwatchdog"  /etc/init.d/S94bmcwatchdog

    if [[ $TEST_MODE -eq 1 ]]; then
      CONF='INTERVAL=10
FAIL_THRESHOLD=6
BOOT_GRACE=180
DEEP_THRESHOLD=6
DEEP_GRACE=240
COOLDOWN=300
MAX_CYCLES_PER_DAY=10'
      info "TEST thresholds: 6 fails x 10s = ~60s trip"
    else
      CONF='INTERVAL=30
FAIL_THRESHOLD=10
BOOT_GRACE=300
DEEP_THRESHOLD=10
DEEP_GRACE=600
COOLDOWN=1800
MAX_CYCLES_PER_DAY=3'
      info "PRODUCTION thresholds: 10 fails x 30s = 5 min trip (ssh + deep)"
    fi

    bmc "chmod +x /etc/bmc-watchdog.sh /etc/init.d/S94bmcwatchdog
cat > /etc/bmc-watchdog.conf <<'EOF'
$CONF
EOF
/etc/init.d/S94bmcwatchdog restart
sleep 1
/etc/init.d/S94bmcwatchdog status"
    say "Done. Log: /mnt/sdcard/bmc-watchdog.log on the BMC ($0 --verify)"
    ;;
esac
