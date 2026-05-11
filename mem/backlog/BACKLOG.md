# tpi-bro Backlog

Ordered roughly by dependency / priority. Items with `[BLOCKED]` cannot start until their blocker is resolved.

---

## Phase A — Bootstrap Polish

### A-01: Replace `tpi_power` placeholder with real `tpi` CLI calls
**Status:** DONE  
`tpi_power` uses `exec {*}$args` with proper list construction; passes `--host $BMC_HOST` when set. A2 calls `tpi power off` (all nodes). A4 calls `tpi power on -n $i` per node. Discovery uses event-driven deadline loops — no fixed sleeps.

### A-02: Write teardown script
**Status:** DONE (`teardown-cluster.exp`)  
Stages T1–T8: load state → verify SSH → stop registry → reset passwords → reset hostnames → clean /etc/hosts → graceful poweroff + tpi → archive state. Flags: `--dry-run`, `--remove-docker`, `--keep-hostname`, `--from`/`--to`, `--password`.

### A-03: Dry-run for all stages (not just Phase A)
**Status:** DONE  
`--dry-run` verified across all bootstrap stages (Phase A), `--rediscover`, and all teardown stages (T1–T8). All produce meaningful output.

### A-04: CI / automated test for Phase A dry-run
**Status:** DONE  
GitHub Actions workflow (`.github/workflows/ci.yml`) runs `./tests/run-ci.sh` on every push/PR to main. No hardware required.

### A-08: Lint CI + Phase B cluster health check
**Status:** DONE (2026-05-11)  
CI (`lint` job in `.github/workflows/ci.yml`) runs `shellcheck --severity=warning` on all Phase B shell scripts and `helm lint` + `helm template` on `charts/registry/` on every push/PR. No hardware required.  
`tests/check-cluster.sh` (Suite 4) runs 10 named checks against a live cluster: nodes Ready, registry pod, TLS, auth, push, and per-node pod pull via containerd mirror. `--quick` skips the pod pull tests.

### A-05: Real flash modes (image / download / local)
**Status:** DONE  
`--flash image` flashes per-node image files via `tpi flash --image-path`. `--flash download` downloads from a manifest (`images-manifest.kv`), verifies SHA256, caches in `./image-cache/`, and re-downloads on checksum mismatch. `--flash local` uses `tpi flash --local`. All four modes (`skip` / `local` / `image` / `download`) are implemented and tested.

### A-06: Config file support
**Status:** DONE  
`--config FILE` loads key=value overrides before stage execution. If `./bootstrap-config.kv` exists it is auto-loaded. CLI flags always win. `bootstrap-config.kv.example` documents all keys. Per-node image paths (`IMAGE_1` … `IMAGE_4`) and types (`IMAGE_1_TYPE` … `IMAGE_4_TYPE`) are settable from the config file.

### A-07: A0 BMC firmware check / upgrade stage
**Status:** DONE  
`A0_bmc_firmware` runs before A1. Controlled by `--bmc-firmware skip|check|upgrade` (default: skip). Check mode compares running BMC version against `bmc-manifest.kv`. Upgrade mode downloads firmware, verifies SHA256, calls `tpi firmware --file`, and waits for BMC reboot. Full dry-run support (exits early before touching BMC host).

---

## Phase B — Persistent Registry + k3s

### B-00: Static IPs on all nodes and BMC
**Status:** DONE (2026-05-09)  
`setup-static-ips.sh` configures netplan on Ubuntu nodes and ifupdown on the BMC. Static IPs persist across reboots. No DHCP drift.

### B-01: k3s install on node1 (server role)
**Status:** DONE (2026-05-09)  
`install-k3s.sh` installs k3s v1.35.4+k3s1 on node1 with `--tls-san rk1-node1 --tls-san 192.168.1.11`. Laptop kubeconfig written to `~/.kube/config`.

### B-02: k3s install on nodes 2–4 (worker/agent role)
**Status:** DONE (2026-05-09)  
`install-k3s.sh` joins nodes 2–4 as k3s agents. All 4 nodes Ready.

