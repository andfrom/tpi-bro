# tpi-bro Backlog

Ordered roughly by dependency / priority. Items with `[BLOCKED]` cannot start until their blocker is resolved.

Finished items are removed rather than kept as `DONE` markers — the historical
record lives in git history and commit messages, not here. This is a pure
TODO list.

---

## Phase C — Resilience + Laptop Mirror

### C-01: IP resilience for registry
**Status:** TODO  
Handle the case where `rk1-node1`'s DHCP lease changes. Options: static IP reservation on router, or CoreDNS custom entry in k3s. Largely mitigated already: the bootstrap configures static node IPs and everything laptop-side resolves by hostname.

Note (2026-08-15): **B-05/MetalLB was dropped** rather than being the answer here. Every job it would do is covered or moot on this cluster — service exposure belongs to the Tailscale operator, the registry is pinned to node1 by its local-SSD *storage* regardless of any VIP, node IPs are static, and the ADR-0028 queue boundary rides the Tailscale-routed ClusterIP. Revisit a LoadBalancer only if the registry ever gets node-independent storage or a non-Tailnet consumer appears.

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

---

## Event-Driven Scheduling (ADR-0022)

Per ADR-0028, this track is more than internal plumbing: the typed job
queue built here is the **sole boundary** between this cluster and any
external orchestrator or producer — the property that makes the cluster
usable as a decoupled, general execution tier. E-01 is therefore the head
of the whole track (and follows the bring-up orchestrator in sequencing).

**Design principle — focus is band rotation, never priority escalation.**
Priorities are a small fixed set of bands (`interactive`/`background`
today); a focus switch *reassigns* which task occupies which band — evict +
requeue the demoted task, admit the promoted one — and never increments a
value. This is what makes unbounded focus ping-pong between long-running
tasks safe: there is no counter to exhaust (the failure mode of
`nice`-style schemes where each switch must "up the ante"). Kubernetes
enforces the shape: `priorityClassName` is immutable on a running pod, so
escalation-in-place is impossible by construction, and preemption triggers
on strictly-higher priority only — equal-band work can never displace the
focused task. Two corollaries: long-running work must be resumable (chunked
through the queue; eviction loses at most a chunk), and focus must always
be expressed as a band *difference* — a dispatcher that enqueues "focused"
work at the running work's own band has silently broken switching (pinned
by an E-04 test scenario below).

### E-01: Deploy KEDA + Redis job queue

**Status:** DONE 2026-08-15 — kept briefly (contra the finished-items
convention) while E-04 still references it; remove when E-04 lands. Delivered: KEDA in
`keda`, Redis (`redis:7-alpine`, `requirepass`, appendonly, PVC on
`local-ssd`, `interactive` priority band) in `jobqueue` via
`charts/jobqueue`, one list key per job type + one `ScaledJob` per type,
demo `echo` type as the contract's reference implementation, and
`tests/check-cluster.sh` C19 asserting the full enqueue → scale-from-zero →
result roundtrip. Contract (envelope, results, at-most-once semantics, and
the producer obligation that all work be chunked/interruptible):
**ADR-0029**. Install/verify: `scripts/install-jobqueue.sh` (also a
`bootstrap-operational.sh` stage).

### E-04: Affinity scheduling validation

**Status:** IN PROGRESS (runnable subset) / partially blocked on E-07.
The band/priority scenarios (focus ping-pong without escalation, equal-band
inertness, background progress on slack) are runnable now against the E-01
queue + focus-demo machinery. The warm/cold affinity scenarios below require
warm-model routing to exist first — see E-07. E-03 and E-05 were closed by
**ADR-0030** (no dispatcher daemon; native preemption + TERM-trap requeue
supersede the eviction init container; `tpi-bro/interruptible` survives as
the safe-to-evict contract marker).

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
- **Focus ping-pong without escalation:** two long-running interruptible
  workloads, focus alternated between them N times (N ≥ 10). Assert that
  (a) every switch completes via eviction + requeue of the demoted task and
  admission of the promoted one, (b) the set of PriorityClass values in use
  never grows — priorities are the fixed bands, reassigned, never
  incremented (there is no "nice counter" to exhaust; see the band-rotation
  principle in the section preamble above), and (c) the demoted task still
  makes progress on leftover capacity (background is deprioritized, not
  suspended).
