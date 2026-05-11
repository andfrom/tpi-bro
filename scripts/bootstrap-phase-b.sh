#!/usr/bin/env bash
# Phase B orchestrator — runs B0 through B2 in order.
#
# Usage:
#   ./bootstrap-phase-b.sh                     # full B0→B2
#   ./bootstrap-phase-b.sh --from B1_k3s       # resume from a specific stage
#   ./bootstrap-phase-b.sh --to   B2_registry  # stop after a specific stage
#   ./bootstrap-phase-b.sh --dry-run            # print what would happen, no changes
#   ./bootstrap-phase-b.sh --check              # run tests/check-cluster.sh after B2_verify
#   ./bootstrap-phase-b.sh [--config FILE] [--state FILE]
#
# Stages (in order):
#   B0_static_ips  — configure static IPs on all nodes and BMC
#   B0_ssh_keys    — distribute SSH key + passwordless sudo
#   B1_k3s         — install k3s server + agents + kubeconfig
#   B2_registry    — deploy private registry via Helm
#   B2_auth        — enable basic auth on registry
#   B2_verify      — smoke-test registry push/pull from laptop
#   B09_mount_ssd  — format + mount NVMe SSDs; deploy local-ssd StorageClass
#   B09_migrate_pvc — move registry PVC from eMMC to SSD (data loss; re-push images after)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

STATE_FILE="${SCRIPT_DIR}/../bootstrap-state.kv"
CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
DRY=0
DO_CHECK=0
FROM_STAGE=""
TO_STAGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --state)    STATE_FILE="$2";  shift 2 ;;
    --from)     FROM_STAGE="$2";  shift 2 ;;
    --to)       TO_STAGE="$2";    shift 2 ;;
    --dry-run)  DRY=1;            shift   ;;
    --check)    DO_CHECK=1;       shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- stage registry ---------------------------------------------------------

STAGES=(
  B0_static_ips
  B0_ssh_keys
  B1_k3s
  B2_registry
  B2_auth
  B2_verify
  B09_mount_ssd
  B09_migrate_pvc
)

say()  { echo "==> $*"; }
info() { echo "    $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

# Validate --from / --to
if [[ -n "$FROM_STAGE" ]]; then
  found=0
  for s in "${STAGES[@]}"; do [[ "$s" == "$FROM_STAGE" ]] && found=1 && break; done
  (( found )) || err "Unknown stage for --from: ${FROM_STAGE}. Valid: ${STAGES[*]}"
fi
if [[ -n "$TO_STAGE" ]]; then
  found=0
  for s in "${STAGES[@]}"; do [[ "$s" == "$TO_STAGE" ]] && found=1 && break; done
  (( found )) || err "Unknown stage for --to: ${TO_STAGE}. Valid: ${STAGES[*]}"
fi

# ---- helpers ----------------------------------------------------------------

DRY_FLAG=()
(( DRY )) && DRY_FLAG=(--dry-run)

run_stage() {
  local name="$1"; shift
  say "──────────────────────────────────────"
  say "STAGE: ${name}"
  say "──────────────────────────────────────"
  if ! "$@"; then
    echo
    echo "ERROR: stage ${name} failed."
    echo "Fix the issue then re-run with:  ./bootstrap-phase-b.sh --from ${name}"
    exit 1
  fi
  say "STAGE ${name}: OK"
  echo
}

# ---- stage functions ---------------------------------------------------------

do_B0_static_ips() {
  run_stage B0_static_ips \
    bash "${SCRIPT_DIR}/setup-static-ips.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      "${DRY_FLAG[@]}"
}

do_B0_ssh_keys() {
  run_stage B0_ssh_keys \
    bash "${SCRIPT_DIR}/setup-ssh-keys.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      "${DRY_FLAG[@]}"
}

do_B1_k3s() {
  run_stage B1_k3s \
    bash "${SCRIPT_DIR}/install-k3s.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      "${DRY_FLAG[@]}"
}

do_B2_registry() {
  run_stage B2_registry \
    bash "${SCRIPT_DIR}/setup-registry.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      "${DRY_FLAG[@]}"
}

do_B2_auth() {
  run_stage B2_auth \
    bash "${SCRIPT_DIR}/setup-registry.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      --enable-auth \
      "${DRY_FLAG[@]}"
}

do_B2_verify() {
  run_stage B2_verify \
    bash "${SCRIPT_DIR}/setup-registry.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      --verify \
      "${DRY_FLAG[@]}"
}

do_B09_mount_ssd() {
  run_stage B09_mount_ssd \
    bash "${SCRIPT_DIR}/mount-ssd.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      "${DRY_FLAG[@]}"
}

do_B09_migrate_pvc() {
  run_stage B09_migrate_pvc \
    bash "${SCRIPT_DIR}/setup-registry.sh" \
      --config "$CONFIG_FILE" \
      --state  "$STATE_FILE" \
      --migrate-pvc \
      "${DRY_FLAG[@]}"
}

# ---- main loop --------------------------------------------------------------

ACTIVE=0
[[ -z "$FROM_STAGE" ]] && ACTIVE=1
PAST_TO=0

for stage in "${STAGES[@]}"; do
  # Activate at --from
  [[ -n "$FROM_STAGE" && "$stage" == "$FROM_STAGE" ]] && ACTIVE=1

  if (( PAST_TO )); then
    info "Skipping ${stage} (after --to ${TO_STAGE})"
  elif (( ACTIVE )); then
    "do_${stage}"
  else
    info "Skipping ${stage} (before --from ${FROM_STAGE})"
  fi

  # Deactivate after --to
  if [[ -n "$TO_STAGE" && "$stage" == "$TO_STAGE" ]]; then
    ACTIVE=0
    PAST_TO=1
  fi
done

# ---- optional cluster health check ------------------------------------------

if (( DO_CHECK )); then
  say "Running cluster health check (tests/check-cluster.sh)…"
  CHECK_SCRIPT="${SCRIPT_DIR}/../tests/check-cluster.sh"
  [[ -x "$CHECK_SCRIPT" ]] || chmod +x "$CHECK_SCRIPT"
  if (( DRY )); then
    info "[dry-run] Would run: tests/check-cluster.sh --config ${CONFIG_FILE}"
  else
    bash "$CHECK_SCRIPT" --config "$CONFIG_FILE"
  fi
fi

say "Phase B complete."
