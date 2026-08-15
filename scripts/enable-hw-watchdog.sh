#!/usr/bin/env bash
# Self-healing layer 1 (docs/SELF-HEALING.md): arm the RK1 on-SoC hardware watchdog.
#
# The RK3588 has a Synopsys DW watchdog (watchdog@feaf0000, dw_wdt driver
# compiled into the Ubuntu rockchip kernel) but the device-tree node ships
# `status = "disabled"`. This script:
#   1. Installs a DT overlay (/boot/overlays/enable-wdt.dtbo) flipping it to
#      "okay", wired through u-boot-update's native overlay support
#      (U_BOOT_FDT_OVERLAYS_DIR in /etc/default/u-boot). The overlay dir is
#      not kernel-versioned, so it survives kernel updates.
#   2. Points systemd at it: RuntimeWatchdogSec=60 — PID1 pets the watchdog;
#      if userspace starves (the 2026-08-15 rknn_init wedge signature), the
#      SoC hard-resets itself with no BMC involvement. RebootWatchdogSec=10min
#      covers hung reboots.
#   3. Sets kernel.panic=10 + kernel.panic_on_oops=1 so kernel crashes
#      reboot instead of sitting at a dead console.
#
# A reboot is required for the overlay to take effect; this script does NOT
# reboot nodes (do that one node at a time, control plane last). Idempotent.
#
# Usage:
#   ./enable-hw-watchdog.sh                  # configure all nodes
#   ./enable-hw-watchdog.sh rk1-node3        # configure one node
#   ./enable-hw-watchdog.sh --verify         # check armed state on all nodes
#   ./enable-hw-watchdog.sh --rolling-reboot # reboot workers then control
#                                            # plane, waiting for k8s Ready
#                                            # between each; then --verify

set -euo pipefail

NODES=(rk1-node1 rk1-node2 rk1-node3 rk1-node4)
# Reboot order: workers first, control plane (node1) last.
REBOOT_ORDER=(rk1-node2 rk1-node3 rk1-node4 rk1-node1)
DO_VERIFY=0
DO_ROLLING=0

say()  { echo "==> $*"; }
info() { echo "    $*"; }

if [[ $# -gt 0 ]]; then
  case $1 in
    --verify) DO_VERIFY=1 ;;
    --rolling-reboot) DO_ROLLING=1 ;;
    rk1-node*) NODES=("$@") ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
fi

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"

verify_node() {
  local node=$1
  $SSH "ubuntu@${node}" '
    status=$(cat /proc/device-tree/watchdog@feaf0000/status 2>/dev/null | tr -d "\0")
    dev=$([ -e /dev/watchdog0 ] && echo yes || echo no)
    armed=$(sudo journalctl -b -o cat 2>/dev/null | grep -m1 -i "hardware watchdog" || true)
    runtime=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)
    panic=$(sysctl -n kernel.panic 2>/dev/null)
    echo "dt=${status:-absent} dev=${dev} runtime=${runtime} panic=${panic}s"
    [ -n "$armed" ] && echo "systemd: ${armed}"
    [ "$dev" = yes ] && [ "$runtime" != "0" ] && [ "$runtime" != "off" ]
  ' </dev/null
}

if [[ $DO_VERIFY -eq 1 ]]; then
  rc=0
  for node in "${NODES[@]}"; do
    say "$node"
    verify_node "$node" || { info "NOT ARMED"; rc=1; }
  done
  exit $rc
fi

if [[ $DO_ROLLING -eq 1 ]]; then
  # A node that hits the warm-reboot PCIe flake (HARDWARE-FIRMWARE-ISSUES.md)
  # never comes back on its own — that's what the 12-minute per-node timeout
  # is for. If it trips: cold-cycle via BMC (or let the BMC watchdog do it)
  # and re-run this mode.
  for node in "${REBOOT_ORDER[@]}"; do
    say "Rebooting ${node}"
    $SSH "ubuntu@${node}" "sudo reboot" </dev/null 2>/dev/null || true
    sleep 15
    deadline=$(( $(date +%s) + 720 ))
    until $SSH "ubuntu@${node}" true </dev/null 2>/dev/null; do
      [[ $(date +%s) -gt $deadline ]] && { echo "ERROR: ${node} not back after 12 min (PCIe flake? cold-cycle it and re-run)"; exit 1; }
      sleep 10
    done
    until kubectl get node "$node" 2>/dev/null | grep -qw Ready; do
      [[ $(date +%s) -gt $deadline ]] && { echo "ERROR: ${node} up but not k8s Ready after 12 min"; exit 1; }
      sleep 5
    done
    info "${node} Ready"
  done
  exec "$0" --verify
fi

for node in "${NODES[@]}"; do
  say "Configuring hardware watchdog on ${node}"
  $SSH "ubuntu@${node}" 'set -euo pipefail
    # 1. DT overlay
    sudo mkdir -p /boot/overlays
    cat <<EOF | sudo tee /tmp/enable-wdt.dts >/dev/null
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "/watchdog@feaf0000";
        __overlay__ {
            status = "okay";
        };
    };
};
EOF
    sudo dtc -q -I dts -O dtb -o /boot/overlays/enable-wdt.dtbo /tmp/enable-wdt.dts
    sudo rm -f /tmp/enable-wdt.dts

    # 2. Wire the overlay dir into u-boot-update and regenerate extlinux.conf.
    #    Must be the rootfs-absolute path: this u-boot-update build never sets
    #    _BOOT_PATH, so the configured dir is used verbatim both for the
    #    filesystem check and in extlinux.conf (whose paths are rootfs-absolute).
    sudo sed -i "/^U_BOOT_FDT_OVERLAYS_DIR=/d" /etc/default/u-boot
    echo "U_BOOT_FDT_OVERLAYS_DIR=\"/boot/overlays\"" | sudo tee -a /etc/default/u-boot >/dev/null
    sudo u-boot-update >/dev/null
    grep -q "fdtoverlays .*enable-wdt.dtbo" /boot/extlinux/extlinux.conf \
      || { echo "ERROR: fdtoverlays line missing from extlinux.conf"; exit 1; }

    # 3. systemd watchdog petting
    sudo mkdir -p /etc/systemd/system.conf.d
    printf "[Manager]\nRuntimeWatchdogSec=60\nRebootWatchdogSec=10min\n" \
      | sudo tee /etc/systemd/system.conf.d/10-hw-watchdog.conf >/dev/null

    # 4. panic behavior
    printf "kernel.panic = 10\nkernel.panic_on_oops = 1\n" \
      | sudo tee /etc/sysctl.d/90-panic-reboot.conf >/dev/null
    sudo sysctl -q --system >/dev/null

    echo "configured (reboot required for the DT overlay)"
  ' </dev/null
done

say "Done. Reboot nodes one at a time (control plane last), then: $0 --verify"
