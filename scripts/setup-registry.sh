#!/usr/bin/env bash
# Phase B2: Deploy the private Docker registry to k3s.
#
# Usage:
#   ./setup-registry.sh              # full B2 deploy
#   ./setup-registry.sh --certs-only # just generate certs
#   ./setup-registry.sh --ca-only    # just distribute CA to all nodes
#   ./setup-registry.sh --enable-auth # B-07: create htpasswd secret + enable auth
#   ./setup-registry.sh --migrate-pvc # B-09: move registry PVC from eMMC to local-ssd
#   ./setup-registry.sh --verify     # test registry push/pull (with login if auth enabled)
#   ./setup-registry.sh [--config FILE] [--state FILE]
set -euo pipefail

CONFIG_FILE="./bootstrap-config.kv"
STATE_FILE="./bootstrap-state.kv"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
DO_CERTS=1
DO_STOP_OLD=1
DO_NAMESPACE=1
DO_TLS_SECRET=1
DO_HELM=1
DO_WAIT=1
DO_CA=1
DO_LAPTOP=1
DO_AUTH=0
DO_VERIFY=0
DO_MIGRATE_PVC=0
DRY=0
YES=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --state)        STATE_FILE="$2";  shift 2 ;;
    --dry-run)      DRY=1;            shift   ;;
    --yes)          YES=1;            shift   ;;
    --certs-only)   DO_STOP_OLD=0; DO_NAMESPACE=0; DO_TLS_SECRET=0; DO_HELM=0;
                    DO_WAIT=0; DO_CA=0; DO_LAPTOP=0; shift ;;
    --ca-only)      DO_CERTS=0; DO_STOP_OLD=0; DO_NAMESPACE=0; DO_TLS_SECRET=0;
                    DO_HELM=0; DO_WAIT=0; DO_LAPTOP=0; shift ;;
    --enable-auth)  DO_CERTS=0; DO_STOP_OLD=0; DO_NAMESPACE=0; DO_TLS_SECRET=0;
                    DO_HELM=0; DO_WAIT=0; DO_CA=0; DO_LAPTOP=0; DO_AUTH=1; shift ;;
    --verify)       DO_CERTS=0; DO_STOP_OLD=0; DO_NAMESPACE=0; DO_TLS_SECRET=0;
                    DO_HELM=0; DO_WAIT=0; DO_CA=0; DO_LAPTOP=0; DO_VERIFY=1; shift ;;
    --migrate-pvc)  DO_CERTS=0; DO_STOP_OLD=0; DO_NAMESPACE=0; DO_TLS_SECRET=0;
                    DO_HELM=0; DO_WAIT=0; DO_CA=0; DO_LAPTOP=0; DO_MIGRATE_PVC=1; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
kv_set() {
  local key="$1" val="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

SSH_KEY="${HOME}/.ssh/id_ed25519"
node_ssh() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    "ubuntu@${ip}" "$@"
}

# ---- read config ------------------------------------------------------------

[[ -f "$CONFIG_FILE" ]] || err "Config file not found: $CONFIG_FILE"
[[ -f "$STATE_FILE"  ]] || err "State file not found: $STATE_FILE"

SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE")
NODE_COUNT=$(kv_get NODE_COUNT      "$CONFIG_FILE")
[[ -n "$SERVER_IDX"  ]] || SERVER_IDX=1
[[ -n "$NODE_COUNT"  ]] || NODE_COUNT=4

SERVER_NODE="rk1-node${SERVER_IDX}"
REGISTRY_ADDR="${SERVER_NODE}:5000"

CERT_DIR_CFG=$(kv_get CERT_DIR "$CONFIG_FILE")
CERT_DIR="${CERT_DIR_CFG:-./registry-certs}"

# ---- stage: prereqs ---------------------------------------------------------

stage_prereqs() {
  say "Checking prerequisites…"
  if ! command -v helm &>/dev/null; then
    err "helm not found. Install with: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  fi
  info "helm: $(helm version --short)"
}

# ---- stage: certs -----------------------------------------------------------

