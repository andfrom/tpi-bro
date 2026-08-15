#!/usr/bin/env bash
# E-01: Deploy the job queue — KEDA + Redis + the demo `echo` ScaledJob.
#
# This is the cluster's sole external boundary per ADR-0028; the job contract
# (queue keys, envelope, results, producer obligations) is ADR-0029.
#
# What it does:
#   1. Installs KEDA (kedacore Helm chart, namespace `keda`) — idempotent.
#   2. Ensures REDIS_PASSWORD in ~/.turingpi/credentials.kv (generated and
#      appended if missing) and mirrors it into the jobqueue-redis-auth
#      Secret in namespace `jobqueue`.
#   3. Installs charts/jobqueue (Redis + TriggerAuthentication + echo demo).
#
# Usage:
#   ./install-jobqueue.sh              # install/upgrade everything
#   ./install-jobqueue.sh --verify     # end-to-end echo roundtrip test
#   ./install-jobqueue.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART="${SCRIPT_DIR}/../charts/jobqueue"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
NAMESPACE="jobqueue"
SECRET_NAME="jobqueue-redis-auth"
RELEASE="jobqueue"
DRY=0
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY=1;         shift ;;
    --verify)  DO_VERIFY=1;   shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

redis_pod() {
  kubectl get pod -n "$NAMESPACE" -l "app=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Run a redis-cli command inside the Redis pod (no laptop-side redis needed).
rcli() {
  local pod
  pod=$(redis_pod)
  [[ -n "$pod" ]] || return 1
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    sh -c "redis-cli --no-auth-warning -a \"\$REDIS_PASSWORD\" $*"
}

# ── verify mode: full echo roundtrip through KEDA ────────────────────────────

if (( DO_VERIFY )); then
  say "Job-queue roundtrip: enqueue → KEDA scale-from-zero → result…"
  id="verify-$(date +%s)-$$"
  rcli "LPUSH jobs:echo '{\"id\":\"${id}\",\"payload\":{\"probe\":true}}'" >/dev/null \
    || err "Could not enqueue — is the jobqueue deployed? (./install-jobqueue.sh)"
  deadline=$(( $(date +%s) + 90 ))
  result=""
  while (( $(date +%s) < deadline )); do
    result=$(rcli "GET result:${id}" | tr -d '\r')
    [[ -n "$result" ]] && break
    sleep 3
  done
  [[ -n "$result" ]] || err "No result:${id} after 90s — check: kubectl get scaledjob,jobs -n ${NAMESPACE}"
  info "result: ${result}"
  grep -q '"ok":true' <<<"$result" || err "Result present but not ok"
  rcli "DEL result:${id}" >/dev/null || true
  say "Roundtrip OK — the ADR-0028 boundary is live."
  exit 0
fi

# ── preflight ─────────────────────────────────────────────────────────────────

command -v helm >/dev/null 2>&1 || err "helm not found"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"
[[ -d "$CHART" ]] || err "Chart not found: ${CHART}"

if (( DRY )); then
  say "Dry-run: job queue (E-01)"
  info "[dry-run] Would: helm repo add kedacore && helm upgrade --install keda kedacore/keda -n keda --create-namespace"
  info "[dry-run] Would: ensure REDIS_PASSWORD in ${CREDS_FILE} (generate if missing)"
  info "[dry-run] Would: create namespace ${NAMESPACE} + secret ${SECRET_NAME}"
  info "[dry-run] Would: helm upgrade --install ${RELEASE} charts/jobqueue -n ${NAMESPACE}"
  exit 0
fi

# ── 1. KEDA ───────────────────────────────────────────────────────────────────

say "Installing KEDA…"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace --wait --timeout 5m
info "KEDA ready."

# ── 2. credentials + secret ───────────────────────────────────────────────────

REDIS_PASSWORD=$(kv_get REDIS_PASSWORD "$CREDS_FILE")
if [[ -z "$REDIS_PASSWORD" ]]; then
  say "REDIS_PASSWORD not in ${CREDS_FILE} — generating one…"
  REDIS_PASSWORD=$(openssl rand -hex 16)
  {
    echo ""
    echo "# Job queue (E-01) — Redis requirepass"
    echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
  } >> "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  info "Appended REDIS_PASSWORD to ${CREDS_FILE}."
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
info "Secret ${SECRET_NAME} in namespace ${NAMESPACE} up to date."

# ── 3. chart ──────────────────────────────────────────────────────────────────

say "Installing job queue chart…"
helm upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE"
kubectl rollout status deployment/"$RELEASE" -n "$NAMESPACE" --timeout=120s

say "Done."
info "Verify the boundary end-to-end: ./install-jobqueue.sh --verify"
