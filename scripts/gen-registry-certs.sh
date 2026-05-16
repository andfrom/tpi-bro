#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="./bootstrap-config.kv"

while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

kv_get() { grep -E "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }
ip_add()  { local p="${1%.*}" l="${1##*.}"; echo "${p}.$((l + $2))"; }

TPI_BASE=""
SERVER_IDX=1
if [[ -f "$CONFIG_FILE" ]]; then
  TPI_BASE=$(kv_get TPI_BASE_IP_ADDR "$CONFIG_FILE")
  _idx=$(kv_get SERVER_NODE_IDX "$CONFIG_FILE")
  [[ -n "$_idx" ]] && SERVER_IDX="$_idx"
  CERT_DIR_CFG=$(kv_get CERT_DIR "$CONFIG_FILE")
  REG_SAN_IP_CFG=$(kv_get REG_SAN_IP "$CONFIG_FILE")
  REG_SAN_DNS_CFG=$(kv_get REG_SAN_DNS "$CONFIG_FILE")
fi

CERT_DIR="${CERT_DIR_CFG:-./registry-certs}"

if [[ -n "${REG_SAN_DNS_CFG:-}" ]]; then
  REG_SAN_DNS=("$REG_SAN_DNS_CFG")
else
  REG_SAN_DNS=("rk1-node${SERVER_IDX}")
fi

if [[ -n "${REG_SAN_IP_CFG:-}" ]]; then
  # Space-separated list supported: REG_SAN_IP=192.168.1.11 <node1-tailscale-ip>
  read -ra REG_SAN_IP <<< "$REG_SAN_IP_CFG"
elif [[ -n "$TPI_BASE" ]]; then
  REG_SAN_IP=("$(ip_add "$TPI_BASE" "$SERVER_IDX")")
else
  REG_SAN_IP=()
fi

DAYS_CA=3650
DAYS_SRV=825

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo "==> Generating local CA (if missing)…"
[[ -f myCA.key ]] || openssl genrsa -out myCA.key 4096
[[ -f myCA.crt ]] || openssl req -x509 -new -nodes -key myCA.key -sha256 -days "$DAYS_CA" -out myCA.crt \
  -subj "/C=US/ST=Local/L=LAN/O=MyLab/OU=Dev/CN=my-local-CA"

echo "==> Building OpenSSL SAN config…"
{
  cat <<'EOF'
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
C  = US
ST = Local
L  = LAN
O  = MyLab
OU = Dev
CN = local-registry

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
EOF

  i=1
  for dns in "${REG_SAN_DNS[@]}"; do
    echo "DNS.$i = ${dns}"
    i=$((i+1))
  done
  j=1
  for ip in "${REG_SAN_IP[@]}"; do
    echo "IP.$j  = ${ip}"
    j=$((j+1))
  done
} > registry.cnf

echo "==> Creating server key + CSR…"
openssl genrsa -out registry.key 2048
openssl req -new -key registry.key -out registry.csr -config registry.cnf

echo "==> Signing server cert with the local CA…"
openssl x509 -req -in registry.csr -CA myCA.crt -CAkey myCA.key -CAcreateserial \
  -out registry.crt -days "$DAYS_SRV" -sha256 -extfile registry.cnf -extensions req_ext

echo "==> Done."
echo "Artifacts:"
ls -1 myCA.crt myCA.key registry.crt registry.key registry.cnf
echo
echo "NEXT:"
echo "1) Laptop Docker trust (pick one SAN you'll use, e.g. IP:5000):"
[[ ${#REG_SAN_IP[@]} -gt 0 ]] && RADDR="${REG_SAN_IP[0]}:5000" || RADDR="${REG_SAN_DNS[0]}:5000"
echo "   sudo mkdir -p /etc/docker/certs.d/${RADDR}"
echo "   sudo cp myCA.crt /etc/docker/certs.d/${RADDR}/ca.crt"
echo "   sudo systemctl restart docker"
echo
echo "2) Create TLS secret in cluster (namespace 'registry'):"
echo "   kubectl -n registry create secret tls registry-tls --cert=registry.crt --key=registry.key"
echo
echo "3) Create htpasswd secret (if using basic auth):"
echo "   htpasswd -Bbn push 'S3cret!' > htpasswd"
echo "   kubectl -n registry create secret generic registry-htpasswd --from-file=htpasswd=./htpasswd"
echo
echo "4) Install CA on each node + containerd config (see install-ca.sh helper)."
