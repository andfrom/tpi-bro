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
**Status:** DONE (2026-05-11)  
`manifests/priority-classes.yaml`: `interactive` (1000, agent-a) and `background` (100, Ollama). `manifests/limitrange-sibling-app.yaml` + `manifests/limitrange-ollama.yaml`. Ollama chart updated with `priorityClassName: background`; Agent A manifest with `priorityClassName: interactive`. Applied via `scripts/apply-resource-policy.sh`.

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
**Status:** DONE (2026-05-11)  
Both bootstrap scripts now fall back to `~/.turingpi/bootstrap-config.kv` when no repo-local config exists. `MANIFEST_FILE` and `IMAGE_CACHE_DIR` defaults also prefer `~/.turingpi/` when no repo-local file exists. Priority order: `--config FILE` > `./bootstrap-config.kv` > `~/.turingpi/bootstrap-config.kv`. Repo-local workflow unchanged.

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

---

## Platform Hygiene

### PH-01: Remove application-specific knowledge from D-02

**Status:** TODO

D-02 (agent deployment, marked DONE) violates the principle that tpi-bro should
not know about specific applications. It names `sibling-app`, `agent-a`, and
`OLLAMA_URL` directly, and `scripts/deploy-agent-a.sh` lives in this repo.

**Correct ownership:**
- `scripts/deploy-agent-a.sh` → move to the application repo under its own
  `infra/` or `scripts/` directory. tpi-bro should not own application deploy
  scripts.
- `sibling-app/infra/k8s/agent-a.yaml` is already in the right place (application
  repo); tpi-bro should not reference it.
- tpi-bro's role is to provide the platform primitives the application uses:
  the cluster, the registry, Ollama as a service, PriorityClasses, StorageClasses,
  Tailscale operator. How an application deploys onto those primitives is the
  application's concern.

**What tpi-bro should provide instead:** a documented pattern for deploying a
stateless agent that consumes an Ollama endpoint — generic enough that any
application can follow it without tpi-bro knowing which application it is.
This pattern can live in `docs/` as a deployment guide, not as a named script.

**Steps:**
1. Move `scripts/deploy-agent-a.sh` to the application repo
2. Update D-02 in this backlog to describe the generic pattern, not the specific
   application
3. Add a `docs/DEPLOYING-AN-AGENT.md` guide covering: build ARM64 image via
   buildx, push to cluster registry, apply a Deployment + ClusterIP Service,
   expose via Tailscale operator annotation — no application names

---

## Event-Driven Scheduling (ADR-0022)

### E-01: Deploy KEDA + Redis job queue

**Status:** TODO

Deploy KEDA via Helm in the `keda` namespace. Deploy a single Redis instance
(lightweight, `redis:7-alpine`) as the shared job queue. One Redis list key per
workload type; KEDA `ScaledJob` per workload type watching its key.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

Redis can share the `monitoring` namespace or get its own. PVC on `local-ssd`
for persistence across pod restarts (job queue must survive Redis restarts).

### E-02: Node capability labels and bootstrap integration

**Status:** TODO

Add capability label detection to the node setup scripts so labels are applied
automatically at bootstrap time and whenever a module is swapped.

Labels to detect and apply (see ADR-0022):
- `tpi-bro/npu: rk3588` — detected by presence of `/dev/rknpu` on the node
- `tpi-bro/npu: jetson-orin-nano` — detected by presence of CUDA device nodes
- No `tpi-bro/npu` label — CM4 or any node without an NPU device

Add a `scripts/label-node-capabilities.sh` that SSHes to each node, probes for
device nodes, and applies the appropriate labels via `kubectl label node`. Run
automatically as part of `bootstrap-phase-b.sh` after nodes are Ready, and
document as a required step after any module swap (HW-01).

### E-03: Interruptible workload eviction init container

**Status:** TODO — [BLOCKED on E-01]

Implement the step-2 eviction logic from ADR-0022 as a reusable init container
image in tagx. The init container:
1. Queries nodes matching the parent job's `nodeAffinity` capability labels
2. Finds running pods labelled `tpi-bro/interruptible: "true"` on those nodes
3. Issues graceful deletes if the parent pod is pending due to resource contention

Requires a ClusterRole with `pods/get`, `pods/list`, `pods/delete` and a
ServiceAccount bound to it, scoped per namespace. Add to the whisper chart
(W-01) as the first consumer.

---

## Whisper STT

### W-01: Helm chart for batch STT jobs with model cache (CPU)

**Status:** TODO — [BLOCKED on `tagx/whisper-stt` CPU image being pushed to the
cluster registry]

Add `charts/whisper/` — a reusable Helm chart for running Whisper transcription
as a one-shot Kubernetes Job. Modelled on `charts/ollama/`: PVC for model weights
on `local-ssd`, `nodeAffinity` on `storage.tpi-bro/nvme=true` to keep the model
cache co-located with the pod.

Key chart values:
- `image.repository` / `image.tag` — caller supplies the tagx image reference
- `model` — Whisper model size (e.g. `large-v3`)
- `modelCache` — path inside container where `/models` is mounted (default `/models`)
- `language`, `beamSize` — passed through as env vars to the container

The chart is application-agnostic: callers specify their own namespace and audio
input via values. tpi-bro provides the scheduling and storage pattern only.

### W-02: RKNN device mount pattern for whisper-stt

