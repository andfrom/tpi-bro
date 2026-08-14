#!/usr/bin/env bash
# N-01 Layer 1: Install Tailscale on all cluster nodes.
#
# Installs tailscaled and runs `tailscale up` on each node, joining them to
# your Tailnet with stable IPs and MagicDNS names (rk1-node1…4.tailnet.ts.net).
# --accept-dns=false protects k3s CoreDNS from being overridden.
#
# Prerequisites:
#   - TAILSCALE_AUTH_KEY in ~/.turingpi/credentials.kv
#     Generate a reusable pre-authorized key at:
#     https://login.tailscale.com/admin/settings/keys
#   - SSH key auth to all nodes (Phase B prerequisite)
#   - tailscale installed on the laptop separately (not covered here)
#
# Usage:
#   ./install-tailscale.sh               # install on all nodes
#   ./install-tailscale.sh --node rk1-node2  # single node
#   ./install-tailscale.sh --status      # show tailscale status on all nodes
#   ./install-tailscale.sh --dry-run
#   ./install-tailscale.sh [--config FILE] [--key FILE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
SSH_KEY="${HOME}/.ssh/id_ed25519"
DRY=0
STATUS_ONLY=0
TARGET_NODE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    --key)     SSH_KEY="$2";     shift 2 ;;
    --node)    TARGET_NODE="$2"; shift 2 ;;
    --dry-run) DRY=1;            shift   ;;
    --status)  STATUS_ONLY=1;    shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE"); SERVER_IDX="${SERVER_IDX:-1}"

node_ssh() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    "ubuntu@$ip" "$@"
}

[[ -f "$CONFIG_FILE" ]] || err "Config not found: $CONFIG_FILE"
[[ -f "$CREDS_FILE"  ]] || err "Credentials not found: $CREDS_FILE"

if ! (( STATUS_ONLY )); then
  AUTH_KEY=$(kv_get TAILSCALE_AUTH_KEY "$CREDS_FILE")
  [[ -n "$AUTH_KEY" ]] || err "TAILSCALE_AUTH_KEY not set in $CREDS_FILE"
fi

# ── build node list ───────────────────────────────────────────────────────────

NODE_NAMES=()
if [[ -n "$TARGET_NODE" ]]; then
  NODE_NAMES+=("$TARGET_NODE")
else
  for i in 1 2 3 4; do
    NODE_NAMES+=("rk1-node${i}")
  done
fi

# ── status mode ───────────────────────────────────────────────────────────────

if (( STATUS_ONLY )); then
  for name in "${NODE_NAMES[@]}"; do
    say "${name}"
    node_ssh "$name" "tailscale status 2>/dev/null || echo '(not installed or not running)'"
  done
  exit 0
fi

# ── install + bring up ────────────────────────────────────────────────────────

for name in "${NODE_NAMES[@]}"; do
  say "${name}"

  if (( DRY )); then
    info "[dry-run] Would install tailscale if not present"
    info "[dry-run] Would: sudo tailscale up --hostname=${name} --accept-dns=false --accept-routes"
    continue
  fi

  # Install if not already present (official install script; ARM64 Ubuntu supported)
  if ! node_ssh "$name" "command -v tailscale > /dev/null 2>&1"; then
    info "Installing tailscale…"
    node_ssh "$name" "curl -fsSL https://tailscale.com/install.sh | sudo sh"
  else
    info "tailscale already installed."
  fi

  # Ensure daemon is running
  node_ssh "$name" "sudo systemctl enable --now tailscaled 2>/dev/null || true"

  # Bring up — idempotent; re-running with a key re-authenticates cleanly
  info "Running tailscale up…"
  node_ssh "$name" "sudo tailscale up \
    --auth-key=${AUTH_KEY} \
    --hostname=${name} \
    --accept-dns=false \
    --accept-routes=false"

  ts_ip=$(node_ssh "$name" "tailscale ip -4 2>/dev/null" || true)
  info "Tailscale IP: ${ts_ip:-<check admin console>}"

  # k3s's serving cert is issued at install time with only the LAN hostname/IP
  # as SANs (install-k3s.sh has no way to know the Tailscale IP yet, since
  # Tailscale isn't installed until this later step) — so kubectl over
  # Tailscale fails TLS verification unless the server node's Tailscale IP is
  # added here. Idempotent: only touches config.yaml/restarts k3s if the IP
  # isn't already present.
  if [[ "$name" == "rk1-node${SERVER_IDX}" && -n "$ts_ip" ]]; then
    if ! node_ssh "$name" "sudo test -f /etc/rancher/k3s/config.yaml && grep -q '${ts_ip}' /etc/rancher/k3s/config.yaml" 2>/dev/null; then
      info "Adding Tailscale IP as a k3s TLS SAN on ${name} (server node)…"
      node_ssh "$name" "sudo mkdir -p /etc/rancher/k3s && \
        if sudo test -f /etc/rancher/k3s/config.yaml && sudo grep -q '^tls-san:' /etc/rancher/k3s/config.yaml; then \
          echo '  - ${ts_ip}' | sudo tee -a /etc/rancher/k3s/config.yaml >/dev/null; \
        else \
          { echo 'tls-san:'; echo '  - ${ts_ip}'; } | sudo tee -a /etc/rancher/k3s/config.yaml >/dev/null; \
        fi && \
        sudo systemctl restart k3s"
      info "k3s restarted; API server cert now covers ${ts_ip}"
    fi
  fi
done

say "Done. Verify at https://login.tailscale.com/admin/machines"
info ""
info "Next: run ./scripts/setup-subnet-router.sh to advertise k3s CIDRs"
info "      (makes all ClusterIP services routable from the laptop)"
