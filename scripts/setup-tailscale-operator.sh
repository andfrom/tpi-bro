#!/usr/bin/env bash
# N-01 Layer 3: Deploy the Tailscale Kubernetes operator.
#
# The operator watches for annotated Services and exposes each as its own
# Tailscale device with a stable MagicDNS name:
#
#   kubectl annotate svc agent-a -n sibling-app tailscale.com/expose=true
#   → accessible at http://agent-a.<tailnet>.ts.net:18090 from any Tailnet device
#
# No ingress controller, no port-forward, no kubectl needed.
# New agents self-advertise on the Tailnet just by being annotated.
#
# Prerequisites:
#   1. Layer 1 done (install-tailscale.sh) — nodes on the Tailnet
#   2. OAuth client in ~/.turingpi/credentials.kv:
#        TAILSCALE_OAUTH_CLIENT_ID=<id>
#        TAILSCALE_OAUTH_CLIENT_SECRET=<secret>
#      Generate at: https://login.tailscale.com/admin/settings/trust-credentials
#      Scopes: Devices → Core → Write (required), DNS → Read (for MagicDNS)
#   3. helm on the laptop
#
# Usage:
#   ./setup-tailscale-operator.sh
#   ./setup-tailscale-operator.sh --dry-run
#   ./setup-tailscale-operator.sh --expose svc/agent-a -n sibling-app
#   ./setup-tailscale-operator.sh --verify

set -euo pipefail

CREDS_FILE="${HOME}/.turingpi/credentials.kv"
DRY=0
DO_VERIFY=0
EXPOSE_SVC=""
EXPOSE_NS=""
NAMESPACE="tailscale"
HELM_RELEASE="tailscale-operator"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY=1;           shift   ;;
    --verify)  DO_VERIFY=1;     shift   ;;
    --expose)  EXPOSE_SVC="$2"; shift 2 ;;
    -n)        EXPOSE_NS="$2";  shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()    { echo "==> $*"; }
info()   { echo "    $*"; }
err()    { echo "ERROR: $*" >&2; exit 1; }

# ── verify mode ───────────────────────────────────────────────────────────────

if (( DO_VERIFY )); then
  say "Tailscale operator status:"
  kubectl get deploy,pod -n "$NAMESPACE" 2>/dev/null || info "Namespace '${NAMESPACE}' not found."
  say "Exposed services (ProxyGroup / tailscale proxy pods):"
  kubectl get svc -A -l tailscale.com/managed=true 2>/dev/null || info "No exposed services found."
  exit 0
fi

# ── expose a single service ───────────────────────────────────────────────────

if [[ -n "$EXPOSE_SVC" ]]; then
  [[ -n "$EXPOSE_NS" ]] || err "Use -n NAMESPACE with --expose"
  svc_name="${EXPOSE_SVC#svc/}"
  say "Exposing ${svc_name} (namespace: ${EXPOSE_NS}) on Tailnet…"
  if (( DRY )); then
    info "[dry-run] Would: kubectl annotate svc ${svc_name} -n ${EXPOSE_NS} tailscale.com/expose=true"
  else
    kubectl annotate svc "$svc_name" -n "$EXPOSE_NS" tailscale.com/expose=true --overwrite
    info "Done. Device will appear at: http://${svc_name}.<tailnet>.ts.net"
    info "Check status: kubectl get svc -n ${EXPOSE_NS} ${svc_name}"
  fi
  exit 0
fi

# ── deploy operator ───────────────────────────────────────────────────────────

[[ -f "$CREDS_FILE" ]] || err "Credentials not found: $CREDS_FILE"
CLIENT_ID=$(kv_get TAILSCALE_OAUTH_CLIENT_ID "$CREDS_FILE")
CLIENT_SECRET=$(kv_get TAILSCALE_OAUTH_CLIENT_SECRET "$CREDS_FILE")
[[ -n "$CLIENT_ID"     ]] || err "TAILSCALE_OAUTH_CLIENT_ID not set in $CREDS_FILE"
[[ -n "$CLIENT_SECRET" ]] || err "TAILSCALE_OAUTH_CLIENT_SECRET not set in $CREDS_FILE"

say "Deploying Tailscale Kubernetes operator (namespace: ${NAMESPACE})…"

if (( DRY )); then
  info "[dry-run] Would: helm repo add tailscale https://pkgs.tailscale.com/helmcharts"
  info "[dry-run] Would: helm upgrade --install ${HELM_RELEASE} tailscale/tailscale-operator \\"
  info "              --namespace ${NAMESPACE} --create-namespace \\"
  info "              --set-string oauth.clientId=<id> --set-string oauth.clientSecret=<secret>"
  info ""
  info "After deploying, expose services with:"
  info "  ./setup-tailscale-operator.sh --expose svc/agent-a -n sibling-app"
  exit 0
fi

say "Adding Tailscale Helm repo…"
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update tailscale

say "Installing operator…"
helm upgrade --install "$HELM_RELEASE" tailscale/tailscale-operator \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set-string oauth.clientId="${CLIENT_ID}" \
  --set-string oauth.clientSecret="${CLIENT_SECRET}" \
  --set-string proxyConfig.defaultTags="tag:k8s-operator" \
  --wait --timeout 120s

say "Done."
info ""
info "Expose services on the Tailnet:"
info "  ./scripts/setup-tailscale-operator.sh --expose svc/agent-a -n sibling-app"
info "  → accessible at http://agent-a.<tailnet>.ts.net:18090"
info ""
info "Or annotate directly:"
info "  kubectl annotate svc <name> -n <namespace> tailscale.com/expose=true"
info ""
info "Verify: ./scripts/setup-tailscale-operator.sh --verify"
