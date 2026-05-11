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
ip_add()  { local p="${1%.*}" l="${1##*.}"; echo "${p}.$((l + $2))"; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

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

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
[[ -n "$TPI_BASE" ]] || err "TPI_BASE_IP_ADDR not set in $CONFIG_FILE"

if ! (( STATUS_ONLY )); then
  AUTH_KEY=$(kv_get TAILSCALE_AUTH_KEY "$CREDS_FILE")
  [[ -n "$AUTH_KEY" ]] || err "TAILSCALE_AUTH_KEY not set in $CREDS_FILE"
fi

# ── build node list ───────────────────────────────────────────────────────────

NODE_IPS=()
NODE_NAMES=()
if [[ -n "$TARGET_NODE" ]]; then
  idx="${TARGET_NODE##*node}"
  NODE_IPS+=("$(ip_add "$TPI_BASE" "$idx")")
  NODE_NAMES+=("$TARGET_NODE")
else
  for i in 1 2 3 4; do
    NODE_IPS+=("$(ip_add "$TPI_BASE" "$i")")
    NODE_NAMES+=("rk1-node${i}")
  done
fi

# ── status mode ───────────────────────────────────────────────────────────────

if (( STATUS_ONLY )); then
  for i in "${!NODE_IPS[@]}"; do
    ip="${NODE_IPS[$i]}" name="${NODE_NAMES[$i]}"
    say "${name} (${ip})"
    node_ssh "$ip" "tailscale status 2>/dev/null || echo '(not installed or not running)'"
  done
  exit 0
fi

# ── install + bring up ────────────────────────────────────────────────────────

for i in "${!NODE_IPS[@]}"; do
  ip="${NODE_IPS[$i]}" name="${NODE_NAMES[$i]}"
  say "${name} (${ip})"

  if (( DRY )); then
    info "[dry-run] Would install tailscale if not present"
    info "[dry-run] Would: sudo tailscale up --hostname=${name} --accept-dns=false --accept-routes"
    continue
  fi

  # Install if not already present (official install script; ARM64 Ubuntu supported)
  if ! node_ssh "$ip" "command -v tailscale > /dev/null 2>&1"; then
    info "Installing tailscale…"
    node_ssh "$ip" "curl -fsSL https://tailscale.com/install.sh | sudo sh"
  else
    info "tailscale already installed."
  fi

  # Ensure daemon is running
  node_ssh "$ip" "sudo systemctl enable --now tailscaled 2>/dev/null || true"

  # Bring up — idempotent; re-running with a key re-authenticates cleanly
  info "Running tailscale up…"
  node_ssh "$ip" "sudo tailscale up \
    --auth-key=${AUTH_KEY} \
    --hostname=${name} \
    --accept-dns=false \
    --accept-routes"

  ts_ip=$(node_ssh "$ip" "tailscale ip -4 2>/dev/null" || true)
  info "Tailscale IP: ${ts_ip:-<check admin console>}"
done

say "Done. Verify at https://login.tailscale.com/admin/machines"
info ""
info "Next: run ./scripts/setup-subnet-router.sh to advertise k3s CIDRs"
info "      (makes all ClusterIP services routable from the laptop)"
