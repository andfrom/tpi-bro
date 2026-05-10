#!/usr/bin/env bash
# Installs the registry CA on one node and configures the k3s containerd mirror.
#
# Usage:
#   ./install-ca.sh <node-ip> [--ca-cert FILE] [--registry ADDR] [--config FILE]
set -euo pipefail

CONFIG_FILE="./bootstrap-config.kv"
CA_CERT=""
REGISTRY_ADDR=""
NODE_IP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --ca-cert)   CA_CERT="$2";       shift 2 ;;
    --registry)  REGISTRY_ADDR="$2"; shift 2 ;;
    --config)    CONFIG_FILE="$2";   shift 2 ;;
    -*)          echo "Unknown flag: $1"; exit 1 ;;
    *)           NODE_IP="$1";       shift ;;
  esac
done

[[ -n "$NODE_IP" ]] || { echo "Usage: $0 <node-ip> [--ca-cert FILE] [--registry ADDR] [--config FILE]"; exit 1; }

# ---- helpers ----------------------------------------------------------------

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ip_add()  { local p="${1%.*}" l="${1##*.}"; echo "${p}.$((l + $2))"; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

SSH_KEY="${HOME}/.ssh/id_ed25519"
node_ssh() {
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    "ubuntu@${NODE_IP}" "$@"
}
node_scp() {
  scp -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$1" "ubuntu@${NODE_IP}:$2"
}

# ---- read config ------------------------------------------------------------

SERVER_IDX=1
if [[ -f "$CONFIG_FILE" ]]; then
  _idx=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE")
  [[ -n "$_idx" ]] && SERVER_IDX="$_idx"
fi

[[ -n "$CA_CERT"        ]] || CA_CERT="./registry-certs/myCA.crt"
[[ -n "$REGISTRY_ADDR"  ]] || REGISTRY_ADDR="rk1-node${SERVER_IDX}:5000"

[[ -f "$CA_CERT" ]] || err "CA cert not found: $CA_CERT (run gen-registry-certs.sh first)"

# ---- copy CA cert -----------------------------------------------------------

say "Copying CA cert to ${NODE_IP}…"
node_scp "$CA_CERT" /tmp/registry-ca.crt
node_ssh sudo mv /tmp/registry-ca.crt /usr/local/share/ca-certificates/registry-ca.crt
node_ssh sudo chmod 644 /usr/local/share/ca-certificates/registry-ca.crt
node_ssh sudo update-ca-certificates

# ---- write containerd mirror config -----------------------------------------

say "Writing /etc/rancher/k3s/registries.yaml on ${NODE_IP}…"
node_ssh sudo mkdir -p /etc/rancher/k3s

REG_ADDR="$REGISTRY_ADDR"

node_ssh sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<EOF
mirrors:
  "${REG_ADDR}":
    endpoint:
      - "https://${REG_ADDR}"
configs:
  "${REG_ADDR}":
    tls:
      ca_file: "/usr/local/share/ca-certificates/registry-ca.crt"
EOF

# ---- restart k3s or k3s-agent -----------------------------------------------

say "Detecting k3s service type on ${NODE_IP}…"
SVC=$(node_ssh "if systemctl is-active k3s &>/dev/null; then echo k3s; \
               elif systemctl is-active k3s-agent &>/dev/null; then echo k3s-agent; \
               else echo none; fi")

case "$SVC" in
  k3s)
    info "Server node — restarting k3s."
    node_ssh sudo systemctl restart k3s
    ;;
  k3s-agent)
    info "Agent node — restarting k3s-agent."
    node_ssh sudo systemctl restart k3s-agent
    ;;
  *)
    err "Neither k3s nor k3s-agent is active on ${NODE_IP}. Is k3s installed?"
    ;;
esac

say "Done: CA installed and containerd mirror configured on ${NODE_IP}."