### B-03: containerd registry mirror config
**Status:** DONE (2026-05-11)  
`install-ca.sh` writes `/etc/rancher/k3s/registries.yaml` on all 4 nodes and restarts k3s/k3s-agent. Mirror endpoint: `https://rk1-node1:5000`.

### B-04: Deploy persistent registry via Helm chart
**Status:** DONE (2026-05-11)  
`setup-registry.sh` deploys `charts/registry/` via Helm in namespace `registry`. HostPort 5000 on node1. PVC 50Gi (local-path). TLS via `registry-tls` Secret. Auth disabled (TLS-first per ADR-0004).

### B-05: Generate and distribute CA cert
**Status:** DONE (2026-05-11)  
`gen-registry-certs.sh` generates self-signed CA + server cert. `install-ca.sh` distributes CA to all 4 nodes (system trust store + containerd). Laptop Docker trust automated in `setup-registry.sh`.

### B-06: End-to-end laptop push/pull test
**Status:** DONE (2026-05-11)  
`setup-registry.sh --verify` confirms `docker push` + `docker pull` from laptop via HTTPS with CA trust. Registry at `rk1-node1:5000` working.

### B-07: Enable registry basic auth
**Status:** DONE (2026-05-11)  
`./scripts/setup-registry.sh --enable-auth` creates htpasswd Secret from `~/.turingpi/credentials.kv` and upgrades the Helm release with `auth.enabled=true`. `--verify` now detects auth and logs in automatically. Deployment strategy fixed to `Recreate` to avoid HostPort conflicts during rolling upgrade.

### B-08: Test k3s pod pull from registry
**Status:** DONE (2026-05-11)  
Pod scheduled to rk1-node3 pulled `rk1-node1:5000/test:latest` in 505ms via containerd mirror (`registries.yaml` uses IP endpoint `https://192.168.1.11:5000` so no hostname DNS needed on worker nodes). Auth credentials embedded in mirror config. Phase A HTTP registry container (docker-proxy) conflict resolved — removed from node1.

### B-09: Mount NVMe SSDs on all nodes
**Status:** IMPLEMENTED — ready to run  
**Must complete before Ollama deployment.**

Hardware reality (verified 2026-05-11):
- Nodes 1, 2, 3: TEAM TM8FPD002T 2TB NVMe, unformatted
- Node 4: **no NVMe** — only eMMC (29.1GB); see ADR-0019 note on DB placement

**Automated via `scripts/mount-ssd.sh` + `setup-registry.sh --migrate-pvc`:**

```bash
# Dry-run to preview all actions
./scripts/bootstrap-phase-b.sh --dry-run --from B09_mount_ssd

# Run: format + mount nodes 1-3, deploy local-ssd StorageClass, migrate registry PVC
./scripts/bootstrap-phase-b.sh --from B09_mount_ssd

# Or run individually
./scripts/mount-ssd.sh                        # format + mount + StorageClass
./scripts/setup-registry.sh --migrate-pvc     # move registry PVC to SSD (data loss ok)
```

After B-09:
- `/mnt/ssd` mounted on nodes 1-3 (UUID fstab entry, noatime, ext4)
- `local-ssd` StorageClass backed by `/mnt/ssd/local-path-provisioner/`
- Registry PVC on `local-ssd` (node1 SSD)
- Node4 has no SSD — DB pod (future) must use node3 SSD or wait for SSD install

See ADR-0019 for storage architecture decisions.

---

## Phase C — Resilience + Laptop Mirror

### C-01: IP resilience for registry
**Status:** TODO  
Handle the case where `rk1-node1`'s DHCP lease changes. Options: static IP reservation on router, or CoreDNS custom entry in k3s.

### C-02: Laptop-to-cluster image sync
**Status:** TODO  
Script to sync images from laptop's local Docker daemon to the cluster registry (e.g., `docker save | ssh | docker load` or `skopeo copy`).

### C-03: Cloud expansion notes
**Status:** TODO  
Document how to federate the local cluster with a cloud K8s cluster (e.g., for GPU inference overflow).

