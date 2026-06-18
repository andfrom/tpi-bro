# RK3588 NPU Characterization Framework

**Purpose:** a device-level (not model-level) performance model of the RK1's
RK3588 NPU, so that for *any* future workload — any model, any agent, any
compute task — we can answer two questions **before building anything**:

1. **Feasibility** — can this run on the NPU at all, and at what precision?
2. **Speed-at-precision** — what inference rate / latency will it achieve at
   INT8 vs INT16 vs FP16, for both serialized and parallelized execution?

This generalizes the Whisper investigation (see "Validation workload" below)
into a reusable apparatus. It is the classic **roofline model** of an
accelerator, extended with the overhead, operator-support, concurrency, and
thermal terms that actually bite on this stack.

> Companion docs: `NPU-MODELS.md` (how to run LLM/Whisper models),
> `mem/adr/ADR-0023` (NPU device access). This doc is the *why-it-is-fast-or-slow*
> layer underneath both.

---

## The mental model

Any workload is a DAG of kernels, each described by `(FLOPs, bytes_moved,
op_type, precision)`. Device characterization measures the constants that turn
that description into a wall-clock prediction:

```
kernel_time = max( FLOPs / peak_compute[precision] ,   ← compute-bound branch
                   bytes / bandwidth[mem_level]    )    ← memory-bound branch
            + fixed_overhead                            ← dominates tiny kernels

workload_time(serial)   = Σ kernel_time   along the critical path
workload_time(parallel) = serial_time / scaling_efficiency(kind, width)
                           — or pipelined max(stage) if stages overlap
            × thermal_derate(sustained?)
```

The **ridge point** = `peak_compute[precision] / bandwidth` (in FLOPs/byte). A
kernel's arithmetic intensity (FLOPs/byte) relative to the ridge point tells you
which branch wins — *before you run it*. This is the single most useful number
the characterization produces.

---

## The seven characterization layers

Each layer is a battery of measurements. "Speed at which precision" is layers
1–2; "can/cannot" is layer 4.

### Layer 1 — Compute ceilings (one roofline per precision)

Peak sustained MAC/s for each precision the NPU supports, per-core and aggregate
across 3 cores.

| Precision | Nominal peak (RK3588, 3-core) | Status |
|---|---|---|
| INT8  | ~6 TOPS | datasheet; measure to confirm |
| INT16 | ~3 TOPS (est) | measure |
| FP16  | fraction of INT8 (est ~1–2 TOPS) | measure — **this is the wall for non-quantized models** |
| FP32  | not natively supported | "non-quantized" RKNN = FP16 internal, not FP32 |

- **Method:** synthetic compute-bound ONNX kernel — large square matmul/conv with
  high data reuse (operands fit in SRAM), swept in size until MAC/s saturates.
  Run per precision via the conversion config.
- **Yields:** the horizontal roofline(s). Directly answers "speed at precision P"
  for compute-bound work.

### Layer 2 — Memory ceilings (roofline slopes)

Bandwidth at each level of the hierarchy.

| Path | What it bounds | Method |
|---|---|---|
| LPDDR5 DRAM | weight/activation streaming for low-reuse kernels | elementwise op over large buffer, swept size |
| NPU SRAM (6 MB) | per-layer compute buffer reuse | small-buffer bandwidth-bound kernel |
| host↔NPU (runtime marshalling) | input/output transfer per inference | vary I/O size, measure `set_inputs`/`get_outputs` |

- **Key finding so far:** the host↔NPU path via `rknnlite` runs at **~383 MB/s**
  when it must convert dtype/layout — ~50–100× below raw DDR. This is *conversion
  cost*, not bandwidth. Feeding inputs already in the model's native dtype removes
  it (see validation workload).
- **Yields:** the diagonal roofline(s) and the ridge point.

### Layer 3 — Fixed overheads / latency floors

Per-`rknn_run` dispatch, DMA setup, kernel-launch, runtime call overhead.

- **Method:** shrink a kernel toward ~0 FLOPs and ~0 bytes; the residual time is
  the floor. Separately vary I/O size to split fixed vs per-byte cost.
