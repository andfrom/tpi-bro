#!/usr/bin/env bash
# B-04: Install Flux and point it at this repo's gitops/ directory.
#
# Scripted form of the procedure described in gitops/README.md:
#   1. `flux install`                    — the controllers (idempotent)
#   2. git auth secret in flux-system    — read-only SSH deploy key
#   3. `kubectl apply -f gitops/flux-system/gotk-sync.yaml`
#
# The repo URL is read from gotk-sync.yaml (single source of truth), and the
# secret name from the same file's secretRef.
#
# Deploy key resolution, in order:
#   1. --key FILE
#   2. GITOPS_DEPLOY_KEY=<path> in ~/.turingpi/credentials.kv
#   3. ~/.turingpi/gitops-deploy-key   (generated here if absent)
# If the key was just generated, the public half must be added as a
# read-only deploy key on the Git host before Flux can sync — the script
# prints the key and the verify step polls until the sync succeeds.
#
# Usage:
#   ./install-gitops.sh                 # install + secret + sync manifest
#   ./install-gitops.sh --verify        # wait for GitRepository/Kustomization Ready
#   ./install-gitops.sh --key FILE      # explicit deploy key
#   ./install-gitops.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GOTK_SYNC="${SCRIPT_DIR}/../gitops/flux-system/gotk-sync.yaml"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
DEFAULT_KEY="${HOME}/.turingpi/gitops-deploy-key"
KEY_FILE=""
DRY=0
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --key)     KEY_FILE="$2"; shift 2 ;;
    --dry-run) DRY=1;         shift   ;;
    --verify)  DO_VERIFY=1;   shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
say()     { echo "==> $*"; }
info()    { echo "    $*"; }
err()     { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$GOTK_SYNC" ]] || err "Sync manifest not found: ${GOTK_SYNC}"

# Repo URL + secret name from the sync manifest — single source of truth.
REPO_URL=$(grep -E '^\s*url:' "$GOTK_SYNC" | head -1 | awk '{print $2}')
SECRET_NAME=$(grep -A1 'secretRef:' "$GOTK_SYNC" | grep 'name:' | head -1 | awk '{print $2}')
[[ -n "$REPO_URL"    ]] || err "Could not read spec.url from ${GOTK_SYNC}"
[[ -n "$SECRET_NAME" ]] || err "Could not read secretRef.name from ${GOTK_SYNC}"

# ── verify mode ───────────────────────────────────────────────────────────────

if (( DO_VERIFY )); then
  say "Waiting for Flux to sync (GitRepository + Kustomization Ready, up to 120s)…"
  ok=1
  kubectl wait --for=condition=Ready gitrepository/flux-system \
    -n flux-system --timeout=120s || ok=0
  kubectl wait --for=condition=Ready kustomization/flux-system \
    -n flux-system --timeout=60s || ok=0
  if (( ! ok )); then
    echo
    err "Flux is not syncing. Most common cause on first install: the deploy
       key isn't registered on the Git host yet. Public key:
         $(cat "${DEFAULT_KEY}.pub" 2>/dev/null || echo '<no generated key found>')
       Add it as a READ-ONLY deploy key for ${REPO_URL}, then re-run --verify."
  fi
  say "Flux is syncing ${REPO_URL}."
  exit 0
fi

# ── preflight ─────────────────────────────────────────────────────────────────

command -v flux >/dev/null 2>&1 || err "flux CLI not found — install from https://fluxcd.io/flux/installation/"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

if (( DRY )); then
  say "Dry-run: GitOps (B-04)"
  info "[dry-run] Would: flux install  (idempotent; skipped if controllers Ready)"
  info "[dry-run] Would: ensure secret '${SECRET_NAME}' in flux-system (deploy key)"
  info "[dry-run] Would: kubectl apply -f ${GOTK_SYNC}  (repo: ${REPO_URL})"
  exit 0
fi

# ── 1. controllers ────────────────────────────────────────────────────────────

if kubectl get deploy source-controller -n flux-system >/dev/null 2>&1; then
  info "Flux controllers already installed — skipping flux install."
else
  say "Installing Flux controllers…"
  flux install
fi

# ── 2. git auth secret ────────────────────────────────────────────────────────

if kubectl get secret "$SECRET_NAME" -n flux-system >/dev/null 2>&1; then
  info "Secret '${SECRET_NAME}' already exists — leaving it untouched."
else
  # Resolve the deploy key
  if [[ -z "$KEY_FILE" ]]; then
    KEY_FILE=$(kv_get GITOPS_DEPLOY_KEY "$CREDS_FILE")
  fi
  if [[ -z "$KEY_FILE" ]]; then
    KEY_FILE="$DEFAULT_KEY"
    if [[ ! -f "$KEY_FILE" ]]; then
      say "No deploy key configured — generating one at ${KEY_FILE}…"
      ssh-keygen -t ed25519 -N "" -C "tpi-bro-flux-deploy-key" -f "$KEY_FILE" >/dev/null
      echo
      echo "============================================================"
      echo "ACTION REQUIRED — register the deploy key on the Git host:"
      echo "  Repo: ${REPO_URL}"
      echo "  Add this as a READ-ONLY deploy key:"
      echo
      cat "${KEY_FILE}.pub"
      echo "============================================================"
      echo
    fi
  fi
  [[ -f "$KEY_FILE" ]] || err "Deploy key not found: ${KEY_FILE}"

  say "Creating git auth secret '${SECRET_NAME}'…"
  flux create secret git "$SECRET_NAME" \
    --url="$REPO_URL" \
    --private-key-file="$KEY_FILE"
fi

# ── 3. sync manifest ──────────────────────────────────────────────────────────

say "Applying sync manifest…"
kubectl apply -f "$GOTK_SYNC"

say "Done. Flux will reconcile ${REPO_URL} (branch per gotk-sync.yaml)."
info "Verify with: ./install-gitops.sh --verify"
info "(If the deploy key was just generated, register it first — see above.)"
