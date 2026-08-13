# tpi-bro Backlog

Ordered roughly by dependency / priority. Items with `[BLOCKED]` cannot start until their blocker is resolved.

Finished items are removed rather than kept as `DONE` markers — the historical
record lives in git history and commit messages, not here. This is a pure
TODO list.

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

### D-03: Ingress / service exposure
**Status:** TODO — superseded in priority by N-01 (Tailscale mesh, done). Tailscale operator covers ingress needs for this use case; revisit only if a non-Tailnet-member consumer ever needs access.

---

## Security & Hardening (Future)

### S-02: Multi-tenancy / user compartmentalization
SSD volume isolation per user. Not needed until multiple users share the cluster.

### S-03: Compute prioritization
PriorityClass for critical agents; ResourceQuota per namespace; eviction policy for background jobs under GPU/NPU pressure.

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

### DOC-03: CONTRIBUTING.md
Contribution guide, issue templates, PR checklist.

### DOC-04: Jetson Orin Nano / CM4 support
Currently untested. Document gaps once hardware is available.

---

## Platform Hygiene

### PH-01: Remove application-specific knowledge from D-02

**Status:** TODO

The agent-deployment path violates the principle that tpi-bro should
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
2. Document the generic pattern instead of the specific application
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

### E-04: Affinity scheduling validation

**Status:** TODO — [BLOCKED on E-01 (KEDA + Redis), E-02 (capability labels, done)]

Dedicated test pass for the model affinity scheduling behaviour described in
ADR-0027. Specific test scenarios are defined (tracked separately by owner);
this item captures that a structured validation plan exists and must run before
affinity is considered production-ready.

At minimum the validation should cover:

- A warm-node hit: job arrives, a node already has the matching model loaded,
  scheduler places the job there without cold-start overhead.
- A cold-start fallback: no warm node available, job is placed on a cold capable
  node and completes correctly.
- A mixed queue: jobs for two different model types arrive in interleaved order;
  each is routed to the node holding the matching model rather than being
  shuffled across nodes.
- A saturated warm node: warm node is at capacity; job falls through to cold
  capable node rather than queuing behind the warm one.

Results should be recorded in a dedicated benchmark document with wall-clock
times for warm vs. cold placement.

### E-05: Orchestrator state management — single query model

**Status:** TODO — [BLOCKED on E-01, E-02 (done)]

The dispatcher that implements ADR-0026 (parallel dispatch) and ADR-0027
(affinity) needs to know — at dispatch time — which nodes are capable, which are
warm (model loaded), and which have free capacity. The design question is whether
to query all nodes individually at dispatch time or to rely on a single
authoritative state source.

k3s maintains all cluster state in etcd and exposes it via the Kubernetes API
server. A single `kubectl get pods,nodes --all-namespaces -o wide` (or
equivalent API call) returns everything needed in one round trip: node labels
(capability), pod labels (`tpi-bro/model-loaded`, `tpi-bro/interruptible`),
pod phase (Running/Pending/Succeeded), and resource requests vs. allocatable.

**Questions to investigate:**

1. Is the k3s API server the sufficient single state source, or does the warm-
   node label on a model-serving pod go stale before the pod actually has the
   model in DRAM? (Startup race: pod is Running but model load takes 25s.)
2. Should the dispatcher use a `watch` stream on pod and node events to maintain
   an in-process state cache, or re-query on every dispatch request?
3. At the current cluster size (4 nodes), does per-dispatch re-query latency
   matter? At what scale does a watch-based cache become necessary?
4. Does KEDA's internal state tracking (queue depth → replica count) overlap
   with anything a custom dispatcher would do, or are they entirely separate
   concerns?

**Expected output:** a documented dispatch query pattern (API call(s), fields
read, decision logic) that becomes the implementation contract for the dispatch
layer. No per-node SSH at dispatch time — a single API server query only.

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

**Status:** PARTIALLY UNBLOCKED — `tagx/whisper-stt:rknn` image exists and
validated on node1. Exact device nodes still unknown (see ADR-0023).

Extend `charts/whisper/` with an `rknn.enabled` flag that conditionally adds
NPU device mounts. Current validated approach uses `--privileged`; once ADR-0023
resolves the exact device nodes for DRM GEM mode, replace with an explicit
allowlist:

