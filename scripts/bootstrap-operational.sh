#!/usr/bin/env bash
# Bring-up orchestrator — one command from a Phase-A-flashed cluster to fully
# operational, ending with the cluster health check green.
#
# Chains the existing phase scripts with verification gates and preflight
# checks (ADR-0028's "layer 1"). Every underlying script is idempotent, so
# re-running the whole chain against an already-built cluster is safe; a
# failed stage prints the exact --from to resume with.
#
# Usage:
#   ./bootstrap-operational.sh                    # full chain
#   ./bootstrap-operational.sh --from D00_resource_policy
#   ./bootstrap-operational.sh --to   N01_ts_operator
#   ./bootstrap-operational.sh --dry-run          # print plan, change nothing
#   ./bootstrap-operational.sh --yes              # no interactive pauses
#   ./bootstrap-operational.sh [--config FILE] [--state FILE]
#
# Stages (in order):
#   PHASEB_full         — bootstrap-phase-b.sh: static IPs, SSH keys, k3s,
#                         registry (+TLS+auth), NVMe + local-ssd StorageClass.
#                         Fresh-bring-up stage: needs the LAN + Phase-A
#                         password auth; skip with --from on a built cluster.
#   D00_resource_policy — PriorityClasses + LimitRanges
#   E02_npu_labels      — tpi-bro/npu capability labels (NVMe labels are
#                         applied by mount-ssd.sh inside PHASEB_full)
#   N01_tailscale       — Tailscale on all nodes + k3s TLS SAN
#   N01_subnet_router   — advertise pod/service CIDRs (MANUAL GATE: approve
#                         the routes in the Tailscale admin console)
#   N01_ts_operator     — Tailscale k8s operator (service exposure)
#   B04_gitops          — Flux + deploy-key secret + gitops/ sync
#   D01_ollama          — Ollama per NVMe node (+ model pull if OLLAMA_MODEL
#                         is set in the config file)
#   D04_monitoring      — kube-prometheus-stack; Grafana exposed on Tailnet
#   E01_jobqueue        — KEDA + Redis job queue + echo demo (the ADR-0028
#                         boundary; REDIS_PASSWORD auto-generated on first run)
#   C04_bmc_watchdog    — self-healing outer loop: BMC-resident node watchdog
#                         (installed BEFORE the hw-watchdog reboots so it
#                         already guards against the warm-reboot PCIe flake)
#   C04_hw_watchdog     — self-healing first line: arm the on-SoC hardware
#                         watchdog (DT overlay + systemd), then a rolling
#                         reboot (workers first, control plane last)
#   VERIFY_cluster      — tests/check-cluster.sh; green here == operational
#
# Credentials consumed (from ~/.turingpi/credentials.kv):
#   TAILSCALE_AUTH_KEY                        (N01_tailscale)
#   TAILSCALE_OAUTH_CLIENT_ID / _SECRET       (N01_ts_operator)
#   GRAFANA_ADMIN_PASSWORD                    (D04_monitoring)
#   GITOPS_DEPLOY_KEY (optional; see install-gitops.sh for the fallback)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

STATE_FILE="${SCRIPT_DIR}/../bootstrap-state.kv"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
if   [[ -f "${SCRIPT_DIR}/../bootstrap-config.kv" ]]; then
  CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
elif [[ -f "${HOME}/.turingpi/bootstrap-config.kv" ]]; then
  CONFIG_FILE="${HOME}/.turingpi/bootstrap-config.kv"
else
  CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
fi
DRY=0
YES=0
FROM_STAGE=""
TO_STAGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --state)    STATE_FILE="$2";  shift 2 ;;
    --from)     FROM_STAGE="$2";  shift 2 ;;
    --to)       TO_STAGE="$2";    shift 2 ;;
    --dry-run)  DRY=1;            shift   ;;
    --yes)      YES=1;            shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

STAGES=(
  PHASEB_full
  D00_resource_policy
  E02_npu_labels
  N01_tailscale
  N01_subnet_router
  N01_ts_operator
  B04_gitops
  D01_ollama
  D04_monitoring
  E01_jobqueue
  C04_bmc_watchdog
  C04_hw_watchdog
  VERIFY_cluster
)

say()  { echo "==> $*"; }
info() { echo "    $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }
kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }

