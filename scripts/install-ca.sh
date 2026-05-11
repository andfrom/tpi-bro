#!/usr/bin/env bash
# Installs the registry CA on one node and configures the k3s containerd mirror.
#
# Usage:
#   ./install-ca.sh <node-ip> [--ca-cert FILE] [--registry ADDR] [--config FILE] [--creds FILE]
set -euo pipefail

CONFIG_FILE="./bootstrap-config.kv"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
CA_CERT=""
REGISTRY_ADDR=""
REGISTRY_IP=""
DRY=0
NODE_IP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --ca-cert)      CA_CERT="$2";       shift 2 ;;
    --registry)     REGISTRY_ADDR="$2"; shift 2 ;;
    --registry-ip)  REGISTRY_IP="$2";   shift 2 ;;
    --config)       CONFIG_FILE="$2";   shift 2 ;;
    --creds)        CREDS_FILE="$2";    shift 2 ;;
    --dry-run)      DRY=1;              shift   ;;
    -*)             echo "Unknown flag: $1"; exit 1 ;;
    *)              NODE_IP="$1";       shift ;;
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

# Derive server IP from config if not provided — used for the mirror endpoint URL
# so worker nodes don't need DNS resolution for rk1-node1.
if [[ -z "$REGISTRY_IP" && -f "$CONFIG_FILE" ]]; then
  _base=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
  if [[ -n "$_base" ]]; then
    REGISTRY_IP=$(ip_add "$_base" "$SERVER_IDX")
  fi
fi

[[ -f "$CA_CERT" ]] || err "CA cert not found: $CA_CERT (run gen-registry-certs.sh first)"

# ---- copy CA cert -----------------------------------------------------------

say "Copying CA cert to ${NODE_IP}…"
if (( DRY )); then
  info "[dry-run] Would scp $CA_CERT → ubuntu@${NODE_IP}:/usr/local/share/ca-certificates/registry-ca.crt"
  info "[dry-run] Would run: sudo update-ca-certificates"
else
  node_scp "$CA_CERT" /tmp/registry-ca.crt
  node_ssh sudo mv /tmp/registry-ca.crt /usr/local/share/ca-certificates/registry-ca.crt
  node_ssh sudo chmod 644 /usr/local/share/ca-certificates/registry-ca.crt
  node_ssh sudo update-ca-certificates
fi

# ---- write containerd mirror config -----------------------------------------

say "Writing /etc/rancher/k3s/registries.yaml on ${NODE_IP}…"
node_ssh sudo mkdir -p /etc/rancher/k3s

REG_ADDR="$REGISTRY_ADDR"
REG_PORT="${REG_ADDR##*:}"
# Use IP in endpoint URL so worker nodes don't need hostname DNS for rk1-node1
ENDPOINT_HOST="${REGISTRY_IP:-${REG_ADDR%:*}}"
ENDPOINT_URL="https://${ENDPOINT_HOST}:${REG_PORT}"

# Build optional auth block from credentials file
AUTH_BLOCK=""
if [[ -f "$CREDS_FILE" ]]; then
  REG_USER=$(kv_get REGISTRY_USER     "$CREDS_FILE")
  REG_PASS=$(kv_get REGISTRY_PASSWORD "$CREDS_FILE")
  if [[ -n "$REG_USER" && -n "$REG_PASS" ]]; then
    info "Adding auth credentials for containerd mirror…"
    AUTH_BLOCK="    auth:
      username: ${REG_USER}
      password: ${REG_PASS}"
  fi
fi

if (( DRY )); then
  info "[dry-run] Would write /etc/rancher/k3s/registries.yaml"
  info "[dry-run]   mirror: ${REG_ADDR} → ${ENDPOINT_URL}"
  [[ -n "$AUTH_BLOCK" ]] && info "[dry-run]   with auth credentials from ${CREDS_FILE}"
else
  node_ssh sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<EOF
mirrors:
  "${REG_ADDR}":
    endpoint:
      - "${ENDPOINT_URL}"
configs:
  "${ENDPOINT_HOST}:${REG_PORT}":
    tls:
      ca_file: "/usr/local/share/ca-certificates/registry-ca.crt"
${AUTH_BLOCK}
EOF
fi

# ---- restart k3s or k3s-agent -----------------------------------------------

say "Detecting k3s service type on ${NODE_IP}…"
if (( DRY )); then
  info "[dry-run] Would restart k3s or k3s-agent on ${NODE_IP}"
else
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
fi

say "Done: CA installed and containerd mirror configured on ${NODE_IP}."