stage_certs() {
  if (( DRY )); then
    info "[dry-run] Would generate registry TLS certs in ${CERT_DIR}/"
    return 0
  fi
  if [[ -f "${CERT_DIR}/registry.crt" ]]; then
    info "Certs already exist at ${CERT_DIR}/registry.crt — skipping generation."
    return 0
  fi
  say "Generating registry TLS certificates…"
  bash "$(dirname "$0")/gen-registry-certs.sh" --config "$CONFIG_FILE"
}

# ---- stage: stop-old --------------------------------------------------------

stage_stop_old() {
  say "Removing Phase A Docker registry container on ${SERVER_NODE} (if present)…"
  if (( DRY )); then
    info "[dry-run] Would run: sudo docker stop registry && sudo docker rm registry on ${SERVER_NODE}"
    return 0
  fi
  node_ssh "$SERVER_NODE" \
    "sudo docker stop registry 2>/dev/null || true; sudo docker rm registry 2>/dev/null || true"
  info "Done (no-op if container was already gone)."
}

# ---- stage: namespace -------------------------------------------------------

stage_namespace() {
  say "Ensuring namespace 'registry' exists…"
  if (( DRY )); then
    info "[dry-run] Would: kubectl create namespace registry"
    return 0
  fi
  kubectl create namespace registry --dry-run=client -o yaml | kubectl apply -f -
}

# ---- stage: tls-secret ------------------------------------------------------

stage_tls_secret() {
  say "Creating/updating TLS secret 'registry-tls' in namespace 'registry'…"
  if (( DRY )); then
    info "[dry-run] Would create secret registry-tls from ${CERT_DIR}/registry.{crt,key}"
    return 0
  fi
  [[ -f "${CERT_DIR}/registry.crt" ]] || err "registry.crt not found in ${CERT_DIR}. Run --certs-only first."
  [[ -f "${CERT_DIR}/registry.key" ]] || err "registry.key not found in ${CERT_DIR}."
  kubectl create secret tls registry-tls \
    -n registry \
    --cert="${CERT_DIR}/registry.crt" \
    --key="${CERT_DIR}/registry.key" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
}

# ---- stage: helm-install ----------------------------------------------------

stage_helm_install() {
  say "Deploying registry Helm chart…"
  if (( DRY )); then
    info "[dry-run] Would: helm upgrade --install registry charts/registry -n registry (nodeSelector: ${SERVER_NODE})"
    return 0
  fi
  helm upgrade --install registry "$(dirname "$0")/../charts/registry" \
    -n registry \
    --set auth.enabled=false \
    --set persistence.storageClass=local-path \
    --set service.hostPort=5000 \
    --set service.type=ClusterIP \
    --set "nodeSelector.kubernetes\\.io/hostname=${SERVER_NODE}"
}

# ---- stage: wait-pod --------------------------------------------------------

stage_wait_pod() {
  say "Waiting for registry pod to be Ready (up to 120s)…"
  if (( DRY )); then
    info "[dry-run] Would poll until registry pod Ready"
    return 0
  fi
  kubectl wait --for=condition=ready pod \
    -l app=registry \
    -n registry \
    --timeout=120s
}

# ---- stage: ca-distribute ---------------------------------------------------

stage_ca_distribute() {
  say "Distributing CA cert and configuring containerd mirror on all nodes…"
  local install_ca
  install_ca="$(dirname "$0")/install-ca.sh"
  [[ -x "$install_ca" ]] || chmod +x "$install_ca"

  local dry_flag=()
  (( DRY )) && dry_flag=(--dry-run)

  for (( i=1; i<=NODE_COUNT; i++ )); do
    local node_name="rk1-node${i}"
    say "  Node ${node_name}…"
    bash "$install_ca" "$node_name" \
      --ca-cert "${CERT_DIR}/myCA.crt" \
      --registry "$REGISTRY_ADDR" \
      --config "$CONFIG_FILE" \
      "${dry_flag[@]}"
  done
}

# ---- stage: laptop-docker-trust ---------------------------------------------

