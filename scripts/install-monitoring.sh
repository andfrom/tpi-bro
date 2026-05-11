#!/usr/bin/env bash
# D-04: Deploy kube-prometheus-stack (Prometheus + Grafana + Alertmanager).
#
# Stateful components (Prometheus, Grafana, Alertmanager) are pinned to NVMe
# nodes via nodeSelector so local-ssd PVC binding succeeds.
# Grafana is exposed on the Tailnet via the Tailscale operator after deploy.
#
# Prerequisites:
#   - GRAFANA_ADMIN_PASSWORD in ~/.turingpi/credentials.kv
#   - N-01 Layer 3 (Tailscale operator) deployed for Grafana Tailnet exposure
#   - helm on the laptop
#
# Usage:
#   ./install-monitoring.sh               # deploy + expose Grafana on Tailnet
#   ./install-monitoring.sh --verify      # show status of all components
#   ./install-monitoring.sh --dry-run
#   ./install-monitoring.sh [--config FILE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
DRY=0
DO_VERIFY=0
NAMESPACE="monitoring"
HELM_RELEASE="kube-prometheus-stack"
CHART_VALUES="${SCRIPT_DIR}/../charts/monitoring/values.yaml"

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)  CREDS_FILE="$2"; shift 2 ;;
    --dry-run) DRY=1;           shift   ;;
    --verify)  DO_VERIFY=1;     shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()    { echo "==> $*"; }
info()   { echo "    $*"; }
err()    { echo "ERROR: $*" >&2; exit 1; }

# ── verify mode ───────────────────────────────────────────────────────────────

if (( DO_VERIFY )); then
  say "Monitoring stack status:"
  kubectl get deploy,statefulset,daemonset -n "$NAMESPACE" 2>/dev/null \
    || info "Namespace '${NAMESPACE}' not found."
  echo
  say "Persistent volumes:"
  kubectl get pvc -n "$NAMESPACE" 2>/dev/null
  echo
  say "Grafana Tailnet exposure:"
  kubectl get svc -n "$NAMESPACE" "${HELM_RELEASE}-grafana" 2>/dev/null \
    | grep -E "NAME|grafana" || true
  exit 0
fi

# ── preflight ─────────────────────────────────────────────────────────────────

[[ -f "$CREDS_FILE"   ]] || err "Credentials not found: $CREDS_FILE"
[[ -f "$CHART_VALUES" ]] || err "Values file not found: $CHART_VALUES"

GRAFANA_PASS=$(kv_get GRAFANA_ADMIN_PASSWORD "$CREDS_FILE")
[[ -n "$GRAFANA_PASS" ]] || err "GRAFANA_ADMIN_PASSWORD not set in $CREDS_FILE"

if (( DRY )); then
  say "Dry-run: kube-prometheus-stack in namespace '${NAMESPACE}'"
  info "[dry-run] Would: helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
  info "[dry-run] Would: helm upgrade --install ${HELM_RELEASE} prometheus-community/kube-prometheus-stack \\"
  info "              -n ${NAMESPACE} --create-namespace -f ${CHART_VALUES} \\"
  info "              --set grafana.adminPassword=<secret>"
  info "[dry-run] Would: kubectl annotate svc ${HELM_RELEASE}-grafana -n ${NAMESPACE} tailscale.com/expose=true"
  exit 0
fi

# ── deploy ────────────────────────────────────────────────────────────────────

say "Adding prometheus-community Helm repo…"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

say "Installing kube-prometheus-stack (this takes a few minutes)…"
helm upgrade --install "$HELM_RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$CHART_VALUES" \
  --set grafana.adminPassword="${GRAFANA_PASS}" \
  --timeout 10m \
  --wait

say "Exposing Grafana on Tailnet…"
kubectl annotate svc "${HELM_RELEASE}-grafana" -n "$NAMESPACE" tailscale.com/expose=true --overwrite

say "Done."
info ""
info "Grafana: http://monitoring-${HELM_RELEASE}-grafana.<tailnet>.ts.net:80"
info "         username: admin  password: (from credentials.kv)"
info ""
info "Prometheus: http://$(kubectl get svc -n monitoring kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null):9090  (ClusterIP, subnet-routed)"
info ""
info "Verify: ./scripts/install-monitoring.sh --verify"
