# tpi-bro — Deployment Status

_Last updated: 2026-05-10_

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
| Registry node IP | DHCP — configure static reservation before Phase B; see `bootstrap-state.kv` |
| BMC hostname | `turingpi.local` (mDNS) |

## Node Role Assignment (planned)

| Node | Hostname | Role |
|------|----------|------|
| 1 | rk1-node1 | k3s server + Agent A LLM agent + ephemeral registry |
| 2 | rk1-node2 | k3s worker — future LLM agent |
| 3 | rk1-node3 | k3s worker — future LLM agent |
| 4 | rk1-node4 | k3s worker — RAG / vector DB / supporting infra |

## Software Stack

| Layer | Tool | Status |
|-------|------|--------|
| OS | Ubuntu 24.04.1 LTS ARM64 (joshua-riek/ubuntu-rockchip v2.4.0) | Deployed on all 4 nodes (2026-05-10) |
| Container runtime (Phase A) | Docker (node1 only, for registry) | Running |
| Container runtime (Phase B) | containerd (via k3s) | Not started |
| Orchestrator | k3s | Not installed |
| GitOps | Argo CD or Flux (TBD) | Not installed |
| Registry (Phase A) | registry:2 container, HTTP, port 5000 | Running on node1 |
| Registry (Phase B) | Helm chart (`registry-chart/`), TLS + auth | Not deployed |
| LLM runtime | Ollama | Not installed |
| Ingress | Traefik (k3s built-in) | Not installed |

## Access Methods

| Method | Command / URL | Notes |
|--------|---------------|-------|
| BMC power control | `tpi power on/off -n NODE` | Installed on laptop; works over WiFi |
| SSH to nodes | `ssh ubuntu@rk1-node{1..4}` | After Phase A; `/etc/hosts` updated |
| Registry push (Phase A) | `docker push rk1-node1:5000/IMAGE` | HTTP only; Docker daemon needs insecure-registries config |
| Registry push (Phase B) | `docker push rk1-node1:5000/IMAGE` | HTTPS; CA cert must be trusted on laptop |
| kubectl | `kubectl get nodes` | After k3s install; kubeconfig on node1 at `/etc/rancher/k3s/k3s.yaml` |

## Registry TLS Cert Status

- `gen-registry-certs.sh` script exists and is ready to run
- SAN includes: `rk1-node1`, and the planned static IP for node1 (update before generating)
- Certs not yet generated (Phase B pre-requisite; configure DHCP reservation for node1 first so the IP in the SAN is stable)
- Generated artefacts are `.gitignore`d (`registry-certs/`, `*.key`, `*.crt`, etc.)

## Laptop Requirements

| Tool | Purpose | Status |
|------|---------|--------|
| `tpi` CLI | BMC power/flash control | Installed |
| `expect` | Phase A bootstrap script | Required |
| `nmap` | BMC/node discovery | Required |
| `ssh` | Node access | Required |
| `curl` | Health checks | Required |
| `docker` | Image build + push | Required for image workflow |
| `kubectl` | Cluster management | Not installed (kubectl binary gitignored) |
| `helm` | Phase B registry deploy | Required for Phase B |

## Known Issues

- `turingpi.local` mDNS resolution can fail when only WiFi is available on some networks; fall back to scanning router DHCP table or using `nmap` on the LAN subnet
- **DHCP leases for all 4 nodes drift on every reboot** — confirmed in validation run 2026-05-10; all nodes received new IPs after each A5 reboot. Configure static DHCP reservations in the router before Phase B. Use `--rediscover` to sync state + `/etc/hosts` after any power cycle until then.
- Phase A registry is HTTP-only; laptop Docker daemon must have `rk1-node1:5000` in `insecure-registries`
- Ubuntu 24.04.1 LTS (like 24.10) enforces a mandatory password change on first boot; the bootstrap script handles this automatically via `unlock_expired_password`
