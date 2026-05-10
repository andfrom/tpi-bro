#!/usr/bin/env bash
set -euo pipefail

# === Edit these ===
OUT_DIR="/home/$USER/Apps/registry-certs"
# All DNS names clients might use for the registry:
REG_SAN_DNS=("rk1-node1")
# REG_SAN_DNS=("rk1-node1" "registry.home")
# All IPs clients might use for the registry (node IP, MetalLB VIP, etc.):
REG_SAN_IP=("<node1-ip>")  # add MetalLB VIP here too when available
DAYS_CA=3650      # 10 years for CA
DAYS_SRV=825      # ~27 months for server cert
# ================

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

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
echo "1) Laptop Docker trust (pick one SAN you’ll use, e.g. IP:5000):"
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



# #!/usr/bin/env bash
# set -euo pipefail

# # === Edit these to match your setup ===
# REG_HOST_DNS="rk1-node1"     # optional DNS name you might use (can be rk1-node1)
# REG_HOST_IP="<node1-ip>"     # the IP clients will use to reach the docker registry
# OUT_DIR="./registry-certs"   # where to place outputs
# DAYS_CA=3650                 # 10 years
# DAYS_SRV=825                 # ~27 months
# # =====================================

# mkdir -p "$OUT_DIR"
# cd "$OUT_DIR"

# echo "==> Generating CA key/cert (if missing)…"
# if [[ ! -f myCA.key ]]; then
#   openssl genrsa -out myCA.key 4096
# fi
# if [[ ! -f myCA.crt ]]; then
#   openssl req -x509 -new -nodes -key myCA.key -sha256 -days "$DAYS_CA" -out myCA.crt \
#     -subj "/C=US/ST=Local/L=LAN/O=MyLab/OU=Dev/CN=my-local-CA"
# fi

# echo "==> Writing OpenSSL config with SANs…"
# cat > registry.cnf <<EOF
# [ req ]
# default_bits       = 2048
# prompt             = no
# default_md         = sha256
# req_extensions     = req_ext
# distinguished_name = dn

# [ dn ]
# C  = US
# ST = Local
# L  = LAN
# O  = MyLab
# OU = Dev
# CN = ${REG_HOST_DNS}

# [ req_ext ]
# subjectAltName = @alt_names

# [ alt_names ]
# DNS.1 = ${REG_HOST_DNS}
# IP.1  = ${REG_HOST_IP}
# EOF

# echo "==> Generating registry key + CSR…"
# openssl genrsa -out registry.key 2048
# openssl req -new -key registry.key -out registry.csr -config registry.cnf

# echo "==> Signing server cert with your CA…"
# openssl x509 -req -in registry.csr -CA myCA.crt -CAkey myCA.key -CAcreateserial \
#   -out registry.crt -days "$DAYS_SRV" -sha256 -extfile registry.cnf -extensions req_ext

# echo "==> Done."
# echo
# echo "Artifacts in: $(pwd)"
# ls -1 myCA.crt myCA.key registry.crt registry.key registry.cnf
# echo
# echo "NEXT:"
# echo "  1) Laptop Docker trust:"
# echo "     sudo mkdir -p /etc/docker/certs.d/${REG_HOST_IP}:5000"
# echo "     sudo cp myCA.crt /etc/docker/certs.d/${REG_HOST_IP}:5000/ca.crt"
# echo "     sudo systemctl restart docker"
# echo
# echo "  2) Kubernetes Secret for the registry (on the cluster):"
# echo "     kubectl -n registry create secret tls registry-tls \\"
# echo "       --cert=registry.crt --key=registry.key"
# echo "     # (If the secret exists, delete or 'kubectl apply -f' your Helm-managed secret instead.)"
# echo
# echo "  3) HTPASSWD Secret (if using basic auth):"
# echo "     # generate once on laptop:  htpasswd -Bbn push 'S3cret!' > htpasswd"
# echo "     kubectl -n registry create secret generic registry-htpasswd --from-file=htpasswd=./htpasswd"
# echo
# echo "  4) Node trust + containerd config (on each RK1): see install-ca.sh helper."
