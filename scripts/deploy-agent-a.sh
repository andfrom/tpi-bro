#!/usr/bin/env bash
# D-02: Build the sibling-app Agent A image on the laptop and deploy to k3s.
#
# Build strategy (no QEMU pre-installed required):
#   1. Register QEMU ARM64 binfmt handler if not already active (survives until reboot)
#   2. Create a docker-container buildx builder if not already present (one-time)
#   3. docker buildx build --platform linux/arm64 --load  → loads into host Docker daemon
#   4. docker push  → host daemon already trusts the cluster registry CA (Phase B)
#   5. kubectl apply  → rolls out the Deployment
#
# Usage:
#   ./deploy-agent-a.sh                     # build + push + deploy
#   ./deploy-agent-a.sh --build-only        # build + push; skip kubectl apply
#   ./deploy-agent-a.sh --deploy-only       # kubectl apply only (image already pushed)
#   ./deploy-agent-a.sh --dry-run
#   ./deploy-agent-a.sh [--sibling-app-dir DIR]   # default: sibling 'sibling-app' repo next to tpi-bro
#   ./deploy-agent-a.sh [--config FILE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
PRIME_DIR="${SCRIPT_DIR}/../../sibling-app"
BUILDER_NAME="tpi-bro-builder"
DRY=0
DO_BUILD=1
DO_DEPLOY=1

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --sibling-app-dir)   PRIME_DIR="$2";   shift 2 ;;
    --dry-run)     DRY=1;            shift   ;;
    --build-only)  DO_DEPLOY=0;      shift   ;;
    --deploy-only) DO_BUILD=0;       shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ip_add()  { local p="${1%.*}" l="${1##*.}"; echo "${p}.$((l + $2))"; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

# ── resolve paths ─────────────────────────────────────────────────────────────

[[ -f "$CONFIG_FILE" ]] || err "Config not found: $CONFIG_FILE"
[[ -f "$CREDS_FILE"  ]] || err "Credentials not found: $CREDS_FILE"

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE"); SERVER_IDX="${SERVER_IDX:-1}"
[[ -n "$TPI_BASE" ]] || err "TPI_BASE_IP_ADDR not set in $CONFIG_FILE"

REGISTRY="rk1-node${SERVER_IDX}:5000"
IMAGE="${REGISTRY}/sibling-app-agent-a:latest"

REG_USER=$(kv_get REGISTRY_USER     "$CREDS_FILE")
REG_PASS=$(kv_get REGISTRY_PASSWORD "$CREDS_FILE")
[[ -n "$REG_USER" ]] || err "REGISTRY_USER not set in $CREDS_FILE"
[[ -n "$REG_PASS" ]] || err "REGISTRY_PASSWORD not set in $CREDS_FILE"

PRIME_DIR="$(cd "$PRIME_DIR" 2>/dev/null && pwd)" \
  || err "sibling-app directory not found. Use --sibling-app-dir PATH."
DOCKERFILE="${PRIME_DIR}/infra/docker/agent-a.Dockerfile"
MANIFEST="${PRIME_DIR}/infra/k8s/agent-a.yaml"
[[ -f "$DOCKERFILE" ]] || err "Dockerfile not found: $DOCKERFILE"
[[ -f "$MANIFEST"   ]] || err "k8s manifest not found: $MANIFEST"

# ── build + push ──────────────────────────────────────────────────────────────

if (( DO_BUILD )); then
  say "Building ${IMAGE} for linux/arm64 on laptop…"

  if (( DRY )); then
    info "[dry-run] Would register QEMU ARM64 binfmt if not present"
    info "[dry-run] Would create buildx builder '${BUILDER_NAME}' if not present"
    info "[dry-run] Would: docker buildx build --platform linux/arm64 --load --tag ${IMAGE} ${PRIME_DIR}"
    info "[dry-run] Would: docker push ${IMAGE}"
  else
    # 1. QEMU binfmt (survives until reboot; re-run after reboot automatically)
    if ! ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q qemu-aarch64; then
      say "Registering QEMU ARM64 binfmt handler…"
      docker run --privileged --rm tonistiigi/binfmt --install arm64
    else
      info "QEMU ARM64 binfmt already registered."
    fi

    # 2. docker-container buildx builder (one-time)
    if ! docker buildx inspect "$BUILDER_NAME" &>/dev/null; then
      say "Creating buildx builder '${BUILDER_NAME}'…"
      docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap
    fi

    # 3. Build for arm64, load into host Docker daemon
    say "Building (this takes a few minutes on first run)…"
    docker buildx build \
      --builder "$BUILDER_NAME" \
      --platform linux/arm64 \
      --tag "$IMAGE" \
      --file "$DOCKERFILE" \
      --load \
      "$PRIME_DIR"

    # 4. Push from host daemon (which already trusts the cluster registry CA)
    say "Logging in to ${REGISTRY}…"
    echo "$REG_PASS" | docker login "$REGISTRY" -u "$REG_USER" --password-stdin

    say "Pushing ${IMAGE}…"
    docker push "$IMAGE"

    docker logout "$REGISTRY" 2>/dev/null || true
    info "Image pushed: ${IMAGE}"
  fi
fi

# ── deploy ────────────────────────────────────────────────────────────────────

if (( DO_DEPLOY )); then
  say "Applying k8s manifests…"
  if (( DRY )); then
    info "[dry-run] Would: kubectl apply -f ${MANIFEST}"
    info "[dry-run] Would: kubectl rollout status deployment/agent-a -n sibling-app --timeout=120s"
  else
    kubectl apply -f "$MANIFEST"
    say "Waiting for agent-a to be Ready (up to 120s)…"
    kubectl rollout status deployment/agent-a -n sibling-app --timeout=120s
    say "agent-a deployed."
    info ""
    info "In-cluster: http://agent-a.sibling-app:18090"
    info "Health:     kubectl exec -n sibling-app deploy/agent-a -- curl -s http://localhost:18090/healthz"
    info "Port-fwd:   kubectl port-forward -n sibling-app svc/agent-a 18090:18090"
  fi
fi

say "Done."