stage_laptop_docker_trust() {
  say "Installing CA trust on laptop Docker…"
  if (( DRY )); then
    info "[dry-run] Would copy ${CERT_DIR}/myCA.crt → /etc/docker/certs.d/${REGISTRY_ADDR}/ca.crt and restart docker"
    return 0
  fi
  local cert_dir="/etc/docker/certs.d/${REGISTRY_ADDR}"
  local src="${CERT_DIR}/myCA.crt"
  local dst="${cert_dir}/ca.crt"

  if [[ -f "$dst" ]] && diff -q "$src" "$dst" &>/dev/null; then
    info "CA already installed at ${dst} — skipping Docker restart."
    return 0
  fi

  sudo mkdir -p "$cert_dir"
  sudo cp "$src" "$dst"
  sudo systemctl restart docker
  info "Done."
}

# ---- stage: enable-auth -----------------------------------------------------

stage_enable_auth() {
  say "Enabling registry basic auth (B-07)…"
  if (( DRY )); then
    info "[dry-run] Would create secret registry-htpasswd and helm upgrade with auth.enabled=true"
    return 0
  fi
  [[ -f "$CREDS_FILE" ]] || err "Credentials file not found: ${CREDS_FILE}"

  local reg_user reg_pass
  reg_user=$(kv_get REGISTRY_USER     "$CREDS_FILE")
  [[ -n "$reg_user" ]] || err "REGISTRY_USER not set in ${CREDS_FILE}"

  reg_pass=$(kv_get REGISTRY_PASSWORD "$CREDS_FILE")
  if [[ -z "$reg_pass" ]]; then
    info "REGISTRY_PASSWORD not set in ${CREDS_FILE} — generating one…"
    reg_pass=$(openssl rand -base64 24)
    kv_set REGISTRY_PASSWORD "$reg_pass" "$CREDS_FILE"
    info "Generated and saved to ${CREDS_FILE}. Registry push password: ${reg_pass}"
    info "(Note it down now — this is the only time it's printed.)"
  fi

  info "Creating htpasswd secret for user '${reg_user}'…"
  local tmp
  tmp=$(mktemp)
  htpasswd -Bbn "$reg_user" "$reg_pass" > "$tmp"
  kubectl create secret generic registry-htpasswd \
    -n registry \
    --from-file=htpasswd="$tmp" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
  rm -f "$tmp"

  info "Upgrading Helm release with auth.enabled=true…"
  helm upgrade registry "$(dirname "$0")/../charts/registry" \
    -n registry \
    --reuse-values \
    --set auth.enabled=true

  say "Waiting for registry pod to be Ready after upgrade (up to 120s)…"
  kubectl rollout status deployment/registry -n registry --timeout=120s

  say "Auth enabled. Test with: docker login ${REGISTRY_ADDR}"
}

# ---- stage: verify ----------------------------------------------------------

