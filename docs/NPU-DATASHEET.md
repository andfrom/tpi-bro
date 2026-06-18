# RK3588 NPU Datasheet (measured)

Lookup table of measured device constants, produced by `tools/npu-bench/` and
interpreted via `NPU-CHARACTERIZATION.md`. Cite these cells in architecture
decisions instead of re-measuring.

**Environment:** RK1 (RK3588), librknnrt 2.3.2, rknpu driver 0.9.7, kernel
6.1.0-1025-rockchip, rknn-toolkit2 2.3.2. Layer tag for all rows below:
**silicon × runtime(2.3.2) × toolchain(2.3.2)** — re-measure on a version bump.

## Layer 1 — compute ceiling, FP16 (measured 2026-06-18)

Achieved GFLOP/s = `2·M·K·N / run` (best-of-10). `run` is pure NPU compute.

| Kernel | Cores | run (ms) | GFLOP/s | 3-core speedup |
|---|---|---|---|---|
| matmul 256³ | auto | 0.42 | 80 | — |
| matmul 256³ | 0_1_2 | 0.46 | 74 | 0.9× (overhead > work) |
| matmul 512³ | auto | 1.57 | 172 | — |
| matmul 512³ | 0_1_2 | 1.39 | 198 | 1.1× |
| matmul 1024³ | auto | 16.2 | 133 | — |
| matmul 1024³ | 0_1_2 | 12.3 | 175 | 1.3× |
| matmul 2048³ | auto | 138.9 | 124 | — |
| matmul 2048³ | 0_1_2 | 75.6 | **228** | 1.8× |
| conv 64×32² k3 | auto | 0.15 | 516 | — |
| conv 64×32² k3 | 0_1_2 | 0.11 | 707 | 1.4× |
| conv 64×64² k3 | auto | 0.47 | 646 | — |
| conv 64×64² k3 | 0_1_2 | 0.27 | 1128 | 2.4× |
| conv 64×128² k3 | auto | 1.83 | 665 | — |
| conv 64×128² k3 | 0_1_2 | 0.83 | **1474** | 2.2× |

**Headline FP16 ceilings:** conv **~1.5 TFLOP/s** (3-core) — the real NPU peak;
matmul only **~230 GFLOP/s** (3-core) — ~6× lower.

### INT8 vs FP16 (3-core GFLOP/s, measured 2026-06-18)

| Kernel | FP16 | INT8 | INT8/FP16 |
|---|---|---|---|
| matmul 1024³ | 175 | 551 | **3.1×** |
| matmul 2048³ | 228 | 564 | 2.5× |
| conv 64² | 1139 | 1764 | 1.5× |
| conv 128² | 1338 | **2287** | 1.7× |

