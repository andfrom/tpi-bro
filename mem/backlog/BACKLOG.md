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
**Status:** DONE (2026-05-11)

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
**Status:** DONE (2026-05-11)  
`charts/ollama/` — single Helm chart, one release per NVMe node (`ollama-node1/2/3`), namespace `ollama`. Node hostname pin justified by model-weight locality (ADR-0019). PVC 200Gi `local-ssd` per instance. `scripts/install-ollama.sh` auto-detects NVMe nodes via label, deploys all three, optionally pulls models. In-cluster DNS: `ollama-node1.ollama:11434`, etc.

### D-02: Agent deployment (sibling-app Agent A)
**Status:** DONE (2026-05-11)  
`scripts/deploy-agent-a.sh` — builds linux/arm64 image on laptop via QEMU + docker buildx (docker-container driver), pushes to cluster registry, applies `sibling-app/infra/k8s/agent-a.yaml`. Namespace `sibling-app`, Deployment + ClusterIP Service on port 18090. `OLLAMA_URL=http://ollama-node1.ollama:11434`. No node pin (stateless). `model.cfg` updated to `llama3.2:3b`.

### D-03: Ingress / service exposure
**Status:** TODO — superseded in priority by N-01 (Tailscale mesh). Revisit after N-01; Tailscale operator may cover all ingress needs for this use case.

### D-04: Observability baseline
**Status:** DONE (2026-05-11)  
`kube-prometheus-stack` deployed via `scripts/install-monitoring.sh` in namespace `monitoring`. Grafana exposed on Tailnet via operator. Pre-loaded dashboards: node-exporter-full (gnetId 1860), k8s cluster overview (7249), k3s (15282). Stateful components (Prometheus, Grafana, Alertmanager) pinned to NVMe nodes via `storage.tpi-bro/nvme=true` nodeSelector; all PVCs on `local-ssd`. k3s-specific components (kubeControllerManager/Scheduler/Proxy/Etcd) disabled. Grafana accessible at `monitoring-kube-prometheus-stack-grafana.<tailnet>.ts.net:80`.  
Config: `charts/monitoring/values.yaml`. Verify: `./scripts/install-monitoring.sh --verify`.

---

## Network Layer

### N-01: Tailscale mesh — cluster as seamless network extension
**Status:** DONE (2026-05-11) — all three layers complete.

Tailscale is not just remote access. It is the network substrate that makes every application on the laptop interact with the cluster without port-forwarding, without `kubectl` tunnels, without knowing about home router topology or NAT. The cluster becomes a seamless extension of the laptop for any process.

**Three layers, each independently valuable:**

**Layer 1 — Node mesh (30 min)**  
Install `tailscale` on all 4 nodes and the laptop. Every device gets a stable Tailscale IP and a MagicDNS hostname (`rk1-node1.your-tailnet.ts.net`) that never changes. Works from home, coffee shop, CI runner, anywhere.

- `OLLAMA_URL=http://rk1-node1.your-tailnet.ts.net:11434` in `.env` — no port-forward ever again
- `kubectl` over Tailscale IP — no `port-forward`, kubeconfig just works
- NodePort services directly reachable by name

**Layer 2 — Subnet routing (15 min)**  
One node advertises the k3s cluster CIDR (`10.43.0.0/16`) as a Tailscale subnet route. Every ClusterIP service becomes directly routable from the laptop — no NodePort needed, in-cluster DNS names become reachable from outside.

**Layer 3 — Tailscale Kubernetes operator (1–2 h)**  
The operator watches for annotated Services and exposes each as its own Tailscale device with a stable DNS name. Annotate a Service with `tailscale.com/expose: "true"` and it appears at `agent-a.your-tailnet.ts.net` — no ingress controller, no port-forward, no kubectl. Any app on any Tailnet device calls it directly by name.

- Deploying a new agent = one annotation; it appears on the Tailnet automatically
- This replaces D-03 (ingress controller) for this use case
- CI pipelines, mobile, scripts, other applications — all call services by stable name

**End state:** `sibling-app score` from anywhere, any app talks to any service by name, new agents self-advertise. The orchestration layer has zero network topology knowledge.

**Implementation order:** Layer 1 → Layer 2 → Layer 3. Each layer is usable standalone.

**Key gotcha:** Auth key must be **Reusable** + **Pre-authorized**. The default in the Tailscale admin is Single-use — a single-use key is silently consumed on the first node and fails for all subsequent ones. See `docs/PREREQUISITES.md` N-01 section for the full manual setup sequence.

**Scripts:**
- `scripts/install-tailscale.sh` — installs + authenticates tailscaled on all 4 nodes; `--status` to inspect
- `scripts/setup-subnet-router.sh` — enables IP forwarding on node1, advertises k3s CIDRs; requires manual route approval in Tailscale admin
- `scripts/setup-tailscale-operator.sh` — deploys Tailscale k8s operator via Helm; `--expose svc/NAME -n NS` to expose a service

---

## Security & Hardening (Future)

### S-01: Internal HTTPS ingress
**Status:** SUPERSEDED by N-01. Tailscale operator provides TLS-terminated ingress per service without a separate ingress controller.

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

## Hardware Upgrades (Future)

### HW-01: NVMe disk replacement and node4 SSD addition
**Status:** TODO — do not attempt until scripting is updated and hardware is in hand.

**Scenario:** Replace node1's 2TB SSD with a 4TB, move the 2TB to node4.

**Why it's safe:** All data on the SSDs (registry images, Ollama model weights) is
fully reproducible — images can be rebuilt and re-pushed, model weights re-pulled.
No irreplaceable state lives on the SSDs.

**Rough sequence:**
1. Record what images are in the registry (re-push list)
2. `kubectl drain rk1-node1 --ignore-daemonsets --delete-emptydir-data`
3. `tpi power off` both nodes; physical swap (4TB → node1, 2TB → node4)
4. `tpi power on`
5. Node1: remove stale fstab entry (`sudo sed -i '/mnt\/ssd/d' /etc/fstab`), then re-mount + re-format
6. Node4: run `mount-ssd.sh` — detects new NVMe, formats, mounts, adds to ConfigMap, labels node
7. Re-deploy registry (PVC recreates on new 4TB); re-push all images
8. Re-pull Ollama models on node1 (`install-ollama.sh --node rk1-node1 --model llama3.2:3b`)
9. Deploy Ollama on node4 (`install-ollama.sh --node rk1-node4 --model llama3.2:3b`)
10. `kubectl uncordon rk1-node1`

**Tooling gaps to fix before attempting:**
- `mount-ssd.sh` has no `--node` flag — currently targets all NVMe nodes at once.
  Need per-node targeting so nodes 2 and 3 are left untouched during a node1 swap.
- `mount-ssd.sh` does not handle stale fstab entries from a replaced disk.
  Need a `--force-remount` mode that strips existing `/mnt/ssd` fstab lines before
  adding the new UUID, so `mount -a` doesn't choke on the old disk's UUID.

**Before starting:** add `--node` and `--force-remount` to `mount-ssd.sh`, test
with `--dry-run` on a live node, then proceed with the hardware swap.

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