---

## Phase D — Multi-Agent Workloads

### D-00: Apply PriorityClass and ResourceRequests to all agent Deployments
**Status:** TODO  
`[BLOCKED on D-01]` Create `interactive` (value 1000) and `background` (value 100) PriorityClasses. Set resource requests + limits on all agent and Ollama pods per ADR-0008. Add a LimitRange to each namespace.

### D-01: Ollama deployment on each LLM node
**Status:** TODO  
Deploy Ollama via Helm or Kubernetes manifest, one instance per node, with `nodeSelector` pinning. Pull model weights from registry or volume.

### D-02: Agent deployment (sibling-app Agent A)
**Status:** TODO  
Deploy the `sibling-app` Agent A agent as a Kubernetes Deployment on `rk1-node1`, with a Service and Ingress (or NodePort) for the FastAPI endpoint.

### D-03: Ingress controller
**Status:** TODO  
Install Traefik (bundled with k3s) or Nginx ingress. Route `/agent-a/` to Agent A, etc.

### D-04: Observability baseline
**Status:** TODO  
Prometheus + Grafana via kube-prometheus-stack Helm chart. Basic dashboards: CPU, RAM, GPU/NPU utilization per node.

---

## Security & Hardening (Future)

### S-01: Internal HTTPS ingress
Node-port exposure is not suitable for production traffic. Add Traefik + cert-manager (Let's Encrypt or self-signed) for HTTPS ingress routing inside the cluster.

### S-04: External remote access (Tailscale / reverse proxy)
**Status:** TODO  
Accessing the cluster from outside the home LAN (e.g. from a laptop on a different network) requires either a VPN mesh or a cloud-fronted reverse proxy. Options:

- **Tailscale** (recommended): install the Tailscale agent on each node and the laptop; the cluster becomes reachable at stable Tailscale IPs regardless of home network topology or NAT. Zero port forwarding required. Free for personal use; ARM64 Ubuntu supported.
- **WireGuard**: self-hosted alternative if Tailscale dependency is undesirable.
- **Cloud reverse proxy**: a small VPS running nginx/caddy with TLS termination, forwarding to the cluster over a persistent tunnel. More control, more ops overhead.

This is a prerequisite for running `sibling-app` agents from a mobile context or CI pipelines outside the home network.

### S-02: Multi-tenancy / user compartmentalization
SSD volume isolation per user. Not needed until multiple users share the cluster.

### S-03: Compute prioritization
PriorityClass for critical agents; ResourceQuota per namespace; eviction policy for background jobs under GPU/NPU pressure.

---

## Configuration & UX

### CFG-01: `~/.turingpi/` home directory for personal config
**Status:** TODO  
Currently personal config files (`bootstrap-config.kv`, `images-manifest.kv`, `bmc-manifest.kv`) and image downloads live gitignored in the repo root — conflating the tool with the installation. A standard home directory would be cleaner:

```
~/.turingpi/
  bootstrap-config.kv     # auto-loaded if no repo-local config and no --config flag
  images-manifest.kv      # default image manifest
  bmc-manifest.kv         # default BMC firmware manifest
  image-cache/            # downloaded images (can be large; shared across clones)
  clusters/               # future: named profiles for multiple clusters
```

Auto-load priority order: `--config FILE` (explicit) > `./bootstrap-config.kv` (repo-local) > `~/.turingpi/bootstrap-config.kv` (user-global).  
Opt-in, not mandatory — existing repo-local workflow still works.

---

## Documentation

### DOC-01: Expand README with BMC reconnection steps
Document how to find the BMC if `turingpi.local` mDNS fails (use `nmap` scan, check router DHCP table, or fall back to Ethernet direct connect).

### DOC-02: LICENSE file
Add MIT or Apache 2.0 license. Required before open-sourcing.

### DOC-03: CONTRIBUTING.md
Contribution guide, issue templates, PR checklist.

### DOC-04: Jetson Orin Nano / CM4 support
Currently untested. Document gaps once hardware is available.