- **Why it matters:** small workloads (e.g. single-token autoregressive decode)
  are **overhead + memory bound, never compute bound**. This is why batching and
  operator fusion matter, and why "6 TOPS" is irrelevant to a 1-token step.

### Layer 4 — Operator support & fallback map (the "can/cannot" oracle)

For each op type: native on NPU? at what efficiency vs the Layer-1 ceiling? or
forced CPU fallback (which adds a host round-trip + sync)?

| Op | NPU native? | Notes |
|---|---|---|
| MatMul / Conv2D / DWConv | yes | the bread and butter; near-ceiling with reuse |
| Softmax / LayerNorm | yes | |
| Gather (scalar index) | yes | used for positional embedding lookup |
| **ScatterND (dynamic index)** | **NO — silently wrong** | compiler accepts it, runtime emits garbage (`E RKNN: Unkown op target: 0`). See tagx ADR-0003. Use host-side scatter. |
| Elementwise (add/mul/etc.) | yes | bandwidth-bound |
| Transpose / Reshape | yes, but triggers layout conversion | NCHW↔NC1HWC2/NHWC has real cost |

- **Method:** synthetic single-op ONNX models (the technique used for ScatterND);
  read the compiler's op-assignment log, then measure. Build the table op by op.
- **Yields:** the feasibility oracle. *This is what lets you say "no" before
  wasting a conversion cycle.*

### Layer 5 — Precision & numerics boundaries (correctness, not speed)

