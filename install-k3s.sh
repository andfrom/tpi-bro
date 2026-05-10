#!/usr/bin/env bash
# Installs k3s on the TuringPi cluster:
#   - k3s server on rk1-node1 (SERVER_NODE_IDX in config)
#   - k3s agent  on rk1-node{2,3,4}
#   - local kubeconfig at ~/.kube/config
#
# Requires B0 complete: SSH key auth + passwordless sudo on all nodes.
# Idempotent: safe to re-run if k3s is already installed.
#
# Usage:
#   ./install-k3s.sh                  # full install
#   ./install-k3s.sh --verify         # check cluster state only
#   ./install-k3s.sh --server-only    # server only (get token for manual agent setup)
#   ./install-k3s.sh --kubeconfig     # refresh local kubeconfig only
#   ./install-k3s.sh [--state FILE] [--config FILE] [--key FILE]

set -euo pipefail

STATE_FILE="./bootstrap-state.kv"
CONFIG_FILE="./bootstrap-config.kv"
SSH_KEY="${HOME}/.ssh/id_ed25519"
DO_SERVER=1
DO_AGENTS=1
DO_KUBECONFIG=1
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --state)        STATE_FILE="$2";  shift 2 ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --key)          SSH_KEY="$2";     shift 2 ;;
    --server-only)  DO_AGENTS=0; DO_KUBECONFIG=0; shift ;;
    --kubeconfig)   DO_SERVER=0; DO_AGENTS=0;      shift ;;
    --verify)       DO_VERIFY=1; DO_SERVER=0; DO_AGENTS=0; DO_KUBECONFIG=0; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2-; }
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

wait_ssh() {
  local ip="$1" timeout_s="$2"
  local deadline=$(( $(date +%s) + timeout_s ))
  while (( $(date +%s) < deadline )); do
    node_ssh "$ip" true &>/dev/null && return 0
    sleep 5
  done
  return 1
}

# ---- read config ------------------------------------------------------------

[[ -f "$CONFIG_FILE" ]] || err "Config file not found: $CONFIG_FILE"
[[ -f "$STATE_FILE"  ]] || err "State file not found: $STATE_FILE"

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE")
NODE_COUNT=$(kv_get NODE_COUNT      "$CONFIG_FILE")
[[ -n "$TPI_BASE"    ]] || err "TPI_BASE_IP_ADDR not set in $CONFIG_FILE"
[[ -n "$SERVER_IDX"  ]] || SERVER_IDX=1
[[ -n "$NODE_COUNT"  ]] || NODE_COUNT=4

SERVER_NODE="rk1-node${SERVER_IDX}"
SERVER_IP=$(ip_add "$TPI_BASE" "$SERVER_IDX")
SERVER_URL="https://${SERVER_IP}:6443"

AGENT_NODES=()
for (( i=1; i<=NODE_COUNT; i++ )); do
  (( i == SERVER_IDX )) && continue
  AGENT_NODES+=("rk1-node${i}")
done

# ---- verify -----------------------------------------------------------------

verify_cluster() {
  say "Cluster state:"
  kubectl --kubeconfig ~/.kube/config get nodes -o wide 2>/dev/null || {
    echo "  kubectl failed — is kubeconfig set up? Run: ./install-k3s.sh --kubeconfig"
    exit 1
  }
}

if (( DO_VERIFY )); then
  verify_cluster
  exit 0
fi

# ---- install k3s server -----------------------------------------------------

install_server() {
  say "Installing k3s server on $SERVER_NODE ($SERVER_IP)…"

  local already
  already=$(node_ssh "$SERVER_IP" \
    "systemctl is-active k3s 2>/dev/null || true")

  if [[ "$already" == "active" ]]; then
    info "k3s server already running — skipping install."
    return 0
  fi

  info "Running k3s install script (ARM64, may take 2-3 min)…"
  node_ssh "$SERVER_IP" \
    "curl -sfL https://get.k3s.io | sudo sh -s - \
       --node-name ${SERVER_NODE} \
       --write-kubeconfig-mode 644 \
       --tls-san ${SERVER_NODE} \
       --tls-san ${SERVER_IP}"

  info "Waiting for k3s server to become active (up to 120s)…"
  local deadline=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < deadline )); do
    local st
    st=$(node_ssh "$SERVER_IP" "systemctl is-active k3s 2>/dev/null || true")
    [[ "$st" == "active" ]] && break
    sleep 5
  done

  local st
  st=$(node_ssh "$SERVER_IP" "systemctl is-active k3s 2>/dev/null || true")
  [[ "$st" == "active" ]] || err "k3s server did not become active within 120s"
  info "k3s server active."
}

# ---- get node token ---------------------------------------------------------

get_token() {
  node_ssh "$SERVER_IP" \
    "sudo cat /var/lib/rancher/k3s/server/node-token"
}

# ---- install k3s agents -----------------------------------------------------

install_agents() {
  local token="$1"
  for node in "${AGENT_NODES[@]}"; do
    local idx="${node##*-node}"
    local ip
    ip=$(ip_add "$TPI_BASE" "$idx")

    say "Installing k3s agent on $node ($ip)…"

    local already
    already=$(node_ssh "$ip" \
      "systemctl is-active k3s-agent 2>/dev/null || true")

    if [[ "$already" == "active" ]]; then
      info "k3s agent already running on $node — skipping."
      continue
    fi

    node_ssh "$ip" \
      "curl -sfL https://get.k3s.io | \
         K3S_URL=${SERVER_URL} \
         K3S_TOKEN=${token} \
         sudo -E sh -s - \
           --node-name ${node}"

    info "Agent install command sent to $node."
  done
}

# ---- wait for all nodes Ready -----------------------------------------------

wait_nodes_ready() {
  say "Waiting for all nodes to be Ready (up to 5 min)…"
  local deadline=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < deadline )); do
    local ready
    ready=$(node_ssh "$SERVER_IP" \
      "sudo kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'" || echo 0)
    info "Ready: $ready / $NODE_COUNT"
    (( ready >= NODE_COUNT )) && break
    sleep 10
  done

  local ready
  ready=$(node_ssh "$SERVER_IP" \
    "sudo kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'" || echo 0)
  if (( ready < NODE_COUNT )); then
    echo "  WARN: only $ready/$NODE_COUNT nodes Ready after 5 min — continuing anyway."
    echo "  Check: kubectl get nodes"
  fi
}

# ---- local kubeconfig -------------------------------------------------------

setup_kubeconfig() {
  say "Fetching kubeconfig from $SERVER_NODE…"
  mkdir -p ~/.kube
  [[ -f ~/.kube/config ]] && cp ~/.kube/config ~/.kube/config.bak \
    && info "Existing config backed up to ~/.kube/config.bak"

  node_ssh "$SERVER_IP" "cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s|https://127.0.0.1:6443|${SERVER_URL}|g" \
    | sed "s|https://localhost:6443|${SERVER_URL}|g" \
    > ~/.kube/config
  chmod 600 ~/.kube/config
  info "kubeconfig written to ~/.kube/config (server: ${SERVER_URL})"
}

# ---- run --------------------------------------------------------------------

(( DO_SERVER     )) && install_server
(( DO_SERVER     )) && TOKEN=$(get_token)
(( DO_AGENTS     )) && install_agents "$TOKEN"
(( DO_SERVER || DO_AGENTS )) && wait_nodes_ready
(( DO_KUBECONFIG )) && setup_kubeconfig

if (( DO_KUBECONFIG )); then
  echo
  say "Done."
  kubectl get nodes -o wide
fi
