#!/usr/bin/env bash
# Distributes the laptop's SSH public key to all RK1 nodes and configures
# passwordless sudo, so Phase B scripts can run without password prompts.
#
# Usage:
#   ./setup-ssh-keys.sh                    # all 4 nodes
#   ./setup-ssh-keys.sh --verify           # test passwordless SSH on all nodes
#   ./setup-ssh-keys.sh --key ~/.ssh/id_ed25519  # override key (default: id_ed25519)
#   ./setup-ssh-keys.sh [--state FILE] [--config FILE]

set -euo pipefail

STATE_FILE="./bootstrap-state.kv"
CONFIG_FILE="./bootstrap-config.kv"
SSH_KEY="${HOME}/.ssh/id_ed25519"
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --state)  STATE_FILE="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --key)    SSH_KEY="$2";    shift 2 ;;
    --verify) DO_VERIFY=1;     shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()  { echo "==> $*"; }
info() { echo "    $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

# ---- prerequisites ----------------------------------------------------------

[[ -f "$CONFIG_FILE" ]] || err "Config file not found: $CONFIG_FILE"
[[ -f "$STATE_FILE"  ]] || err "State file not found: $STATE_FILE"

if ! command -v sshpass &>/dev/null; then
  say "Installing sshpass…"
  sudo apt-get install -y sshpass
fi

NODE_USER=$(kv_get DEFAULT_USER "$CONFIG_FILE")
[[ -n "$NODE_USER" ]] || NODE_USER=ubuntu

# ---- verify mode ------------------------------------------------------------

verify_nodes() {
  say "Verifying passwordless SSH on all nodes…"
  local failed=()
  for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
    local ip
    ip=$(kv_get "$node" "$STATE_FILE")
    if ssh -i "$SSH_KEY" \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=10 \
         -o BatchMode=yes \
         "$NODE_USER@$ip" hostname &>/dev/null; then
      info "OK — $node ($ip) accepts key auth"
    else
      echo "  FAIL: $node ($ip) rejected key auth"
      failed+=("$node")
    fi
  done
  echo
  if [[ ${#failed[@]} -eq 0 ]]; then
    say "PASS — all nodes accept key-based SSH."
  else
    echo "FAIL: ${failed[*]}"
    exit 1
  fi
}

if (( DO_VERIFY )); then
  verify_nodes
  exit 0
fi

# ---- key setup --------------------------------------------------------------

[[ -f "${SSH_KEY}.pub" ]] || err "Public key not found: ${SSH_KEY}.pub"
PUBKEY=$(cat "${SSH_KEY}.pub")
say "Using key: ${SSH_KEY}.pub"
info "$PUBKEY"
echo

echo -n "Node password (NEW_PASS set during Phase A): "
read -rs NODE_PASS
echo
echo

# ---- per-node setup ---------------------------------------------------------

FAILED=()

for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
  ip=$(kv_get "$node" "$STATE_FILE")
  [[ -n "$ip" ]] || err "No IP for $node in $STATE_FILE"

  say "Configuring $node ($ip)…"

  sshpass -p "$NODE_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "$NODE_USER@$ip" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh
grep -qF '${PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${PUBKEY}' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo '${NODE_PASS}' | sudo -S tee /etc/sudoers.d/ubuntu-nopasswd >/dev/null <<'SUDOERS'
ubuntu ALL=(ALL) NOPASSWD: ALL
SUDOERS
echo '${NODE_PASS}' | sudo -S chmod 440 /etc/sudoers.d/ubuntu-nopasswd
echo DONE" 2>/dev/null || { echo "  WARN: SSH failed for $node"; FAILED+=("$node"); continue; }

  # Verify key auth works immediately
  if ssh -i "$SSH_KEY" \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=10 \
       -o BatchMode=yes \
       "$NODE_USER@$ip" hostname &>/dev/null; then
    info "OK — key auth verified"
  else
    echo "  WARN: key auth failed on $node after setup"
    FAILED+=("$node")
  fi
  echo
done

if [[ ${#FAILED[@]} -eq 0 ]]; then
  say "Done. All nodes accept key-based SSH with passwordless sudo."
  echo
  echo "Test manually: ssh ubuntu@rk1-node1"
  echo "Next: Phase B1 — k3s installation"
else
  echo "WARNING: failed on ${FAILED[*]} — re-run to retry."
  exit 1
fi