| Boundary | Value | Consequence |
|---|---|---|
| FP16 dynamic range | max ±65504 | large masks/logits overflow to ±inf (e.g. `-1e9` mask → `-inf`; harmless for softmax, fatal elsewhere). Use `-65504` or `-3e4`. |
| INT8 quantization | per-tensor/per-channel error | accuracy loss; **currently broken for some graphs** (empty output — airockchip/rknn_model_zoo#314). FP16 mandatory until fixed. |
| Determinism | TBD | measure run-to-run bit-stability if an agent needs reproducibility |

- **Method:** range-stress kernels; compare NPU output to a CPU/FP64 reference;
  repeat-run diff for determinism.

### Layer 6 — Concurrency & scaling laws (the serial-vs-parallel answer)

Linear scaling never holds; each kind needs a *measured* efficiency.

| Parallelism kind | Question | Finding so far |
|---|---|---|
| Intra-op multi-core | does 1 op spread across 3 cores? | **op-size dependent.** Single-token decode: 1.07× on 3 cores (useless). Large ops (encoder): untested, expected better. |
| Inter-context | 2+ models sharing the NPU — halved each, or scheduled? | untested — decides node allocation |
| Async overlap | can host marshalling of step N+1 overlap NPU compute of step N? | **untested, high-leverage** — turns serial *sum* into pipelined *max*. `rknnlite` exposes `async_mode`. |
| Multi-node (4× RK1) | shard across nodes | interconnect-bound — separate domain |

- **Method:** sweep core_mask per op size; run concurrent contexts and measure
  mutual slowdown; enable async_mode and check for overlap; for multi-node,
  characterize the network path (bandwidth/latency of activation transfer).
- **Yields:** the scaling-efficiency curves the parallel cost model needs.

### Layer 7 — Sustained / thermal (DVFS)

Burst peak vs steady-state under continuous load; the throttle curve and time
constant.

- **Method:** sustained-load loop measuring throughput over minutes; read NPU
  clock from `/sys/class/devfreq/` and temps from thermal zones.
- **Yields:** the derate factor long-running agents actually live on.

---

## Stability layering — what ages, what doesn't

Tag every measured constant by the layer that owns it, so a version bump only
invalidates the affected rows:

| Layer | Examples | Changes |
|---|---|---|
| **Silicon** | TOPS/precision, DRAM/SRAM bandwidth, thermal | never (fixed for RK3588) |
| **Driver** | rknpu kernel version (0.9.7) | rarely |
| **Runtime** | librknnrt marshalling rate, async behavior | per `.so` version (currently 2.3.2) |
| **Toolchain** | rknn-toolkit2 op support, INT8 #314, 2 GB protobuf limit | most often |

---

## The predictive calculator (how to use this)

Given a proposed workload:

1. **Decompose** into kernels: `(FLOPs, bytes, op_type, precision)` each.
2. **Feasibility:** every op in the Layer-4 map? If an op falls back to CPU, add
   the round-trip; if unsupported, redesign (e.g. host-side scatter).
3. **Per-kernel time:** compute arithmetic intensity, compare to the ridge point,
   take the binding branch, add the Layer-3 overhead.
4. **Serial:** sum along the critical path.
5. **Parallel:** divide by the measured Layer-6 efficiency for the relevant kind,
   or take pipelined `max(stage)` if async overlap applies.
6. **Derate** by Layer-7 thermal for sustained operation.
7. **Capacity check:** weights + activations + caches fit in 32 GB DRAM; watch
   toolchain limits (2 GB protobuf on conversion).

Express this as a small spreadsheet/script once the datasheet rows are filled.

---

## Validation workload — Whisper (seed data)

Whisper is the reference workload that validates the model: we predict its
numbers from the device characterization and check against measurement. Current
measured cells (medium, FP16, single core, librknnrt 2.3.2):

| Stage | Phase | Measured | Layer it exercises |
|---|---|---|---|
| Decoder step | `set_inputs` (FP32 in) | 1001 ms | L2 host-path conversion |
| Decoder step | `set_inputs` (FP16 in) | **344 ms** | L2 — conversion removed, 1.5× total win |
| Decoder step | `run` | **897 ms** | **L1 FP16 compute floor** |
| Decoder step | `get_outputs` | ~25 ms | L2 retrieval |
| Decoder step | 3-core `run` | 836 ms (1.07×) | L6 intra-op scaling (poor for 1-token) |
| Encoder (30 s window) | full | 10.4 s | L1 + L2 (big compute) |

**What it already taught us (generalizable):**
- The decode step is **compute-bound on the FP16 ceiling (L1)**, not transfer-bound
  — so I/O tricks (resident memory, FP16 inputs) have a hard ~1.9× ceiling and
  cannot substitute for a smaller model or INT8.
- Model I/O boundary dtype is **queryable before running** (`get_tensor_attr` →
  FP16/NHWC); matching it removes most marshalling cost. General rule: always feed
  native dtype/layout.
- 3-core helps big ops, not tiny ones — confirm per stage, never assume.

Open Whisper-specific cells (cost-table to fill) live in tagx
`mem/backlog/live-transcription-optimization.md`.

---

## Open characterization tasks (priority order)

1. **L1 per-precision ceilings** — synthetic matmul sweep at INT8/INT16/FP16,
   1-core and 3-core. The core "speed at precision" table.
2. **L4 operator map** — systematic single-op probes; build the support/efficiency
   table. The feasibility oracle for any future agent.
3. **L2 ridge point** — DRAM + SRAM + host-path bandwidth; compute the ridge.
4. **L6 async overlap** — does `async_mode` overlap marshalling with compute?
   (Potentially turns serial-sum into pipelined-max — large structural lever.)
5. **L3 fixed overhead** — the latency floor for tiny kernels.
6. **L7 thermal derate** — sustained-load throttle curve.
7. **Build the calculator** — spreadsheet/script composing the above; validate
   against the Whisper seed cells.

---

## Reusable harness (planned)

A parametrized microbenchmark tool that emits structured rows (JSON/CSV) into a
living datasheet:

```
npu-bench --kernel matmul --precision int8 --size 1024 --cores 3 --runs 50
npu-bench --op scatternd --dynamic-index   # feasibility probe
npu-bench --bandwidth --buffer-mb 256
```

Each cell is one command, re-runnable when silicon/driver/runtime/toolchain
versions change. Output accumulates into `docs/NPU-DATASHEET.md` (the lookup
table architecture decisions cite). Harness does not exist yet — this doc is the
spec for it.
