#!/usr/bin/env bash
# Label cluster nodes with hardware capability labels (E-02, ADR-0022/0023).
#
# Detects NPU type via device tree model string — /dev/rknpu does NOT exist
# on this cluster (DRM GEM kernel mode, CONFIG_ROCKCHIP_RKNPU_DRM_GEM=y).
#
# Labels applied:
#   tpi-bro/npu=rk3588           RK1 module (RK3588 NPU)
#   tpi-bro/npu=jetson-orin-nano Jetson Orin Nano module
#   (label removed)              CM4 or any module without an NPU
#
# Run after Phase B bootstrap and after any module swap.
#
# Usage:
#   ./scripts/label-node-capabilities.sh
#   ./scripts/label-node-capabilities.sh --config FILE
#   ./scripts/label-node-capabilities.sh --dry-run

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CONFIG_FILE="./bootstrap-config.kv"
SSH_KEY="${HOME}/.ssh/id_ed25519"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ip_add()  { local p="${1%.*}" l="${1##*.}"; echo "${p}.$((l + $2))"; }

node_ssh() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "ubuntu@${ip}" "$@" 2>/dev/null
}

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config not found: $CONFIG_FILE"; exit 1; }

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE"); SERVER_IDX="${SERVER_IDX:-1}"
NODE_COUNT=$(kv_get NODE_COUNT      "$CONFIG_FILE"); NODE_COUNT="${NODE_COUNT:-4}"

[[ -n "$TPI_BASE" ]] || { echo "ERROR: TPI_BASE_IP_ADDR not set in $CONFIG_FILE"; exit 1; }

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster."
  exit 1
fi

echo ""
echo "Node capability detection (E-02)"
echo "─────────────────────────────────"
[[ $DRY_RUN -eq 1 ]] && echo -e "${YELLOW}DRY RUN — no labels will be applied${NC}"
echo ""

ERRORS=0

for (( i=1; i<=NODE_COUNT; i++ )); do
  node_name="rk1-node${i}"
  node_ip=$(ip_add "$TPI_BASE" "$i")

  echo -e "${CYAN}${node_name}${NC} (${node_ip})"

  # ── probe device tree ──────────────────────────────────────────────────────
  dt_model=$(node_ssh "$node_ip" "cat /proc/device-tree/model 2>/dev/null | tr -d '\\0'" || echo "")

  if [[ -z "$dt_model" ]]; then
    echo -e "  ${RED}ERROR${NC}: SSH to ${node_ip} failed or /proc/device-tree/model absent"
    ((ERRORS++))
    continue
  fi

  echo "  DT model: ${dt_model}"

  # ── determine NPU label ────────────────────────────────────────────────────
  npu_label=""

  if echo "$dt_model" | grep -qi "RK1"; then
    npu_label="rk3588"
  elif echo "$dt_model" | grep -qi "jetson"; then
    # Jetson: confirm via CUDA device node presence
    if node_ssh "$node_ip" "test -e /dev/nvhost-ctrl" 2>/dev/null; then
      npu_label="jetson-orin-nano"
    else
      echo "  ${YELLOW}WARN${NC}: Jetson DT string found but /dev/nvhost-ctrl absent — skipping NPU label"
    fi
  fi

  # ── apply or remove label ──────────────────────────────────────────────────
  if [[ -n "$npu_label" ]]; then
    echo -e "  NPU detected: ${GREEN}${npu_label}${NC}"
    if [[ $DRY_RUN -eq 0 ]]; then
      kubectl label node "$node_name" "tpi-bro/npu=${npu_label}" --overwrite
      echo "  Applied: tpi-bro/npu=${npu_label}"
    else
      echo "  Would apply: tpi-bro/npu=${npu_label}"
    fi
  else
    echo "  No NPU — removing tpi-bro/npu label if present"
    if [[ $DRY_RUN -eq 0 ]]; then
      kubectl label node "$node_name" tpi-bro/npu- 2>/dev/null || true
    else
      echo "  Would run: kubectl label node ${node_name} tpi-bro/npu-"
    fi
  fi

  echo ""
done

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}${ERRORS} node(s) could not be probed.${NC}"
  exit 1
fi

echo "Done. Verify with: kubectl get nodes -L tpi-bro/npu"
