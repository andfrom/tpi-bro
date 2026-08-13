#!/usr/bin/env bash
# setup-offnet-access.sh — Configure this laptop for off-network cluster access.
#
# What this script does:
#   1. Reads node1's Tailscale IP from bootstrap-config.kv (or --ts-ip flag)
#   2. Trusts the cluster registry CA cert in Docker's cert store for that IP
#   3. Optionally restarts Docker to apply the new cert trust
#   4. Verifies registry reachability over Tailscale
#   5. Prints the TAILSCALE_REGISTRY_IP value to add to your application's .env
#
# Run once per laptop when working off-network (e.g., coffee shop, travel).
# Re-run after cert regeneration or if the Tailscale IP changes.
#
# Usage:
#   ./scripts/setup-offnet-access.sh
#   ./scripts/setup-offnet-access.sh --ts-ip <node1-tailscale-ip>
#   ./scripts/setup-offnet-access.sh --config ./bootstrap-config.kv --cert-dir ./registry-certs
#   ./scripts/setup-offnet-access.sh --dry-run
#   ./scripts/setup-offnet-access.sh --verify-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
CERT_DIR="${SCRIPT_DIR}/../registry-certs"
REGISTRY_PORT=5000
DRY=0
VERIFY_ONLY=0
TS_IP_OVERRIDE=""
RESTART_DOCKER=1

# ── helpers ───────────────────────────────────────────────────────────────────

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
warn()    { echo "WARN: $*" >&2; }
err()     { echo "ERROR: $*" >&2; exit 1; }

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)        CONFIG_FILE="$2";    shift 2 ;;
    --cert-dir)      CERT_DIR="$2";       shift 2 ;;
    --ts-ip)         TS_IP_OVERRIDE="$2"; shift 2 ;;
    --no-restart)    RESTART_DOCKER=0;    shift   ;;
    --dry-run)       DRY=1;               shift   ;;
    --verify-only)   VERIFY_ONLY=1;       shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── resolve Tailscale IP ──────────────────────────────────────────────────────

if [[ -n "$TS_IP_OVERRIDE" ]]; then
  NODE1_TS_IP="$TS_IP_OVERRIDE"
elif [[ -f "$CONFIG_FILE" ]]; then
  NODE1_TS_IP=$(kv_get NODE1_TAILSCALE_IP "$CONFIG_FILE")
  if [[ -z "$NODE1_TS_IP" ]]; then
    # Fall back: parse second IP from REG_SAN_IP (space-separated)
    REG_SAN=$(kv_get REG_SAN_IP "$CONFIG_FILE")
    read -ra _ips <<< "$REG_SAN"
    [[ ${#_ips[@]} -ge 2 ]] && NODE1_TS_IP="${_ips[1]}" || true
  fi
fi

[[ -n "${NODE1_TS_IP:-}" ]] || err \
  "Cannot determine node1 Tailscale IP. Set NODE1_TAILSCALE_IP in $CONFIG_FILE or pass --ts-ip."

REGISTRY_ADDR="${NODE1_TS_IP}:${REGISTRY_PORT}"
CA_CERT="${CERT_DIR}/myCA.crt"
DOCKER_CERT_DIR="/etc/docker/certs.d/${REGISTRY_ADDR}"
DOCKER_CA_PATH="${DOCKER_CERT_DIR}/ca.crt"

# ── verify-only mode ──────────────────────────────────────────────────────────

if (( VERIFY_ONLY )); then
  say "Verifying off-network registry access to ${REGISTRY_ADDR}…"
  if curl -sf --max-time 10 "https://${REGISTRY_ADDR}/v2/" >/dev/null 2>&1 || \
     curl -sf --max-time 10 -u "$(kv_get REGISTRY_USER "${HOME}/.turingpi/credentials.kv" 2>/dev/null || echo push):x" \
          "https://${REGISTRY_ADDR}/v2/" >/dev/null 2>&1; then
    say "Registry reachable at ${REGISTRY_ADDR} — Tailscale cert trust is working."
  else
    warn "Registry not reachable at ${REGISTRY_ADDR}."
    info "Check: is Tailscale connected?  →  tailscale status"
    info "Check: is Docker cert trusted?  →  ls /etc/docker/certs.d/${REGISTRY_ADDR}/"
    exit 1
  fi
  exit 0
fi

# ── pre-flight checks ─────────────────────────────────────────────────────────

say "Setting up off-network cluster access"
info "Tailscale registry: ${REGISTRY_ADDR}"
info "CA cert source:     ${CA_CERT}"
info "Docker trust dir:   ${DOCKER_CERT_DIR}"

[[ -f "$CA_CERT" ]] || err "CA cert not found: ${CA_CERT}
  Generate it first: tpi-bro/scripts/gen-registry-certs.sh"

# ── Docker cert trust ─────────────────────────────────────────────────────────

say "Trusting registry CA cert in Docker for ${REGISTRY_ADDR}…"

if (( DRY )); then
  info "[dry-run] Would: sudo mkdir -p ${DOCKER_CERT_DIR}"
  info "[dry-run] Would: sudo cp ${CA_CERT} ${DOCKER_CA_PATH}"
else
  sudo mkdir -p "$DOCKER_CERT_DIR"
  sudo cp "$CA_CERT" "$DOCKER_CA_PATH"
  info "Cert installed: ${DOCKER_CA_PATH}"
fi

# ── Docker restart ────────────────────────────────────────────────────────────

if (( RESTART_DOCKER )); then
  say "Restarting Docker to apply cert changes…"
  if (( DRY )); then
    info "[dry-run] Would: sudo systemctl restart docker"
  else
    sudo systemctl restart docker
    info "Docker restarted."
  fi
else
  warn "Skipping Docker restart (--no-restart). Run 'sudo systemctl restart docker' manually."
fi

# ── verify Tailscale reachability ─────────────────────────────────────────────

say "Verifying Tailscale connectivity…"
if ! tailscale status 2>/dev/null | grep -q rk1-node1; then
  warn "rk1-node1 not visible in 'tailscale status' — is Tailscale connected?"
  info "Run: tailscale up"
fi

if (( ! DRY )); then
  if curl -sf --max-time 10 "https://${REGISTRY_ADDR}/v2/" >/dev/null 2>&1; then
    say "Registry reachable at ${REGISTRY_ADDR}"
  else
    warn "Registry not responding at ${REGISTRY_ADDR} — check Tailscale connection and registry health."
    info "  tailscale status | grep rk1-node1"
    info "  kubectl get pods -n registry"
  fi
fi

# ── print next steps ──────────────────────────────────────────────────────────

say "Done."
echo
echo "Add the following to your application's .env to enable off-network builds:"
echo ""
echo "  TAILSCALE_REGISTRY_IP=${NODE1_TS_IP}"
echo ""
echo "Then re-source .env (or open a new shell) and run:"
echo "  export TAILSCALE_REGISTRY_IP=${NODE1_TS_IP}"
echo "  cd <your-app>  &&  make build-push   # or whatever your build target is"
