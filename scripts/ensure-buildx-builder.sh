#!/usr/bin/env bash
# Idempotently create the tpi-bro-builder buildx builder used to cross-build
# ARM64 images from an x86_64 laptop. Documented pattern (DEPLOYING-AN-AGENT.md)
# turned into runnable code so it isn't copy-pasted/rediscovered per-project.
#
# --driver-opt network=host: without this, the builder container gets its own
# isolated network namespace and can inherit a stale DNS server baked in at
# creation time (see commit 8dce3d7).
#
# Deliberately does NOT configure registry CA trust for the builder itself —
# build with --load (into the host Docker daemon, which already trusts the
# registry CA from Phase B) and push with plain `docker push`, rather than
# buildx's own --push. That sidesteps buildx's isolated build container
# needing its own separate CA trust configuration entirely.
#
# Usage:
#   ./scripts/ensure-buildx-builder.sh               # create if missing, use it
#   ./scripts/ensure-buildx-builder.sh --name NAME    # override builder name

set -euo pipefail

BUILDER_NAME="tpi-bro-builder"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) BUILDER_NAME="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if docker buildx inspect "$BUILDER_NAME" &>/dev/null; then
  echo "==> Builder '${BUILDER_NAME}' already exists."
else
  echo "==> Creating buildx builder '${BUILDER_NAME}' (network=host)…"
  docker buildx create --name "$BUILDER_NAME" --driver docker-container \
    --driver-opt network=host --bootstrap
fi

docker buildx use "$BUILDER_NAME"
echo "==> Active builder: ${BUILDER_NAME}"
echo "    Build with --load (not --push) so the push step uses the host"
echo "    Docker daemon's existing registry CA trust:"
echo "      docker buildx build --builder ${BUILDER_NAME} --platform linux/arm64 \\"
echo "        --tag rk1-node1:5000/YOUR_IMAGE:latest --load ."
echo "      docker push rk1-node1:5000/YOUR_IMAGE:latest"
