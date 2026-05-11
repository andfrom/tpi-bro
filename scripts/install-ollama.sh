#!/usr/bin/env bash
# D-01: Deploy Ollama to all NVMe-capable nodes (one instance per node).
#
# Usage:
#   ./install-ollama.sh                     # deploy to all nodes labeled storage.tpi-bro/nvme=true
#   ./install-ollama.sh --node rk1-node1    # deploy to one node only
#   ./install-ollama.sh --model llama3.2:3b # pull a model after deploying (repeatable)
#   ./install-ollama.sh --verify            # print status of all Ollama instances
#   ./install-ollama.sh --dry-run
#   ./install-ollama.sh [--config FILE] [--state FILE]
#
# Release names: ollama-node1, ollama-node2, ollama-node3 (all in namespace 'ollama').
# In-cluster DNS: ollama-node1.ollama:11434, ollama-node2.ollama:11434, …

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY=0
TARGET_NODE=""
MODELS=()
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)  shift 2 ;;  # accepted but unused; config not needed for k8s-only deploy
    --state)   shift 2 ;;
    --dry-run) DRY=1;            shift   ;;
    --node)    TARGET_NODE="$2"; shift 2 ;;
    --model)   MODELS+=("$2");   shift 2 ;;
    --verify)  DO_VERIFY=1;      shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

say()  { echo "==> $*"; }
info() { echo "    $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

CHART="${SCRIPT_DIR}/../charts/ollama"

# ── resolve target nodes ──────────────────────────────────────────────────────

get_nvme_nodes() {
  kubectl get nodes -l storage.tpi-bro/nvme=true \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | sort
}

if [[ -n "$TARGET_NODE" ]]; then
  NODES=("$TARGET_NODE")
else
  mapfile -t NODES < <(get_nvme_nodes)
fi

[[ ${#NODES[@]} -gt 0 ]] || \
  err "No target nodes. Use --node NODE or ensure nodes are labeled storage.tpi-bro/nvme=true."

# release name: rk1-node1 → ollama-node1
release_name() { echo "ollama-${1#rk1-}"; }

# ── verify mode ───────────────────────────────────────────────────────────────

if (( DO_VERIFY )); then
  say "Ollama instance status:"
  for node in "${NODES[@]}"; do
    rel=$(release_name "$node")
    pod=$(kubectl get pod -n ollama -l "app=${rel}" --no-headers 2>/dev/null \
      | awk '{print $1}' | head -1)
    if [[ -z "$pod" ]]; then
      info "${node} (${rel}): NOT DEPLOYED"
      continue
    fi
    phase=$(kubectl get pod "$pod" -n ollama --no-headers 2>/dev/null | awk '{print $3}')
    ready=$(kubectl get pod "$pod" -n ollama --no-headers 2>/dev/null | awk '{print $2}')
    models=""
    if [[ "$phase" == "Running" ]]; then
      models=$(kubectl exec "$pod" -n ollama -- ollama list 2>/dev/null \
        | tail -n +2 | awk '{print $1}' | tr '\n' ' ' || echo "error")
    fi
    info "${node} (${rel}): phase=${phase} ready=${ready} models=${models:-none}"
  done
  echo
  kubectl get deploy,pvc,svc -n ollama 2>/dev/null \
    || info "namespace 'ollama' not found"
  exit 0
fi

# ── deploy ────────────────────────────────────────────────────────────────────

say "Target nodes: ${NODES[*]}"

if (( DRY )); then
  info "[dry-run] Would: kubectl create namespace ollama"
  for node in "${NODES[@]}"; do
    rel=$(release_name "$node")
    info "[dry-run] Would: helm upgrade --install ${rel} charts/ollama -n ollama --set nodeName=${node}"
    for model in "${MODELS[@]}"; do
      info "[dry-run] Would: kubectl exec -n ollama deploy/${rel} -- ollama pull ${model}"
    done
  done
  exit 0
fi

kubectl create namespace ollama --dry-run=client -o yaml | kubectl apply -f -

for node in "${NODES[@]}"; do
  rel=$(release_name "$node")
  say "Deploying ${rel} → ${node}…"
  helm upgrade --install "${rel}" "$CHART" \
    -n ollama \
    --set nodeName="${node}"
done

say "Waiting for all Ollama pods to be Ready (up to 5m each)…"
for node in "${NODES[@]}"; do
  rel=$(release_name "$node")
  kubectl rollout status deployment/"${rel}" -n ollama --timeout=300s
  info "${rel}: Ready"
done

if [[ ${#MODELS[@]} -gt 0 ]]; then
  say "Pulling models: ${MODELS[*]}"
  for node in "${NODES[@]}"; do
    rel=$(release_name "$node")
    pod=$(kubectl get pod -n ollama -l "app=${rel}" --no-headers \
      | awk '{print $1}' | head -1)
    if [[ -z "$pod" ]]; then
      info "WARN: no pod for ${rel} — skipping model pull"
      continue
    fi
    for model in "${MODELS[@]}"; do
      info "${rel}: pulling ${model} (may take several minutes)…"
      kubectl exec -n ollama "$pod" -- ollama pull "$model"
      info "${rel}: ${model} ready"
    done
  done
fi

say "Done."
info "In-cluster endpoints:"
for node in "${NODES[@]}"; do
  rel=$(release_name "$node")
  info "  http://${rel}.ollama:11434  (${node})"
done
if [[ ${#MODELS[@]} -eq 0 ]]; then
  info ""
  info "No models pulled. Pull one with:"
  info "  ./scripts/install-ollama.sh --model llama3.2:3b"
fi