```yaml
# placeholder — to be updated once device nodes are confirmed
devices:
  - /dev/dri/renderD128   # likely the NPU render node (unconfirmed)
  - /dev/mpp_service      # Rockchip MPP (confirmed present)
```

With `rknn.enabled: false` (default) the chart deploys the CPU variant cleanly.
This pattern is reusable for any future RKNN-accelerated workload beyond Whisper.

**Note:** `/dev/rknpu` does NOT exist on this cluster (DRM GEM kernel mode).
Do not reference it in device mount lists.

### W-03: Self-attention KV cache for RKNN Whisper decoder

**Status:** TODO — cross-attention KV cache is done (validated numerically
identical to CPU, `tagx/images/whisper-stt/rknn/`); this remaining piece avoids
rescanning prior self-attention tokens each decode step for additional speedup,
but requires static-shape RKNN buffers for the growing cache. Defer until the
cross-attention KV path is validated on hardware and actual decode time is
measured (the compute-saving case for self-attention KV depends on where the
cross-attention win leaves the remaining bottleneck).

---

## NPU Characterization

The RK3588 NPU is characterized end-to-end in `docs/NPU-CHARACTERIZATION.md`
(framework), `docs/NPU-DATASHEET.md` (measured constants), and `tools/npu-bench/`
(reusable harness + calculator). The items below are deferred follow-ups.

### NC-01: Map the RK1 fan curve (thermal trip points)
**Status:** TODO

The TuringPi BMC controls the RK1 fan in **discrete speed steps** (≥2 steps
observed audibly during a CPU stress climb 42→62 °C). The NPU at 100% duty peaked
at 48 °C and never tripped even the first step (silent); CPU at 100% crossed two
steps. So the first fan trip is between **48 °C and ~62 °C**, second below 62 °C.

**Task:** slow CPU temperature ramp (step core count / frequency) with die temps
logged, correlated to the audible speed changes — and pull fan state/RPM from the
BMC via the `tpi` CLI if it exposes fan telemetry. Produces the actual trip
temperatures + the fan PWM curve. Operational relevance: CPU-bound batch STT
(faster-whisper) spins the fans; NPU encode stays silent — matters for noise-sensitive deployments.

### NC-02: Record CPU thermal + Whisper-per-minute into the datasheet
**Status:** TODO

`docs/NPU-DATASHEET.md` L7 currently has only the NPU thermal data. Add the
measured **CPU side** and the Whisper capability summary:
- RK1 CPU, 100% on 8 cores, 70 s: 42 → **62 °C (+20 °C)**, flat ~58 GFLOP/s, no
  throttle (vs NPU +4 °C). The CPU is the heat/noise source, not the NPU.
- **Whisper per minute of audio (medium, FP16):** ~195 s ≈ **3–4× slower than
  real-time**, decode-dominated (~90%); FP16 mandatory (INT8 broken, #314).
  **Optimised CPU faster-whisper (INT8) does medium at ~2× real-time — beats the
  NPU SA-KV decoder.** NPU's real Whisper value = the encoder (~2× CPU) or
  smaller models; `small` is the realtime tier (~1× realtime, first usable
  Swedish quality). See `tagx/mem/backlog/live-transcription-optimization.md`.

### NC-03: Remaining characterization gaps

- **INT8 #314 root cause — DIAGNOSED (2026-06-18).** INT8 breaks in the attention
  **softmax/SDPA path** (per-layer cosine 0.98→0.79 across blocks; FFN matmuls
  perfect at 0.999); error compounds over the stack → end-to-end collapse (94%
  zeros). Not the calibration data. Full writeup + repro + draft upstream comments:
  **`docs/RKNN-INT8-WHISPER-314.md`**. **Tracked open until airockchip fixes it
  upstream** (issue #314 is open, no maintainer response). Post the draft comments
  once this repo is public.
- **INT8 hybrid quantization (workaround) — validation in progress.** Keep
  attention/softmax in fp16, quantize the FFN to int8 via
  `hybrid_quantization_step1/step2` (run on **node2**, 32 GB — step1 alone is a
  ~30+ min quantization-analysis pass). Append measured results to the doc.
- **L6 manual double-buffering / non-blocking `rknn_run`** — `async_mode` gives
  no overlap; a lower-level frame-managed path might. Only worth it if a
  marshalling-bound workload needs it.

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
