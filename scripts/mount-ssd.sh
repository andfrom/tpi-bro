#!/usr/bin/env bash
# B-09: Format and mount NVMe SSDs on cluster nodes; deploy local-ssd StorageClass.
#
# Nodes with /dev/nvme0n1 get:
#   - GPT partition table + single ext4 partition on nvme0n1p1
#   - /mnt/ssd mounted (UUID-based fstab entry, noatime)
#   - Entry in the local-ssd-config ConfigMap nodePathMap
#
# Nodes without NVMe (e.g. node4) are silently skipped.
#
# Usage:
#   ./mount-ssd.sh                     # detect + format + mount + storageclass
#   ./mount-ssd.sh --verify            # report mount status and StorageClass on all nodes
#   ./mount-ssd.sh --no-storageclass   # node work only; skip K8s objects
#   ./mount-ssd.sh --storageclass-only # K8s objects only; assume nodes already mounted
#   ./mount-ssd.sh --dry-run           # print actions, no changes
#   ./mount-ssd.sh [--config FILE] [--state FILE]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../bootstrap-config.kv"
STATE_FILE="${SCRIPT_DIR}/../bootstrap-state.kv"
SSH_KEY="${HOME}/.ssh/id_ed25519"
DRY=0
DO_NODES=1
DO_SC=1
DO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)           CONFIG_FILE="$2"; shift 2 ;;
    --state)            STATE_FILE="$2";  shift 2 ;;
    --dry-run)          DRY=1;            shift   ;;
    --verify)           DO_VERIFY=1; DO_NODES=0; DO_SC=0; shift ;;
    --no-storageclass)  DO_SC=0;          shift   ;;
    --storageclass-only) DO_NODES=0;      shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

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
    "ubuntu@${ip}" "$@"
}

# ---- read config ------------------------------------------------------------

[[ -f "$CONFIG_FILE" ]] || err "Config not found: $CONFIG_FILE"
[[ -f "$STATE_FILE"  ]] || err "State not found: $STATE_FILE"

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
NODE_COUNT=$(kv_get NODE_COUNT      "$CONFIG_FILE")
[[ -n "$TPI_BASE"   ]] || err "TPI_BASE_IP_ADDR not set in $CONFIG_FILE"
[[ -n "$NODE_COUNT" ]] || NODE_COUNT=4

# ---- detect which nodes have NVMe -------------------------------------------

