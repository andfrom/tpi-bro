#!/usr/bin/env bash
# Suite 4 — Live cluster health checks.
# Requires: kubectl configured, cluster running, bootstrap-config.kv present.
#
# Usage:
#   ./tests/check-cluster.sh
#   ./tests/check-cluster.sh --quick          # skip per-node pod pull tests
#   ./tests/check-cluster.sh --config FILE    # override config file
#   ./tests/check-cluster.sh --creds FILE     # override credentials file

set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG_FILE="./bootstrap-config.kv"
CREDS_FILE="${HOME}/.turingpi/credentials.kv"
QUICK=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --creds)  CREDS_FILE="$2";  shift 2 ;;
    --quick)  QUICK=1; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0

pass() { echo -e "  ${GREEN}PASS${NC} [$1]"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC} [$1]: $2"; ((FAIL++)); }
skip() { echo -e "  ${YELLOW}SKIP${NC} [$1]: $2"; ((SKIP++)); }

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ip_add()  { local p="${1%.*}" l="${1##*.}"; echo "${p}.$((l + $2))"; }

# ── load config ──────────────────────────────────────────────────────────────

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config not found: $CONFIG_FILE"; exit 1; }

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
SERVER_IDX=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE"); SERVER_IDX="${SERVER_IDX:-1}"
NODE_COUNT=$(kv_get NODE_COUNT      "$CONFIG_FILE"); NODE_COUNT="${NODE_COUNT:-4}"
CERT_DIR_CFG=$(kv_get CERT_DIR      "$CONFIG_FILE"); CERT_DIR="${CERT_DIR_CFG:-./registry-certs}"

[[ -n "$TPI_BASE" ]] || { echo "ERROR: TPI_BASE_IP_ADDR not set in $CONFIG_FILE"; exit 1; }

SERVER_IP=$(ip_add "$TPI_BASE" "$SERVER_IDX")
REGISTRY_ADDR="rk1-node${SERVER_IDX}:5000"

REG_USER=""; REG_PASS=""
if [[ -f "$CREDS_FILE" ]]; then
  REG_USER=$(kv_get REGISTRY_USER     "$CREDS_FILE")
  REG_PASS=$(kv_get REGISTRY_PASSWORD "$CREDS_FILE")
fi

# ── prereq: kubectl reachable ─────────────────────────────────────────────────

echo ""
echo "Suite 4 — Cluster Health Checks"
echo "─────────────────────────────────"

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster. Is ~/.kube/config set up?"
  exit 1
fi

# ── C01: all nodes Ready ──────────────────────────────────────────────────────

echo ""
echo "Cluster"

nodes_output=$(kubectl get nodes --no-headers 2>/dev/null)
total=$(echo "$nodes_output" | grep -c "" || true)
not_ready=$(echo "$nodes_output" | grep -vc " Ready" || true)

if [[ "$total" -eq "$NODE_COUNT" && "$not_ready" -eq 0 ]]; then
  pass "C01 all-${NODE_COUNT}-nodes-ready"
else
  fail "C01 all-${NODE_COUNT}-nodes-ready" "${total}/${NODE_COUNT} nodes found, ${not_ready} not Ready"
fi

# ── C02: registry pod Running ─────────────────────────────────────────────────

echo ""
echo "Registry"

pod_phase=$(kubectl get pod -n registry -l app=registry --no-headers 2>/dev/null \
  | awk '{print $3}' | head -1)
if [[ "$pod_phase" == "Running" ]]; then
  pass "C02 registry-pod-running"
else
  fail "C02 registry-pod-running" "phase=${pod_phase:-not found}"
fi

# ── C03: CA cert present on laptop ───────────────────────────────────────────

if [[ -f "${CERT_DIR}/myCA.crt" ]]; then
  pass "C03 ca-cert-present"
  CA_OK=1
else
  fail "C03 ca-cert-present" "${CERT_DIR}/myCA.crt not found"
  CA_OK=0
fi

# ── C04: registry HTTPS (401 = TLS OK + auth required; 200 = TLS OK, no auth) ─

if (( CA_OK )); then
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --cacert "${CERT_DIR}/myCA.crt" --max-time 5 \
    "https://${SERVER_IP}:5000/v2/" 2>/dev/null)
  if [[ "$http_code" == "401" || "$http_code" == "200" ]]; then
    pass "C04 registry-tls (HTTP ${http_code})"
  else
    fail "C04 registry-tls" "expected 401 or 200, got ${http_code:-no response}"
  fi
else
  skip "C04 registry-tls" "CA cert missing (C03 failed)"
fi

# ── C05: registry auth (200 with credentials) ─────────────────────────────────

if [[ -z "$REG_USER" || -z "$REG_PASS" ]]; then
  skip "C05 registry-auth" "no credentials in ${CREDS_FILE}"
elif (( ! CA_OK )); then
  skip "C05 registry-auth" "CA cert missing"
else
  auth_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --cacert "${CERT_DIR}/myCA.crt" --max-time 5 \
    -u "${REG_USER}:${REG_PASS}" \
    "https://${SERVER_IP}:5000/v2/" 2>/dev/null)
  if [[ "$auth_code" == "200" ]]; then
    pass "C05 registry-auth"
  else
    fail "C05 registry-auth" "expected 200, got ${auth_code:-no response}"
  fi