**Status:** TODO — [BLOCKED on W-01 + `tagx/whisper-stt:rknn` image existing]

Extend `charts/whisper/` with an `rknn.enabled` flag that conditionally adds
the required device mounts for NPU-accelerated inference:
`/dev/rknpu`, `/dev/dri`, `/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap`.
Container security context: privileged or explicit device allowlist.

With `rknn.enabled: false` (default) the chart deploys the CPU variant cleanly.
Switching to RKNN is a single values override — no manifest changes needed.

This pattern is reusable for any future RKNN-accelerated workload beyond Whisper.
Record NPU benchmark results in `docs/NPU-MODELS.md` once measured.

---

## Research

### R-01: RK3588 NPU acceleration for LLM inference
**Status:** TODO

The RK3588 has a 6 TOPS NPU per module (18 TOPS across 3 NVMe nodes). Ollama
does not use it — CPU-only inference on `llama3.2:1b` takes ~70–150 s per
request (warm model), making larger models impractical regardless of RAM.
Validated 2026-05-12: llama3.2:1b on CPU produces unreliable scores (95/100
for Profile A vs Profile B); the model is too small to apply
a multi-criterion rubric. A 7B model on NPU is the minimum viable path.

**Why RAM is not the bottleneck**  
A 13B Q4 model (~7 GB) fits in 16 GB per node. The limit is compute throughput
(matrix multiply) and memory bandwidth per token, not capacity. CPU NEON SIMD
gives ~3–5 tok/s for 1B; 13B would be ~0.3 tok/s (~10 min/response). The NPU
dedicates silicon to matrix multiply — same model should run 5–15× faster.

**Model targets (estimated)**

| Model     | INT4 size | Fits NPU SRAM? | Est. tok/s (NPU) |
|-----------|-----------|----------------|------------------|
| Llama 3.2 1B | 0.7 GB | Partially | 20–40 |
| Llama 3.2 3B | 2 GB   | No — DRAM  | 8–15  |
| Llama 3.1 7B | 4 GB   | No — DRAM  | 3–6   |

7B is the minimum for reliable structured reasoning. 6 TOPS on DRAM-backed
layers still beats CPU by a large margin because the compute units are faster,
not because weights fit on-chip.

**Conversion pipeline**

```
Hugging Face weights → rknn-llm conversion tool (x86 host) → .rkllm file
                                                                    ↓
                                              rkllm-server on RK1 node (ARM64 + NPU)
```

Conversion is a one-time step per model, runs on the laptop, produces a
`.rkllm` file that is deployed to the cluster (e.g. via a PVC or baked into
an image layer).

**Key finding:** Rockchip's official `airockchip/rknn-llm` toolkit supports
LLM inference on the NPU. Community projects (e.g. `rkllm-server`) wrap it
with an Ollama-compatible HTTP API, meaning the sibling-app stack (Agent A,
`OLLAMA_URL`) would not need changes — just swap the inference endpoint.

**Suggested first step (self-contained experiment)**  
Clone `rknn-llm`, convert `llama3.2:1b` on the laptop, run `rkllm-server` on
a single RK1 node, and score one item end-to-end. This answers the four open
questions (model family support, JSON output stability, conversion toolchain,
single-node latency) without touching the cluster configuration.

**What the full investigation involves:**
1. Model conversion — export `llama3.2:1b` (then 7B) to RKNN format using the
   rknn-llm toolkit on the laptop; verify output on one RK1 node
2. Runtime deployment — build or pull a container image with the RKNN runtime
   + rkllm-server; deploy as a Kubernetes Deployment on an NVMe node with the
   RKNN device node (`/dev/rknpu`) mounted
3. Benchmark — compare tokens/second and end-to-end scoring latency vs. current
   CPU-only Ollama baseline; verify score quality with a 7B model
4. Rollout — if viable, deploy alongside Ollama as an opt-in endpoint
   (`OLLAMA_URL` → rkllm-server ClusterIP); Ollama stays as fallback

**Open questions to resolve in step 1**
- Does rknn-llm support Llama 3.x architecture? (model-specific conversion code)
- Does rkllm-server support `format: json` (structured output)?
- Does the conversion toolchain run cleanly on the laptop (x86 Linux)?
- What is realistic tok/s for 1B and 7B on a single RK1 node?

**Constraints / risks:**
- RKNN-LLM model support is limited (Llama, Qwen, Phi families confirmed;
  others need testing)
- Model conversion requires x86 host with the rknn-llm conda environment
- `/dev/rknpu` device must be exposed to the pod via `hostPath` volume +
  privileged security context (or a device plugin); multiple device nodes
  required (`/dev/dri`, `/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap`) —
  silent CPU fallback if any are missing
- The Mali G610 GPU is NOT useful for this — NPU only
- Multi-node: rkllm-server runs per-node; decide whether to run one per RK1
  or pin to node1 only
- `/mnt/ssd` is root-owned; `sudo` required for model downloads via SSH.
  Fix: `sudo chown -R $USER:$USER /mnt/ssd/rkllm-models` after creating dir.
- RKLLM-API-Server does not yet implement `format: json` (structured output).
  Mitigation: strong system prompt + JSON parse-and-retry in agent-a;
  reliable with 7B+ Instruct models without grammar sampling.

**Documentation:** `docs/NPU-MODELS.md` — storage layout, download commands,
conversion pipeline, quantization guide, planned automation script interface.