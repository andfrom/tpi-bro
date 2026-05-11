#!/usr/bin/env bash
# N-01 Layer 2: Configure node1 as a Tailscale subnet router.
#
# Advertises the k3s pod CIDR (10.42.0.0/16) and service CIDR (10.43.0.0/16)
# on the Tailnet. Once approved in the Tailscale admin console, every ClusterIP
# service is directly routable from the laptop — no port-forward needed.
#
# After running this script you must approve the routes in the Tailscale admin:
#   https://login.tailscale.com/admin/machines
#   → Click rk1-node1 → Edit route settings → enable both advertised routes
#
# On the laptop, run once:
#   sudo tailscale up --accept-routes
#
# Usage:
#   ./setup-subnet-router.sh
#   ./setup-subnet-router.sh --dry-run
#   ./setup-subnet-router.sh [--config FILE] [--key FILE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
SSH_KEY="${HOME}/.ssh/id_ed25519"
DRY=0

# k3s default CIDRs — override if you customised them during install
POD_CIDR="10.42.0.0/16"
SVC_CIDR="10.43.0.0/16"

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    --key)     SSH_KEY="$2";     shift 2 ;;
    --dry-run) DRY=1;            shift   ;;
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

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
[[ -n "$TPI_BASE" ]] || err "TPI_BASE_IP_ADDR not set in $CONFIG_FILE"

SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE"); SERVER_IDX="${SERVER_IDX:-1}"
SERVER_IP=$(ip_add "$TPI_BASE" "$SERVER_IDX")

say "Configuring rk1-node${SERVER_IDX} (${SERVER_IP}) as Tailscale subnet router"
info "Advertising: ${POD_CIDR} (pods), ${SVC_CIDR} (services)"

if (( DRY )); then
  info "[dry-run] Would: enable net.ipv4.ip_forward + net.ipv6.conf.all.forwarding on rk1-node${SERVER_IDX}"
  info "[dry-run] Would: sudo tailscale up --hostname=rk1-node${SERVER_IDX} --advertise-routes=${POD_CIDR},${SVC_CIDR} --accept-routes=false --accept-dns=false"
  info ""
  info "[dry-run] ACTION REQUIRED after real run:"
  info "  https://login.tailscale.com/admin/machines → rk1-node${SERVER_IDX} → Edit route settings"
  info "  Laptop: sudo tailscale up --accept-routes"
  exit 0
fi

say "Enabling IP forwarding…"
node_ssh "$SERVER_IP" "printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
  | sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null \
  && sudo sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null"

say "Advertising subnet routes…"
# Must restate all non-default flags when changing settings via tailscale up.
node_ssh "$SERVER_IP" "sudo tailscale up \
  --hostname=rk1-node${SERVER_IDX} \
  --advertise-routes=${POD_CIDR},${SVC_CIDR} \
  --accept-routes=false \
  --accept-dns=false"

ts_ip=$(node_ssh "$SERVER_IP" "tailscale ip -4 2>/dev/null" || true)
say "Done. rk1-node${SERVER_IDX} Tailscale IP: ${ts_ip:-<check admin console>}"
info ""
info "============================================================"
info "ACTION REQUIRED — approve routes in Tailscale admin console:"
info "  https://login.tailscale.com/admin/machines"
info "  → Click on rk1-node${SERVER_IDX}"
info "  → Edit route settings"
info "  → Enable: ${POD_CIDR}  and  ${SVC_CIDR}"
info "============================================================"
info ""
info "On the laptop, run once:"
info "  sudo tailscale up --accept-routes"
info ""
info "Then verify (ClusterIP of kubernetes service):"
info "  curl -s http://\$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}'):443 || true"