**INT8 peak ≈ 2.3 TFLOP/s** (conv, 3-core) vs 1.5 for FP16. INT8 helps matmul
most (~2.5–3×, since its FP16 path is so inefficient), conv ~1.5–1.7×. All INT8
compute + op kernels **executed without the #314 empty-output failure** — but
these use random calibration, so this validates INT8 **speed only**. Numerical
correctness (#314) must still be checked on a real workload with real
calibration data (Whisper is the validation case).

## Layer 2 — memory bandwidth + ridge point (measured 2026-06-18)

FP16 elementwise add (4D NCHW); GB/s = actual on-device bytes (3·S·2) ÷ run.

| Kernel (4D add) | elems | Cores | run (ms) | GB/s |
|---|---|---|---|---|
| 64×128² | 1.0 M | auto | 1.26 | 5.0 |
| 64×128² | 1.0 M | 0_1_2 | 0.76 | 8.5 |
| 128×256² | 8.4 M | 0_1_2 | 4.0 | 12.7 |
| 256×256² | 16.8 M | 0_1_2 | 7.67 | **13.2** |

**Achievable elementwise bandwidth ≈ 13 GB/s** (3-core, large tensors;
asymptotic as fixed overhead amortizes). Well below LPDDR5 theoretical peak —
elementwise ops are bandwidth-starved on the NPU datapath, not DRAM-limited.
3-core roughly doubles bandwidth too.

**INT8 bandwidth (3-core):** 8.2 / 12.0 / 12.6 GB/s for the 1.0 / 8.4 / 16.8 M
adds — i.e. the **GB/s ceiling (~13) is precision-independent** (it's a datapath
limit). But INT8 moves half the bytes, so bandwidth-bound ops still get ~**1.8×
wall-time** (16.8 M add: 7.42 ms FP16 → 4.03 ms INT8). Two distinct precision
levers: compute-bound ops gain from INT8's higher TOPS; bandwidth-bound ops gain
from fewer bytes against the same GB/s wall.

**Ridge point (FP16)** = conv peak ÷ bandwidth = 1474 GFLOP/s ÷ 13.2 GB/s ≈
**110 FLOP/byte**. Any kernel below ~110 FLOP/byte is memory-bound. (matmul 2048³
has AI ≈ 680 FLOP/byte → compute-bound, yet hits only 228 GFLOP/s — so its
shortfall is path inefficiency, not bandwidth.)

## Layer 4 — operator support map (measured 2026-06-18)

| Op | fp16 converts? | runs? | run (ms) | Notes |
|---|---|---|---|---|
| MatMul | ✅ | ✅ | — | works but inefficient (~230 GFLOP/s peak) |
| Conv | ✅ | ✅ | — | saturates NPU (~1.5 TFLOP/s) |
| Add (4D) | ✅ | ✅ | — | bandwidth-bound; **flat (1,S) shape is pathological — use 4D** |
| Softmax | ✅ | ✅ | 0.84 | no 3-core gain |
| Transpose | ✅ | ✅ | 0.36 | layout op |
| Gather (scalar idx) | ✅ | ✅ | 0.05 | very cheap — positional-embedding lookup |
| Sigmoid | ✅ | ✅ | 0.83→0.17 | 3-core helps (4.9×) |
| **ScatterND (dynamic idx)** | ✅ | **❌** | — | converts but emits garbage — tagx ADR-0003 |

## Layer 6 — async overlap (measured 2026-06-18)

Does `init_runtime(async_mode=True)` overlap host marshalling with NPU compute?
Steady-state per-frame wall-time, sync vs async, via `async_test.py`:

| Kernel | set+get (host) | run | sync/frame | async/frame | speedup |
|---|---|---|---|---|---|
| matmul 2048³ | 27.7 ms | 75.7 ms | 106.0 | 103.0 | 1.03× |
| conv 64×128² | 14.1 ms | 1.1 ms | 15.2 | 15.2 | 1.00× |
| add 256×256² | 533.7 ms | 7.2 ms | 532.9 | 533.6 | 1.00× |

**Finding: `async_mode` gives no overlap** via rknnlite's `inference()`. Per-frame
cost stays at the serial sum `set_inputs + run + get_outputs`. To hide marshalling
behind compute you must either (a) eliminate marshalling with the zero-copy
resident-I/O path, (b) double-buffer manually with threads, or (c) pipeline
across *separate* contexts/nodes. Single-context async is not a lever.

(Note: a lower-level non-blocking `rknn_run` + frame management might overlap,
but the high-level `inference()` async flag does not.)

## Layer 3 — fixed overhead / latency floor (measured 2026-06-18)

Trivial single-input Sigmoid swept ~4 B → 2 MB (FP16, single core), phase-split:

| Kernel | in+out bytes | set (ms) | run (ms) | get (ms) | total |
|---|---|---|---|---|---|
| 1×1×1 | 4 | 0.07 | 0.06 | 0.07 | 0.20 |
| 1×16² | 1 K | 0.07 | 0.06 | 0.07 | 0.20 |
| 1×64² | 16 K | 0.11 | 0.11 | 0.11 | 0.33 |
| 1×128² | 64 K | 0.25 | 0.26 | 0.23 | 0.74 |
| 8×128² | 512 K | 1.41 | 0.18 | 0.92 | 2.51 |
| 32×128² | 2 M | 5.46 | 0.65 | 3.43 | 9.54 |

- **Fixed per-inference floor ≈ 0.20 ms** (size→0): ~60 µs NPU `run` dispatch +
  ~70 µs `set_inputs` + ~70 µs `get_outputs`. No op goes below this.
- **NPU `run` dispatch floor ≈ 60 µs** — the cost of launching any kernel.
- **Marshalling rate (native FP16, no dtype conversion):** `set_inputs` ~190 MB/s,
  `get_outputs` ~300 MB/s. Far below DDR — so the slow host path is the
  **layout transpose + copy itself**, not dtype conversion. Feeding native dtype
  removes only the *extra* conversion penalty; this floor remains. Only zero-copy
  resident I/O beats it.

## Wall-clock calculator — validated against Whisper (`calculator.py`)

Composes the constants above into a serial wall-clock prediction for any kernel
DAG, then checks it against the directly-measured Whisper medium numbers:

| Stage | roofline (eff=1) | measured | ratio | with derate | regime |
|---|---|---|---|---|---|
| encoder | 8489 ms | 10373 ms | 0.82 | 10350 ms (eff=0.82) → **1.00** | compute-bound |
| decoder step | 179 ms | 897 ms | 0.20 | 881 ms (eff=0.18) → **0.98** | memory-bound |
| set_inputs (fp32) | 998 ms | 1001 ms | **1.00** | — | host marshalling |
| set_inputs (fp16) | 344 ms | 344 ms | **1.00** | — | host marshalling |

**Reading the validation:**
- **Compute-bound stages predict directly.** The encoder (large matmuls, M=1500)
  lands within 18% of the raw roofline — the device model is accurate here.
- **The roofline is a lower bound for autoregressive decode.** A single-token step
  is memory-bound (streaming ~810 MB of weights as M=1 GEMV) and runs at only
  ~0.18 of clean-kernel efficiency — the cost of GEMV + hundreds of tiny ops on a
  conv-optimised NPU. Use an empirical per-class efficiency derate for such
  workloads; the raw roofline tells you the *best case*.
- **Marshalling predicts to 1.00** at ~557 MB/s bulk native rate (with a 1.45×
  per-byte penalty when feeding fp32 into an fp16 model). Confirms the FP16-input
  win and that resident I/O is the only way past the host path.

## Derived design rules (measured)

- **Prefer conv-shaped compute over matmul** on RK3588 — the matmul→exmatmul path
  underutilizes the NPU ~6×. A workload expressible as conv hits the real ceiling.
- **3-core scaling is op-size dependent:** large compute-bound ops get 1.8–2.4×;
  small ops (256³ matmul) get <1× (dispatch overhead dominates). Matches the
  Whisper single-token decode finding (1.07× on 3 cores — too small to scale).
- **FP16 compute peak ≈ 1.5 TFLOP/s; INT8 ≈ 2.3 TFLOP/s** (both conv, 3-core).
  INT8 gives ~1.5–1.7× on conv and ~2.5–3× on matmul — quantization is the
  bigger lever for matmul-heavy graphs. Weigh against accuracy + #314 risk.
- **INT8 executes fine** (no empty-output failures here) but #314 is about
  *numerical* correctness — validate on a real model before trusting INT8 output.
