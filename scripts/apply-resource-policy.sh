#!/usr/bin/env bash
# D-00: Apply cluster-wide resource policy.
#
# Creates PriorityClasses (interactive / background) and per-namespace
# LimitRanges so pods that omit resource specs get sane defaults.
#
# PriorityClasses are cluster-scoped and must exist before Ollama and agent
# Deployments are applied; otherwise the priorityClassName field is silently
# ignored. Run this once after k3s is up, before any workload deploys.
#
# Usage:
#   ./apply-resource-policy.sh            # apply everything
#   ./apply-resource-policy.sh --verify   # show current state
#   ./apply-resource-policy.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
DRY=0
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY=1;        shift ;;
    --verify)  DO_VERIFY=1;  shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

say()  { echo "==> $*"; }
info() { echo "    $*"; }

# ── verify mode ───────────────────────────────────────────────────────────────

if (( DO_VERIFY )); then
  say "PriorityClasses:"
  kubectl get priorityclass interactive background 2>/dev/null \
    || info "PriorityClasses not yet applied."
  echo
  say "LimitRange — ollama:"
  kubectl get limitrange -n ollama 2>/dev/null \
    || info "Namespace 'ollama' not found."
  info ""
  info "Applications manage their own namespace's LimitRange — this script"
  info "only owns cluster-scoped PriorityClasses and tpi-bro's own platform"
  info "services (Ollama)."
  exit 0
fi

# ── apply ─────────────────────────────────────────────────────────────────────

if (( DRY )); then
  say "Dry-run — would apply:"
  info "kubectl apply -f ${MANIFESTS_DIR}/priority-classes.yaml"
  info "kubectl apply -f ${MANIFESTS_DIR}/limitrange-ollama.yaml"
  exit 0
fi

say "Applying PriorityClasses (cluster-scoped)…"
kubectl apply -f "${MANIFESTS_DIR}/priority-classes.yaml"

say "Applying LimitRange — ollama namespace…"
kubectl apply -f "${MANIFESTS_DIR}/limitrange-ollama.yaml"

say "Done."
info ""
info "Verify: ./scripts/apply-resource-policy.sh --verify"
info ""
info "Restart Ollama to pick up the new priorityClassName:"
info "  kubectl rollout restart deployment -n ollama"
info ""
info "Applications own their own namespace's LimitRange and are responsible"
info "for restarting their own Deployments to pick up priorityClassName —"
info "see docs/DEPLOYING-AN-AGENT.md."