for v in FROM_STAGE TO_STAGE; do
  val="${!v}"
  if [[ -n "$val" ]]; then
    found=0
    for s in "${STAGES[@]}"; do [[ "$s" == "$val" ]] && found=1 && break; done
    (( found )) || err "Unknown stage for --${v/_STAGE/}: ${val}. Valid: ${STAGES[*]}"
  fi
done

# ── which stages will actually run? ──────────────────────────────────────────

stage_selected() {
  # true if $1 falls within the --from/--to window
  local target="$1" active=0
  [[ -z "$FROM_STAGE" ]] && active=1
  for s in "${STAGES[@]}"; do
    [[ -n "$FROM_STAGE" && "$s" == "$FROM_STAGE" ]] && active=1
    [[ "$s" == "$target" ]] && { (( active )); return; }
    [[ -n "$TO_STAGE" && "$s" == "$TO_STAGE" ]] && active=0
  done
  return 1
}

# ── preflight: fail fast with the FULL list of problems ──────────────────────

preflight() {
  local missing=()

  [[ -f "$CONFIG_FILE" ]] || missing+=("config file not found: ${CONFIG_FILE}")

  local t
  for t in kubectl helm ssh; do
    command -v "$t" >/dev/null 2>&1 || missing+=("tool not found: ${t}")
  done
  if stage_selected PHASEB_full; then
    for t in sshpass docker; do
      command -v "$t" >/dev/null 2>&1 || missing+=("tool not found: ${t} (needed by PHASEB_full)")
    done
  fi
  if stage_selected B04_gitops; then
    command -v flux >/dev/null 2>&1 || missing+=("tool not found: flux (needed by B04_gitops)")
  fi

  if stage_selected N01_tailscale || stage_selected N01_ts_operator || stage_selected D04_monitoring; then
    [[ -f "$CREDS_FILE" ]] || missing+=("credentials file not found: ${CREDS_FILE}")
  fi
  if [[ -f "$CREDS_FILE" ]]; then
    stage_selected N01_tailscale && [[ -z "$(kv_get TAILSCALE_AUTH_KEY "$CREDS_FILE")" ]] \
      && missing+=("TAILSCALE_AUTH_KEY missing in ${CREDS_FILE} (N01_tailscale)")
    if stage_selected N01_ts_operator; then
      [[ -z "$(kv_get TAILSCALE_OAUTH_CLIENT_ID "$CREDS_FILE")" ]] \
        && missing+=("TAILSCALE_OAUTH_CLIENT_ID missing in ${CREDS_FILE} (N01_ts_operator)")
      [[ -z "$(kv_get TAILSCALE_OAUTH_CLIENT_SECRET "$CREDS_FILE")" ]] \
        && missing+=("TAILSCALE_OAUTH_CLIENT_SECRET missing in ${CREDS_FILE} (N01_ts_operator)")
    fi
    stage_selected D04_monitoring && [[ -z "$(kv_get GRAFANA_ADMIN_PASSWORD "$CREDS_FILE")" ]] \
      && missing+=("GRAFANA_ADMIN_PASSWORD missing in ${CREDS_FILE} (D04_monitoring)")
  fi

  if (( ${#missing[@]} )); then
    echo "Preflight failed — fix ALL of the following, then re-run:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  say "Preflight OK."
}

# ── stage plumbing ────────────────────────────────────────────────────────────

DRY_FLAG=()
YES_FLAG=()
(( DRY )) && DRY_FLAG=(--dry-run)
(( YES )) && YES_FLAG=(--yes)

run_stage() {
  local name="$1"; shift
  say "──────────────────────────────────────"
  say "STAGE: ${name}"
  say "──────────────────────────────────────"
  if ! "$@"; then
    echo
    echo "ERROR: stage ${name} failed."
    echo "Fix the issue then resume with:  ./bootstrap-operational.sh --from ${name}"
    exit 1
  fi
  say "STAGE ${name}: OK"
  echo
}

do_PHASEB_full() {
  run_stage PHASEB_full \
    bash "${SCRIPT_DIR}/bootstrap-phase-b.sh" \
      --config "$CONFIG_FILE" --state "$STATE_FILE" \
      "${DRY_FLAG[@]}" "${YES_FLAG[@]}"
}

do_D00_resource_policy() {
  run_stage D00_resource_policy \
    bash "${SCRIPT_DIR}/apply-resource-policy.sh" "${DRY_FLAG[@]}"
}

do_E02_npu_labels() {
  run_stage E02_npu_labels \
    bash "${SCRIPT_DIR}/label-node-capabilities.sh" \
      --config "$CONFIG_FILE" "${DRY_FLAG[@]}"
}

do_N01_tailscale() {
  run_stage N01_tailscale \
    bash "${SCRIPT_DIR}/install-tailscale.sh" \
      --config "$CONFIG_FILE" "${DRY_FLAG[@]}"
}

do_N01_subnet_router() {
  run_stage N01_subnet_router \
    bash "${SCRIPT_DIR}/setup-subnet-router.sh" \
      --config "$CONFIG_FILE" "${DRY_FLAG[@]}"
  if (( ! DRY && ! YES )); then
    echo
    echo "MANUAL GATE: approve the advertised routes in the Tailscale admin"
    echo "console now (see the instructions above), then press Enter."
    echo "(Ctrl-C to stop; resume later with --from N01_ts_operator)"
    read -r
  elif (( ! DRY )); then
    info "--yes: not pausing for route approval — remember to approve them."
  fi
}

do_N01_ts_operator() {
  run_stage N01_ts_operator \
    bash "${SCRIPT_DIR}/setup-tailscale-operator.sh" "${DRY_FLAG[@]}"
}

do_B04_gitops() {
  run_stage B04_gitops \
    bash "${SCRIPT_DIR}/install-gitops.sh" "${DRY_FLAG[@]}"
}

do_D01_ollama() {
  local model_flag=()
  local model
  model=$(kv_get OLLAMA_MODEL "$CONFIG_FILE")
  [[ -n "$model" ]] && model_flag=(--model "$model")
  run_stage D01_ollama \
    bash "${SCRIPT_DIR}/install-ollama.sh" "${model_flag[@]}" "${DRY_FLAG[@]}"
}

do_D04_monitoring() {
  # NOTE: install-monitoring.sh's --config points at the CREDENTIALS file,
  # not the bootstrap config — its default is already ~/.turingpi/credentials.kv.
  run_stage D04_monitoring \
    bash "${SCRIPT_DIR}/install-monitoring.sh" "${DRY_FLAG[@]}"
}

do_E01_jobqueue() {
  # Generates REDIS_PASSWORD into credentials.kv on first run — nothing to
  # preflight for this stage.
  run_stage E01_jobqueue \
    bash "${SCRIPT_DIR}/install-jobqueue.sh" "${DRY_FLAG[@]}"
}

do_C04_bmc_watchdog() {
  if (( DRY )); then
    say "STAGE: C04_bmc_watchdog"
    info "[dry-run] Would run: install-bmc-watchdog.sh (BMC-resident prober)"
    return 0
  fi
  run_stage C04_bmc_watchdog \
    bash "${SCRIPT_DIR}/install-bmc-watchdog.sh"
}

do_C04_hw_watchdog() {
  if (( DRY )); then
    say "STAGE: C04_hw_watchdog"
    info "[dry-run] Would run: enable-hw-watchdog.sh, then --rolling-reboot"
    return 0
  fi
  run_stage C04_hw_watchdog \
    bash -c "'${SCRIPT_DIR}/enable-hw-watchdog.sh' && '${SCRIPT_DIR}/enable-hw-watchdog.sh' --rolling-reboot"
}

do_VERIFY_cluster() {
  if (( DRY )); then
    say "STAGE: VERIFY_cluster"
    info "[dry-run] Would run: tests/check-cluster.sh --config ${CONFIG_FILE}"
    return 0
  fi
  run_stage VERIFY_cluster \
    bash "${SCRIPT_DIR}/../tests/check-cluster.sh" --config "$CONFIG_FILE"
}

# ── main ──────────────────────────────────────────────────────────────────────

preflight

ACTIVE=0
[[ -z "$FROM_STAGE" ]] && ACTIVE=1
PAST_TO=0

for stage in "${STAGES[@]}"; do
  [[ -n "$FROM_STAGE" && "$stage" == "$FROM_STAGE" ]] && ACTIVE=1

  if (( PAST_TO )); then
    info "Skipping ${stage} (after --to ${TO_STAGE})"
  elif (( ACTIVE )); then
    "do_${stage}"
  else
    info "Skipping ${stage} (before --from ${FROM_STAGE})"
  fi

  if [[ -n "$TO_STAGE" && "$stage" == "$TO_STAGE" ]]; then
    ACTIVE=0
    PAST_TO=1
  fi
done

say "Cluster is operational."
info "Registry is empty on a fresh bring-up — push application images"
info "whenever you're ready (any OCI client; see docs/OPERATIONS.md)."
