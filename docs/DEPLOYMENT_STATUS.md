# tpi-bro — Deployment Status

_Last updated: 2026-05-11 (B-07/B-08 complete)_

## Cluster Hardware

| Component | Detail |
|-----------|--------|
| Board | TuringPi 2 |
| Compute modules | 4× RK1 (RK3588 SoC, ARM64) |
| RAM per node | 32 GB LPDDR5 |
| Total cluster RAM | 128 GB |
| GPU | Mali G610 MP4 (display / OpenCL only — not useful for LLM inference) |
| NPU | 6 TOPS per module |
| Estimated power | ~10 W per module at idle |
| Node IPs | Static: node1=192.168.1.11, node2=.12, node3=.13, node4=.14, BMC=.10 |
| BMC hostname | `turingpi.local` (mDNS) |

## Node Role Assignment (planned)

| Node | Hostname | IP | Role |
|------|----------|----|------|
| 1 | rk1-node1 | 192.168.1.11 | k3s server + persistent registry + future Agent A LLM agent |
| 2 | rk1-node2 | 192.168.1.12 | k3s agent — future LLM agent |
| 3 | rk1-node3 | 192.168.1.13 | k3s agent — future LLM agent |
| 4 | rk1-node4 | 192.168.1.14 | k3s agent — RAG / vector DB / supporting infra |

## Software Stack

| Layer | Tool | Status |
|-------|------|--------|
| OS | Ubuntu 24.04.1 LTS ARM64 (joshua-riek/ubuntu-rockchip v2.4.0) | Deployed on all 4 nodes (2026-05-10) |
| Container runtime (Phase A) | Docker (node1 only, for Phase A registry) | Stopped (Phase B registry replaced it) |
| Container runtime (Phase B) | containerd 2.2.3 (via k3s) | Running on all 4 nodes |
| Orchestrator | k3s v1.35.4+k3s1 | Running (node1 server, nodes 2–4 agents) |
| GitOps | Argo CD or Flux (TBD) | Not installed |
| Registry (Phase A) | registry:2 container, HTTP, port 5000 | Stopped (replaced by Phase B) |
| Registry (Phase B) | Helm chart (`charts/registry/`), TLS + basic auth | **Running** on node1 (HostPort 5000, PVC 50Gi local-path) |
| LLM runtime | Ollama | Not installed |
| Ingress | Traefik (k3s built-in) | Running (k3s default) |

## Access Methods

| Method | Command / URL | Notes |
|--------|---------------|-------|
| BMC power control | `tpi power on/off -n NODE` | Installed on laptop; works over WiFi |
| SSH to nodes | `ssh ubuntu@rk1-node{1..4}` | After Phase A; `/etc/hosts` updated |
| Registry push (Phase A) | `docker push rk1-node1:5000/IMAGE` | HTTP only; Docker daemon needs insecure-registries config |
| Registry push (Phase B) | `docker push rk1-node1:5000/IMAGE` | HTTPS; CA cert must be trusted on laptop |
| kubectl | `kubectl get nodes` | After k3s install; kubeconfig on node1 at `/etc/rancher/k3s/k3s.yaml` |

## Registry TLS Cert Status

- **Certs generated and deployed** (2026-05-11)
- SAN includes: `rk1-node1` (DNS) and `192.168.1.11` (IP) — matches static IP
- Self-signed CA (`myCA.crt`) trusted by all 4 nodes and laptop Docker daemon
- `registry-tls` Secret in namespace `registry` contains `registry.crt` + `registry.key`
- CA and cert artefacts in `registry-certs/` (gitignored)
- Cert valid 825 days from generation; CA valid 3650 days

## Laptop Requirements

| Tool | Purpose | Status |
|------|---------|--------|
| `tpi` CLI | BMC power/flash control | Installed |
| `expect` | Phase A bootstrap script | Required |
| `nmap` | BMC/node discovery | Required |
| `ssh` | Node access | Required |
| `curl` | Health checks | Required |
| `docker` | Image build + push | Required for image workflow |
| `kubectl` | Cluster management | Installed (`bin/kubectl`, vendored) |
| `helm` | Phase B registry deploy | Installed (v3.20.2, `/usr/local/bin/helm`) |

## Auth Credentials

Registry basic auth credentials are stored in `~/.turingpi/credentials.kv` (mode 600, gitignored).

```
# ~/.turingpi/credentials.kv  (key=value, chmod 600)
REGISTRY_USER=push
REGISTRY_PASSWORD=<generated on first --enable-auth run>
```

Run `./scripts/setup-registry.sh --verify` to confirm push/pull with authentication.  
Run `./scripts/setup-registry.sh --enable-auth` to (re-)apply auth from this file.

containerd mirror config on each node includes the credentials in `/etc/rancher/k3s/registries.yaml`.  
Mirror endpoint uses the server IP (`192.168.1.11:5000`) so worker nodes don't need hostname DNS for `rk1-node1`.  
Re-run `./scripts/setup-registry.sh --ca-only` after changing the password to push updated credentials to all nodes.

## Known Issues

- `turingpi.local` mDNS resolution can fail when only WiFi is available on some networks; fall back to using the static IP `192.168.1.10` directly
- Ubuntu 24.04.1 LTS enforces a mandatory password change on first boot; the bootstrap script handles this automatically via `unlock_expired_password`
- Registry PVC is currently backed by eMMC via local-path. Must be moved to SSD (B-09) before Ollama deployment to avoid storage bottleneck.