- **Equal-priority is inert:** dummy work admitted at the *same* band as
  the currently focused work never preempts it (k8s preempts on strictly
  higher priority only) — and, the flip side, a focus switch implemented
  without a band difference silently does nothing. The test pins both
  behaviors so a future dispatcher can't regress into same-band "focus"
  semantics.

Results should be recorded in a dedicated benchmark document with wall-clock
times for warm vs. cold placement.

### E-07: Warm-model affinity implementation

**Status:** TODO — created by ADR-0030 as the implementation half of
ADR-0027's design. Worker-written `tpi-bro/model-loaded=<model>` node labels
(set only AFTER the model is actually in memory — never inferred from pod
phase; advisory on crash-staleness), plus `preferredDuringScheduling` node
affinity in model-bearing job templates, plus the E-04 warm/cold validation
scenarios that unblock once this exists. Relates to E-06 (tagx image labels
could eventually feed the model identity automatically).

### E-06: Consume tagx's deployment-manifest image labels

**Status:** Future dev — not started, no urgency yet (single schema version,
single consumer chart).

tagx's ADR-0008 (`tagx/docs/adr/0008-deployment-manifest-image-labels.md`,
Proposed as of 2026-08-14, not yet implemented on tagx's side either) has
tagx publish OCI labels on each model-bearing image tag: `tagx.model`,
`tagx.requires-capability` (reusing this repo's own `tpi-bro/<capability>`
vocabulary from ADR-0022), `tagx.validated-date`/`-node`, and
`tagx.manifest-schema-version`. Nothing on this side reads them yet —
`charts/whisper/values.yaml`'s `rknn.enabled` boolean is still a manual
flag with no check that the target tag exists or matches the node.

Two separate pieces, only worth building once tagx actually ships the labels:

1. **Read `tagx.requires-capability` before scheduling** — query the tag's
   labels via the registry manifest API (no image pull needed), confirm the
   target node's `tpi-bro/<capability>` labels satisfy it, fail fast instead
   of deploying `--privileged` and finding out at runtime. Replaces the
   manual `rknn.enabled` boolean in `charts/whisper/values.yaml`.
2. **Auto-populate `tpi-bro/model-loaded` from `tagx.model`** — closes the
   gap in ADR-0027's model-affinity mechanism, which currently has no
   automated source for what a given image actually needs.

**Deferred, not decided here:** how this chart expresses "which
`tagx.manifest-schema-version` I can consume" — e.g. a version-constraint
field in `Chart.yaml`/`values.yaml` (exact key naming not decided),
mirroring how a chart already declares a `kubeVersion` constraint. Not worth
designing until there's a second schema version to actually negotiate
between; tagx's ADR-0008 explicitly leaves this open rather than speculating
on a compatibility-negotiation mechanism neither repo needs yet.

First consumer: Whisper STT (`charts/whisper/`) — both the CPU and RKNN
images now exist in tagx's registry (`tagx/whisper-stt:latest`,
`tagx/whisper-stt:rknn`), so labels have real tags to attach to whenever
tagx's ADR-0008 lands.

---

## Whisper STT

### W-03: Self-attention KV cache for RKNN Whisper decoder

**Status:** DONE except final measurement polish — root-caused, fixed, and
productionized 2026-08-14. The failure was never a silicon/scale limit:
librknnrt 2.3.2 silently never delivers NC1HWC2-native-layout graph inputs
on real RK3588, at any model size. The "input shim" (3D cache inputs,
unsqueezed in-model so they enter in linear layout) routes around it — full
story in `docs/RKNN-SA-KV-DECODER-BUG.md`.