stage_migrate_pvc() {
  say "Migrating registry PVC from eMMC (local-path) to SSD (local-ssd)…"

  # Idempotence gate: if the PVC is already on local-ssd there is nothing to
  # migrate — and re-running the migration anyway would uninstall/reinstall
  # the registry and DESTROY all pushed images. Critical for orchestrated
  # re-runs (bootstrap-operational.sh), where --yes suppresses the prompt.
  local current_sc
  current_sc=$(kubectl get pvc registry-data -n registry \
    -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
  if [[ "$current_sc" == "local-ssd" ]]; then
    info "Registry PVC already on local-ssd — nothing to migrate, skipping."
    return 0
  fi

  if (( DRY )); then
    info "[dry-run] Would: helm uninstall registry -n registry --wait"
    info "[dry-run] Would: helm upgrade --install registry … --set persistence.storageClass=local-ssd"
    info "[dry-run] Note: existing registry data (pushed images) will be lost"
    return 0
  fi

  # Verify local-ssd StorageClass exists before proceeding
  kubectl get sc local-ssd &>/dev/null \
    || err "StorageClass 'local-ssd' not found. Run mount-ssd.sh first."

  # Verify the SSD is actually mounted on the server node
  local ssd_mounted
  ssd_mounted=$(node_ssh "$SERVER_NODE" "mountpoint -q /mnt/ssd && echo yes || echo no" 2>/dev/null || echo no)
  [[ "$ssd_mounted" == "yes" ]] \
    || err "/mnt/ssd is not mounted on ${SERVER_NODE}. Run mount-ssd.sh first."

  say "WARNING: existing registry data (pushed images) will be deleted."
  echo "  The registry secrets (TLS + auth) are preserved."
  echo "  Re-push any images you need after this step."
  if (( YES )); then
    say "--yes: skipping confirmation."
  else
    echo
    echo "Press Enter to continue or Ctrl-C to abort."
    read -r < /dev/tty
  fi

  say "Uninstalling current registry Helm release (deletes Deployment + PVC)…"
  helm uninstall registry -n registry --wait --timeout=120s

  # Confirm PVC is gone before reinstalling
  local retries=0
  while kubectl get pvc registry-data -n registry &>/dev/null; do
    (( retries++ < 12 )) || err "PVC registry-data still exists after 60s"
    info "Waiting for PVC to be deleted…"
    sleep 5
  done

  say "Reinstalling registry with persistence.storageClass=local-ssd…"
  helm upgrade --install registry "$(dirname "$0")/../charts/registry" \
    -n registry \
    --reuse-values \
    --set persistence.storageClass=local-ssd

  say "Waiting for registry pod to be Ready (up to 120s)…"
  kubectl wait --for=condition=ready pod \
    -l app=registry \
    -n registry \
    --timeout=120s

  say "PVC migration complete."
  info "New PVC storage class: local-ssd (backed by /mnt/ssd/ on ${SERVER_NODE})"
  kubectl get pvc registry-data -n registry
}

stage_verify() {
  say "Verifying registry with a test push/pull…"
  if (( DRY )); then
    info "[dry-run] Would docker push/pull ${REGISTRY_ADDR}/test:latest"
    return 0
  fi

  # Log in if auth is enabled (credentials file present and auth secret exists)
  local authed=0
  if [[ -f "$CREDS_FILE" ]] && kubectl get secret registry-htpasswd -n registry &>/dev/null; then
    local reg_user reg_pass
    reg_user=$(kv_get REGISTRY_USER     "$CREDS_FILE")
    reg_pass=$(kv_get REGISTRY_PASSWORD "$CREDS_FILE")
    if [[ -n "$reg_user" && -n "$reg_pass" ]]; then
      info "Auth detected — logging in to ${REGISTRY_ADDR}…"
      echo "$reg_pass" | docker login "$REGISTRY_ADDR" -u "$reg_user" --password-stdin
      authed=1
    fi
  fi

  local test_image="${REGISTRY_ADDR}/test:latest"
  info "Pulling a small image to use as test payload…"
  docker pull alpine:latest
  docker tag alpine:latest "$test_image"

  info "Pushing ${test_image}…"
  docker push "$test_image"

  info "Pulling back ${test_image}…"
  docker pull "$test_image"

  info "Cleaning up local test tag…"
  docker rmi "$test_image" || true

  (( authed )) && docker logout "$REGISTRY_ADDR" || true

  say "Verify: OK — registry at ${REGISTRY_ADDR} is working."
}

# ---- run stages -------------------------------------------------------------

(( DO_CERTS      )) && stage_prereqs
(( DO_CERTS      )) && stage_certs
(( DO_STOP_OLD   )) && stage_stop_old
(( DO_NAMESPACE  )) && stage_namespace
(( DO_TLS_SECRET )) && stage_tls_secret
(( DO_HELM       )) && stage_helm_install
(( DO_WAIT       )) && stage_wait_pod
(( DO_CA         )) && stage_ca_distribute
(( DO_LAPTOP     )) && stage_laptop_docker_trust
(( DO_AUTH        )) && stage_enable_auth
(( DO_MIGRATE_PVC )) && stage_migrate_pvc
(( DO_VERIFY      )) && stage_verify

say "Done."
