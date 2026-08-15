# ADR-0004: Local Docker Registry on rk1-node1

**Status:** Accepted — Phase B deployed 2026-05-11  
**Date:** 2026-05-09

## Context

The cluster is air-gapped from public container registries during normal operation. The laptop CI/CD pipeline builds ARM64 images that need to be pushed to the cluster. Docker Hub and GitHub Container Registry are not always accessible from the cluster's LAN segment.

Phase A requires a registry that can receive pushed images before k3s is installed (chicken-and-egg for Helm-managed registry).

## Decision

**Phase A:** Run an ephemeral `registry:2` container on `rk1-node1` via plain Docker (HTTP, no TLS, port 5000, `--restart=always`). This is deliberately simple and insecure — it only serves the bootstrapping period.

**Phase B:** Replace with a persistent registry deployed via Helm chart (`registry-chart/` in this repo), with:
- TLS termination (self-signed CA, certs in Kubernetes Secret)
- Basic auth (`htpasswd`)
- SSD-backed persistent volume (avoids image loss on pod restart)
- containerd mirror config on all nodes so `k3s` pulls from local registry transparently

## Consequences

**Positive:**
- Phase A registry is up in minutes with no k3s dependency
- `--restart=always` survives node reboots without manual intervention
- Phase B Helm chart is pre-written and ready to deploy once k3s is running

**Negative:**
- Phase A registry is HTTP-only — insecure on the LAN, acceptable for bootstrap
- Phase A registry is ephemeral — images lost on `docker rm` or node re-flash
- containerd mirror config (Phase B) must be applied to all nodes for transparent pull

## Notes

Phase B registry is deployed, TLS verified, and basic auth enabled as of 2026-05-11. Credentials in `~/.turingpi/credentials.kv`. containerd mirror on all nodes confirmed via k3s pod pull. See ADR-0021 for the TLS/CA approach.