Productionized same day:
- Shim is the canonical export (`_DecoderSAKVStepShim` in tagx
  `export_onnx.py`; `convert_rknn.py` shapes updated); canonical
  re-export/convert deployed to node1
  (`whisper_decoder_sa_kv_step_medium.rknn`, replacing the broken 4D
  artifact) and validated on hardware (cosine 0.999951 + fingerprint
  "caches DELIVERED" + correct real-audio transcript).
- `charts/whisper/` gained `rknn.decoder: sa-kv` (command override to
  `infer_rknn_sa_kv.py`, XA-KV/SA-KV env wiring, `WHISPER_SA_KV_SHIM=1`);
  the `tagx/whisper-stt:rknn` image now ships the SA-KV driver.
- FP16 input feeds implemented (`--fp16-feeds`) and fingerprint-verified:
  measured **~1.10×** (2,027 → 1,834 ms/step) — NOT the ~1.5× projected by
  tagx's live-transcription notes (that number came from a deleted script
  and doesn't reproduce through `rknnlite.inference()`; a genuine 1.5×
  likely needs the zero-copy/pass-through C-API path). Default off; enable
  per-run with the flag or `WHISPER_SA_KV_FP16_FEEDS=1`.

Bottom line: SA-KV decode is ~2.5× the naive decoder (2.0 s/step vs
5.0 s/step, medium; ~1.8 s/step with fp16 feeds). Remaining ideas beyond
this (zero-copy I/O, smaller live-tier models) belong to tagx's
live-transcription program, not this repo.

### W-04: Publish prebuilt RKNN model artifacts (verified distribution)

Converting Whisper models to RKNN requires an x86 host, the vendor
toolkit, and (for large models) hours of conversion time — most users of
this repo will want prebuilt binaries. Decided distribution model:

- **Bytes on Hugging Face Hub** (purpose-built for multi-GB model
  binaries: free bandwidth, LFS sha256 per blob, resumable downloads,
  discoverable). Artifacts are pinned to runtime + target — name per
  `librknnrt` version and SoC (e.g. `*-rknnrt2.3.2-rk3588.rknn`).
  Whisper is MIT-licensed; redistribution of derivatives is clean.
- **Trust anchored in git, not next to the download**: SHA-256 for every
  artifact is pinned in a committed manifest, and the chart's model-fetch
  path verifies the hash before use. A checksum beside the download
  protects nothing; a checksum in the repo the user already cloned is a
  second channel — the binary can then come from any mirror.
- Personal/project web pages link the HF repo and display the pinned
  hashes (a third channel), but never serve the bytes.

Work: create the HF model repo, upload encoder/decoder + manifest per
model, pin hashes in the tagx/tpi-bro manifests, add hash verification to
the model-fetch path, document in the whisper chart README.

Scope note (2026-08-15): **medium only.** large-v3 converts but cannot be
initialized on the hardware — `rknn_init` allocates >12× the model size
(20.9 GB measured for the 1.77 GB decoder) and, uncapped, wedges the node
(see `HARDWARE-FIRMWARE-ISSUES.md`). Don't publish artifacts users can't
run.

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
(faster-whisper) spins the fans; NPU encode stays silent — matters for
noise-sensitive deployments.

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
Validated 2026-05-12: llama3.2:1b on CPU produces unreliable structured
output (a falsely-confident result on two clearly-mismatched test inputs);
the model is too small to reliably follow multi-step evaluation
instructions. A 7B model on NPU is the minimum viable path.

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
a single RK1 node, and process one item end-to-end. This answers the four open
questions (model family support, JSON output stability, conversion toolchain,
single-node latency) without touching the cluster configuration.

**What the full investigation involves:**
1. Model conversion — export `llama3.2:1b` (then 7B) to RKNN format using the
   rknn-llm toolkit on the laptop; verify output on one RK1 node
2. Runtime deployment — build or pull a container image with the RKNN runtime
   + rkllm-server; deploy as a Kubernetes Deployment on an NVMe node with the
   RKNN device node (`/dev/rknpu`) mounted
3. Benchmark — compare tokens/second and end-to-end processing latency vs. current
   CPU-only Ollama baseline; verify output quality with a 7B model
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
