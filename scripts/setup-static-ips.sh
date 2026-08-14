#!/usr/bin/env bash
# Configures static IPs on all 4 RK1 nodes (via netplan) and the BMC (via
# ifupdown on its BusyBox/UBIFS overlay).
#
# IPs are derived from TPI_BASE_IP_ADDR in bootstrap-config.kv:
#   BMC       = base + 0   (the base address itself)
#   rk1-nodeN = base + N   (base+1 … base+4)
#
# Example: TPI_BASE_IP_ADDR=<your-base-ip>
#   BMC=base, node1=base+1, node2=base+2, node3=base+3, node4=base+4
#
# Usage:
#   ./setup-static-ips.sh                  # configure BMC + all nodes
#   ./setup-static-ips.sh --nodes-only     # configure nodes only
#   ./setup-static-ips.sh --bmc-only       # configure BMC only
#   ./setup-static-ips.sh --verify         # reboot nodes + assert static IPs persist
#   ./setup-static-ips.sh [--state FILE] [--config FILE]

set -euo pipefail

STATE_FILE="./bootstrap-state.kv"
CONFIG_FILE="./bootstrap-config.kv"
DO_NODES=1
DO_BMC=1
DO_VERIFY=0
DRY=0
YES=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --state)      STATE_FILE="$2";  shift 2 ;;
    --config)     CONFIG_FILE="$2"; shift 2 ;;
    --nodes-only) DO_BMC=0;         shift   ;;
    --bmc-only)   DO_NODES=0;       shift   ;;
    --verify)     DO_VERIFY=1; DO_NODES=0; DO_BMC=0; shift ;;
    --dry-run)    DRY=1;            shift   ;;
    --yes)        YES=1;            shift   ;;
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