fi

# ── C06: push health-check image + verify catalog ────────────────────────────

PUSH_OK=0
TEST_IMAGE="${REGISTRY_ADDR}/health-check:latest"

if [[ -z "$REG_USER" || -z "$REG_PASS" ]]; then
  skip "C06 registry-push" "no credentials"
elif (( ! CA_OK )); then
  skip "C06 registry-push" "CA cert missing"
else
  login_ok=0
  echo "$REG_PASS" | docker login "$REGISTRY_ADDR" -u "$REG_USER" --password-stdin &>/dev/null \
    && login_ok=1

  if (( ! login_ok )); then
    fail "C06 registry-push" "docker login failed"
  else
    push_ok=0
    docker pull alpine:latest &>/dev/null
    docker tag alpine:latest "$TEST_IMAGE"
    docker push "$TEST_IMAGE" &>/dev/null && push_ok=1
    docker rmi "$TEST_IMAGE" &>/dev/null || true
    docker logout "$REGISTRY_ADDR" &>/dev/null || true

    if (( ! push_ok )); then
      fail "C06 registry-push" "docker push failed"
    else
      catalog=$(curl -s --cacert "${CERT_DIR}/myCA.crt" --max-time 5 \
        -u "${REG_USER}:${REG_PASS}" \
        "https://${SERVER_IP}:5000/v2/_catalog" 2>/dev/null)
      if echo "$catalog" | grep -q "health-check"; then
        pass "C06 registry-push"
        PUSH_OK=1
      else
        fail "C06 registry-push" "image not in catalog after push"
      fi
    fi
  fi
fi

# ── C07+: per-node pod pull ───────────────────────────────────────────────────

echo ""
echo "Per-node image pull"

for (( i=1; i<=NODE_COUNT; i++ )); do
  node="rk1-node${i}"
  pod="hc-node-${i}"
  check=$(printf "C%02d pod-pull-%s" $((6 + i)) "$node")

  if (( QUICK )); then
    skip "$check" "--quick flag set"
    continue
  fi

  if (( ! PUSH_OK )); then
    skip "$check" "registry push (C06) failed or skipped"
    continue
  fi

  kubectl delete pod "$pod" --ignore-not-found &>/dev/null

  overrides='{"spec":{"nodeName":"'"${node}"'"}}'
  kubectl run "$pod" \
    --image="${TEST_IMAGE}" \
    --restart=Never \
    --overrides="$overrides" &>/dev/null

  # We care about the image pull, not the container exit code.
  # Wait up to 60s for either "Successfully pulled" or a pull failure event.
  pulled=0
  pull_err=""
  deadline=$(( $(date +%s) + 60 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    events=$(kubectl describe pod "$pod" 2>/dev/null)
    if echo "$events" | grep -q "Successfully pulled"; then
      pulled=1; break
    fi
    if echo "$events" | grep -qE "ImagePullBackOff|ErrImagePull|failed to pull"; then
      pull_err=$(echo "$events" | grep -E "ImagePullBackOff|ErrImagePull|failed to pull" | head -1)
      break
    fi
    sleep 2
  done

  kubectl delete pod "$pod" --ignore-not-found &>/dev/null

  if (( pulled )); then
    pass "$check"
  else
    fail "$check" "${pull_err:-pull timed out or no events}"
  fi
done

# ── C11–C14: B-09 storage checks ─────────────────────────────────────────────

echo ""
echo "Storage (B-09)"

sc_provisioner=$(kubectl get sc local-ssd -o jsonpath='{.provisioner}' 2>/dev/null || echo "")
sc_binding=$(kubectl get sc local-ssd -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "")
if [[ "$sc_provisioner" == "rancher.io/local-path-ssd" && "$sc_binding" == "WaitForFirstConsumer" ]]; then
  pass "C11 local-ssd-storageclass"
else
  fail "C11 local-ssd-storageclass" "provisioner=${sc_provisioner:-not found}, bindingMode=${sc_binding:-unknown}"
fi

prov_ready=$(kubectl get deploy local-ssd-provisioner -n kube-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${prov_ready:-0}" -ge 1 ]]; then
  pass "C12 local-ssd-provisioner-ready"
else
  fail "C12 local-ssd-provisioner-ready" "readyReplicas=${prov_ready:-0}"
fi

nvme_nodes=$(kubectl get nodes -l storage.tpi-bro/nvme=true --no-headers 2>/dev/null | grep -c "" || true)
if [[ "$nvme_nodes" -ge 1 ]]; then
  pass "C13 nvme-node-label (${nvme_nodes} node(s))"
else
  fail "C13 nvme-node-label" "no nodes with storage.tpi-bro/nvme=true"
fi

pvc_sc=$(kubectl get pvc registry-data -n registry \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
if [[ "$pvc_sc" == "local-ssd" ]]; then
  pass "C14 registry-pvc-on-ssd"
else
  fail "C14 registry-pvc-on-ssd" "storageClass=${pvc_sc:-not found}"
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────"
TOTAL=$(( PASS + FAIL + SKIP ))
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} of ${TOTAL} checks"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