detect_ssd_nodes() {
  say "Detecting NVMe devices on all nodes…"
  SSD_NODES=()
  SSD_IPS=()
  for (( i=1; i<=NODE_COUNT; i++ )); do
    local ip node
    ip=$(ip_add "$TPI_BASE" "$i")
    node="rk1-node${i}"
    local dev
    dev=$(node_ssh "$ip" "test -b /dev/nvme0n1 && echo present || echo absent" 2>/dev/null || echo absent)
    if [[ "$dev" == "present" ]]; then
      info "${node} (${ip}): /dev/nvme0n1 found"
      SSD_NODES+=("$node")
      SSD_IPS+=("$ip")
    else
      info "${node} (${ip}): no NVMe — skipping"
    fi
  done
  if [[ ${#SSD_NODES[@]} -eq 0 ]]; then
    err "No nodes with NVMe found. Verify SSDs are seated and nodes are reachable."
  fi
  say "SSD nodes: ${SSD_NODES[*]}"
}

# ---- format /dev/nvme0n1p1 (idempotent) ------------------------------------

format_node() {
  local node="$1" ip="$2"
  say "Formatting ${node} (${ip})…"

  if (( DRY )); then
    info "[dry-run] Would: parted -s /dev/nvme0n1 mklabel gpt mkpart primary ext4 0% 100%"
    info "[dry-run] Would: mkfs.ext4 -F /dev/nvme0n1p1"
    return 0
  fi

  local fs_type
  fs_type=$(node_ssh "$ip" "sudo blkid -s TYPE -o value /dev/nvme0n1p1 2>/dev/null || true")
  if [[ "$fs_type" == "ext4" ]]; then
    info "${node}: nvme0n1p1 already ext4 — skipping format."
    return 0
  fi

  info "${node}: creating GPT partition table and ext4 partition…"
  node_ssh "$ip" "sudo parted -s /dev/nvme0n1 mklabel gpt mkpart primary ext4 0% 100%"
  # Let udev settle so nvme0n1p1 appears
  node_ssh "$ip" "sudo udevadm settle 2>/dev/null || sleep 2"
  node_ssh "$ip" "sudo mkfs.ext4 -F /dev/nvme0n1p1"
  info "${node}: formatted."
}

# ---- mount /mnt/ssd (idempotent) --------------------------------------------

mount_node() {
  local node="$1" ip="$2"
  say "Mounting /mnt/ssd on ${node} (${ip})…"

  if (( DRY )); then
    info "[dry-run] Would: mkdir -p /mnt/ssd, fstab UUID entry, mount -a"
    return 0
  fi

  local mounted
  mounted=$(node_ssh "$ip" "mountpoint -q /mnt/ssd && echo yes || echo no")
  if [[ "$mounted" == "yes" ]]; then
    info "${node}: /mnt/ssd already mounted — skipping."
    return 0
  fi

  local uuid
  uuid=$(node_ssh "$ip" "sudo blkid -s UUID -o value /dev/nvme0n1p1")
  [[ -n "$uuid" ]] || err "${node}: could not get UUID for nvme0n1p1 — format step may have failed"

  local in_fstab
  in_fstab=$(node_ssh "$ip" "grep -q '$uuid' /etc/fstab && echo yes || echo no")

  node_ssh "$ip" "sudo mkdir -p /mnt/ssd"

  if [[ "$in_fstab" == "no" ]]; then
    info "${node}: adding fstab entry (UUID=${uuid})…"
    node_ssh "$ip" "echo 'UUID=${uuid}  /mnt/ssd  ext4  defaults,noatime  0  2' | sudo tee -a /etc/fstab > /dev/null"
  else
    info "${node}: fstab entry already present."
  fi

  node_ssh "$ip" "sudo mount -a"

  # Verify
  mounted=$(node_ssh "$ip" "mountpoint -q /mnt/ssd && echo yes || echo no")
  [[ "$mounted" == "yes" ]] || err "${node}: /mnt/ssd is not mounted after mount -a"
  info "${node}: /mnt/ssd mounted."

  # Create provisioner subdirectory now so the provisioner pod can write to it
  node_ssh "$ip" "sudo mkdir -p /mnt/ssd/local-path-provisioner && sudo chmod 777 /mnt/ssd/local-path-provisioner"
}

# ---- deploy StorageClass + provisioner --------------------------------------

deploy_storageclass() {
  say "Deploying local-ssd StorageClass and provisioner…"

  if (( DRY )); then
    info "[dry-run] Would generate ConfigMap for nodes: ${SSD_NODES[*]}"
    info "[dry-run] Would kubectl apply manifests/local-ssd-provisioner.yaml"
    return 0
  fi

  # Build nodePathMap JSON entries for each SSD node
  local node_entries=""
  for node in "${SSD_NODES[@]}"; do
    node_entries+="      {\"node\": \"${node}\", \"paths\": [\"/mnt/ssd/local-path-provisioner\"]},"$'\n'
  done
  # Strip trailing comma from last entry
  node_entries="${node_entries%,*}"$'\n'"      ${node_entries##*,}"
  # Rebuild without trailing comma cleanly using python
  local entries_json
  entries_json=$(python3 -c "
import json, sys
nodes = '${SSD_NODES[*]}'.split()
entries = [{'node': n, 'paths': ['/mnt/ssd/local-path-provisioner']} for n in nodes]
print(json.dumps({'nodePathMap': entries}, indent=2))
")

  # Apply ConfigMap
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-ssd-config
  namespace: kube-system
data:
  config.json: |
    ${entries_json//$'\n'/$'\n'    }
  helperPod.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      containers:
      - name: helper-pod
        image: "rancher/mirrored-library-busybox:1.37.0"
        imagePullPolicy: IfNotPresent
  setup: |
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "\${VOL_DIR}"
    chmod 700 "\${VOL_DIR}/.."
  teardown: |
    #!/bin/sh
    set -eu
    rm -rf "\${VOL_DIR}"
EOF

  # Apply static objects (SA, ClusterRole, ClusterRoleBinding, Deployment, StorageClass)
  local manifest="${SCRIPT_DIR}/../manifests/local-ssd-provisioner.yaml"
  [[ -f "$manifest" ]] || err "Manifest not found: ${manifest}"
  kubectl apply -f "$manifest"

  say "Waiting for local-ssd-provisioner pod to be Ready (up to 60s)…"
  kubectl rollout status deployment/local-ssd-provisioner -n kube-system --timeout=60s
  info "local-ssd StorageClass ready."
}

# ---- verify mode ------------------------------------------------------------

verify() {
  say "SSD mount status:"
  for (( i=1; i<=NODE_COUNT; i++ )); do
    local ip node
    ip=$(ip_add "$TPI_BASE" "$i")
    node="rk1-node${i}"
    local nvme mounted df_out
    nvme=$(node_ssh "$ip" "test -b /dev/nvme0n1 && echo present || echo absent" 2>/dev/null || echo unreachable)
    mounted=$(node_ssh "$ip" "mountpoint -q /mnt/ssd && echo yes || echo no" 2>/dev/null || echo unreachable)
    if [[ "$mounted" == "yes" ]]; then
      df_out=$(node_ssh "$ip" "df -h /mnt/ssd | tail -1 | awk '{print \$2\" total, \"\$4\" avail\"}'")
      info "OK  ${node} (${ip}): NVMe=${nvme}, /mnt/ssd mounted (${df_out})"
    else
      info "--- ${node} (${ip}): NVMe=${nvme}, /mnt/ssd not mounted"
    fi
  done
  echo
  say "StorageClass status:"
  kubectl get sc local-ssd 2>/dev/null || info "local-ssd StorageClass not found"
  kubectl get deploy local-ssd-provisioner -n kube-system 2>/dev/null || info "local-ssd-provisioner Deployment not found"
}

# ---- run --------------------------------------------------------------------

if (( DO_VERIFY )); then
  verify
  exit 0
fi

if (( DO_NODES )); then
  detect_ssd_nodes
  say ""
  say "This will format /dev/nvme0n1 on: ${SSD_NODES[*]}"
  say "Existing data on these disks will be DESTROYED."
  if (( DRY )); then
    say "Dry-run: no changes will be made."
  else
    echo
    echo "Press Enter to continue or Ctrl-C to abort."
    read -r
  fi

  for (( i=0; i<${#SSD_NODES[@]}; i++ )); do
    format_node "${SSD_NODES[$i]}" "${SSD_IPS[$i]}"
    mount_node  "${SSD_NODES[$i]}" "${SSD_IPS[$i]}"
    echo
  done
fi

if (( DO_SC )); then
  # If we skipped DO_NODES, we still need SSD_NODES populated
  if [[ -z "${SSD_NODES+set}" ]]; then
    detect_ssd_nodes
  fi
  deploy_storageclass
fi

say "B-09 complete."