say()  { echo "==> $*"; }
info() { echo "    $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

# Increment the last octet of an IPv4 address by N.
ip_add() {
  local base="$1" n="$2"
  local prefix="${base%.*}"
  local last="${base##*.}"
  echo "${prefix}.$((last + n))"
}

poll_ssh() {
  local user="$1" pass="$2" ip="$3" timeout_s="$4"
  local deadline
  deadline=$(( $(date +%s) + timeout_s ))
  while (( $(date +%s) < deadline )); do
    sleep 3
    if sshpass -p "$pass" ssh \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=5 \
         "$user@$ip" hostname &>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ---- prerequisites ----------------------------------------------------------

if ! command -v sshpass &>/dev/null; then
  say "Installing sshpass…"
  sudo apt-get install -y sshpass
fi

# ---- read config + state ----------------------------------------------------

[[ -f "$CONFIG_FILE" ]] || err "Config file not found: $CONFIG_FILE"
[[ -f "$STATE_FILE"  ]] || err "State file not found: $STATE_FILE"

TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
GATEWAY=$(kv_get GATEWAY "$CONFIG_FILE")
DNS_SERVERS=$(kv_get DNS_SERVERS "$CONFIG_FILE")
NODE_USER=$(kv_get DEFAULT_USER "$CONFIG_FILE")
BMC_PASS_CFG=$(kv_get BMC_PASS "$CONFIG_FILE")
NODE_PASS_CFG=$(kv_get NEW_PASS "$CONFIG_FILE")

[[ -n "$TPI_BASE"    ]] || err "TPI_BASE_IP_ADDR not set in $CONFIG_FILE"
[[ -n "$GATEWAY"     ]] || err "GATEWAY not set in $CONFIG_FILE"
[[ -n "$DNS_SERVERS" ]] || err "DNS_SERVERS not set in $CONFIG_FILE"
[[ -n "$NODE_USER"   ]] || NODE_USER=ubuntu

BMC_NEW_IP="$TPI_BASE"
declare -A NODE_NEW_IP=(
  [rk1-node1]="$(ip_add "$TPI_BASE" 1)"
  [rk1-node2]="$(ip_add "$TPI_BASE" 2)"
  [rk1-node3]="$(ip_add "$TPI_BASE" 3)"
  [rk1-node4]="$(ip_add "$TPI_BASE" 4)"
)

# ---- show plan + prompt for passwords ---------------------------------------

say "IP assignment plan (base: $TPI_BASE):"
if (( DO_BMC )); then
  bmc_cur=$(kv_get bmc_ip "$STATE_FILE")
  info "BMC (br0, BusyBox/UBIFS):  $bmc_cur  →  $BMC_NEW_IP"
fi
if (( DO_NODES )); then
  for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
    cur=$(kv_get "$node" "$STATE_FILE")
    info "$node (netplan):           $cur  →  ${NODE_NEW_IP[$node]}"
  done
fi
echo

if (( DRY )); then
  say "Dry-run: no changes made."
  exit 0
fi

if (( ! YES )); then
  echo "Press Enter to continue or Ctrl-C to abort."
  read -r
fi

if (( DO_BMC )); then
  if [[ -n "$BMC_PASS_CFG" ]]; then
    BMC_PASS="$BMC_PASS_CFG"
    info "BMC password read from config."
  else
    echo -n "BMC root password: "
    read -rs BMC_PASS
    echo
  fi
fi
if (( DO_NODES )); then
  if [[ -n "$NODE_PASS_CFG" ]]; then
    NODE_PASS="$NODE_PASS_CFG"
    info "Node password read from config (NEW_PASS)."
  else
    echo -n "Node password (NEW_PASS set during Phase A): "
    read -rs NODE_PASS
    echo
  fi
fi
echo

# ---- BMC static IP ----------------------------------------------------------

configure_bmc() {
  local cur_ip="$1"
  say "Configuring BMC: $cur_ip  →  $BMC_NEW_IP"

  # The BMC network is a Linux bridge (br0) over DSA switch ports.
  # Replace the DHCP stanza with a static one; keep bridge-ports and pre-up hook.
  # The 'hostname $(hostname)' line is dhcp-client-only — dropped for static.
  local new_interfaces
  new_interfaces=$(cat <<EOF
# interface file auto-generated by buildroot

auto lo
iface lo inet loopback

auto br0
iface br0 inet static
  address ${BMC_NEW_IP}
  netmask 255.255.255.0
  gateway ${GATEWAY}
  bridge-ports node1 node2 node3 node4 ge0 ge1
  pre-up /etc/network/nfs_check
  wait-delay 15
EOF
)

  local new_resolv
  new_resolv=$(printf 'nameserver %s\n' $DNS_SERVERS)

  # Write configs, then schedule ifdown/ifup in background so this SSH session
  # exits cleanly before the IP changes.  bridge wait-delay 15 means ~15s before
  # the interface is fully up after ifup.
  sshpass -p "$BMC_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "root@$cur_ip" \
    "cat > /etc/network/interfaces <<'IFACES'
${new_interfaces}
IFACES
cat > /etc/resolv.conf <<'RESOLV'
${new_resolv}
RESOLV
nohup sh -c 'sleep 2 && ifdown br0 && ifup br0' >/tmp/ifup.log 2>&1 &
echo IFUP_QUEUED" 2>/dev/null || {
    echo "  WARN: could not SSH to BMC at $cur_ip"
    return 1
  }

  info "ifdown/ifup queued — waiting for BMC at $BMC_NEW_IP (up to 60s)…"
  if poll_ssh root "$BMC_PASS" "$BMC_NEW_IP" 60; then
    info "OK — BMC is live at $BMC_NEW_IP"
    return 0
  else
    echo "  WARN: BMC did not respond at $BMC_NEW_IP within 60s"
    echo "  Check: ssh root@$BMC_NEW_IP and review /tmp/ifup.log"
    return 1
  fi
}

# ---- node static IP ---------------------------------------------------------

configure_node() {
  local node="$1"
  local cur_ip="$2"
  local new_ip="${NODE_NEW_IP[$node]}"

  say "Configuring $node: $cur_ip  →  $new_ip"

  # Detect the primary ethernet interface (first non-loopback)
  local iface
  iface=$(sshpass -p "$NODE_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "$NODE_USER@$cur_ip" \
    "ip -o link show | awk -F': ' '\$2 != \"lo\" {print \$2; exit}'" 2>/dev/null) || {
      echo "  WARN: could not SSH to $node at $cur_ip — skipping"
      return 1
    }
  iface="${iface%%@*}"
  info "Ethernet interface: $iface"

  # /etc/netplan/99-static.yaml — priority 99 overrides cloud-init's
  # 50-cloud-init.yaml which enables DHCP.
  local dns_yaml
  dns_yaml=$(printf '%s, ' $DNS_SERVERS)
  dns_yaml="[${dns_yaml%, }]"

  local netplan_yaml
  netplan_yaml=$(cat <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${new_ip}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: ${dns_yaml}
EOF
)

  sshpass -p "$NODE_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "$NODE_USER@$cur_ip" \
    "tee /tmp/99-static.yaml >/dev/null <<'YAML'
${netplan_yaml}
YAML
echo '$NODE_PASS' | sudo -S mv /tmp/99-static.yaml /etc/netplan/99-static.yaml
echo '$NODE_PASS' | sudo -S chmod 600 /etc/netplan/99-static.yaml
echo '$NODE_PASS' | sudo -S rm -f /etc/netplan/50-cloud-init.yaml
printf 'network: {config: disabled}\n' > /tmp/99-disable-network.cfg
echo '$NODE_PASS' | sudo -S mkdir -p /etc/cloud/cloud.cfg.d
echo '$NODE_PASS' | sudo -S mv /tmp/99-disable-network.cfg /etc/cloud/cloud.cfg.d/99-disable-network.cfg
echo '$NODE_PASS' | sudo -S systemd-run --no-block --unit=netplan-static-ip bash -c 'sleep 2 && netplan apply'
echo NETPLAN_QUEUED" 2>/dev/null || true

  info "netplan apply queued — waiting for $node at $new_ip (up to 120s)…"
  if poll_ssh "$NODE_USER" "$NODE_PASS" "$new_ip" 120; then
    info "OK — $node is live at $new_ip"
    return 0
  else
    echo "  WARN: $node did not respond at $new_ip within 60s — check manually"
    return 1
  fi
}

# ---- verify (reboot + assert) -----------------------------------------------

verify_nodes() {
  say "Rebooting all nodes to verify static IP persistence…"

  if [[ -n "$NODE_PASS_CFG" ]]; then
    NODE_PASS="$NODE_PASS_CFG"
    info "Node password read from config (NEW_PASS)."
  else
    echo -n "Node password: "
    read -rs NODE_PASS
    echo
  fi
  echo

  # Issue reboots in parallel; ignore errors (session drops when node reboots)
  for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
    local new_ip="${NODE_NEW_IP[$node]}"
    info "Rebooting $node ($new_ip)…"
    sshpass -p "$NODE_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      "$NODE_USER@$new_ip" \
      "echo '$NODE_PASS' | sudo -S reboot" 2>/dev/null || true &
  done
  wait
  echo

  info "Waiting 20s for nodes to go down…"
  sleep 20

  say "Polling all nodes in parallel…"
  local tmpdir
  tmpdir=$(mktemp -d)

  for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
    local new_ip="${NODE_NEW_IP[$node]}"
    (
      if poll_ssh "$NODE_USER" "$NODE_PASS" "$new_ip" 120; then
        echo "OK" > "$tmpdir/$node"
      else
        echo "FAIL" > "$tmpdir/$node"
      fi
    ) &
  done
  wait

  local failed=()
  for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
    local new_ip="${NODE_NEW_IP[$node]}"
    local result
    result=$(cat "$tmpdir/$node" 2>/dev/null || echo "FAIL")
    if [[ "$result" == "OK" ]]; then
      info "OK — $node is live at ${new_ip} after reboot"
    else
      echo "  FAIL: $node did not come back at $new_ip"
      failed+=("$node")
    fi
  done
  rm -rf "$tmpdir"

  echo
  if [[ ${#failed[@]} -eq 0 ]]; then
    say "PASS — all nodes returned at their static IPs after reboot."
  else
    echo "FAIL: ${failed[*]} did not return at expected IPs."
    echo "Check netplan config on each node: sudo cat /etc/netplan/99-static.yaml"
    exit 1
  fi
}

# ---- run --------------------------------------------------------------------

if (( DO_VERIFY )); then
  verify_nodes
  exit 0
fi

FAILED=()

if (( DO_BMC )); then
  bmc_cur=$(kv_get bmc_ip "$STATE_FILE")
  configure_bmc "$bmc_cur" || FAILED+=(bmc)
  echo
fi

if (( DO_NODES )); then
  for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
    cur=$(kv_get "$node" "$STATE_FILE")
    [[ -n "$cur" ]] || err "No IP found for $node in $STATE_FILE"
    configure_node "$node" "$cur" || FAILED+=("$node")
    echo
  done
fi

# ---- update state file + /etc/hosts ----------------------------------------

if [[ ${#FAILED[@]} -eq 0 ]]; then
  say "All targets configured. Updating $STATE_FILE and /etc/hosts…"

  if (( DO_BMC )); then
    kv_set bmc_ip "$BMC_NEW_IP" "$STATE_FILE"
    if grep -q "turingpi" /etc/hosts; then
      sudo sed -i "s|.*turingpi.*|${BMC_NEW_IP}  turingpi|" /etc/hosts
    else
      echo "${BMC_NEW_IP}  turingpi" | sudo tee -a /etc/hosts >/dev/null
    fi
  fi

  if (( DO_NODES )); then
    for node in rk1-node1 rk1-node2 rk1-node3 rk1-node4; do
      new_ip="${NODE_NEW_IP[$node]}"
      kv_set "$node" "$new_ip" "$STATE_FILE"
      if grep -q "$node" /etc/hosts; then
        sudo sed -i "s|.*\b${node}\b.*|${new_ip}  ${node}|" /etc/hosts
      else
        echo "${new_ip}  ${node}" | sudo tee -a /etc/hosts >/dev/null
      fi
    done
  fi

  say "Done. Proceed with Phase B0 (SSH key distribution)."
else
  echo
  echo "WARNING: The following targets were not updated: ${FAILED[*]}"
  echo "Fix them and re-run (use --bmc-only or --nodes-only to retry a subset)."
  exit 1
fi
