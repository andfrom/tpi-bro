# RKNN silently never delivers NC1HWC2-native-layout graph inputs on real RK3588

Root-cause investigation for a bug found implementing W-03 (self-attention KV
cache for the RKNN Whisper decoder). **Root-caused and worked around
2026-08-14 (second pass, same day):** on real RK3588 hardware, any graph
input that the compiled `.rknn` model expects in the NPU's native tiled
`NC1HWC2` layout is **silently never delivered — the buffer stays
zero-filled** — while all linear-layout inputs arrive correctly. No error or
warning is produced at any log level, in userspace or the kernel. The x86
simulator delivers everything correctly, so the vendor's own testing story
cannot see this bug. A one-op graph change (the "input shim", below) routes
around it completely; the full 24-layer SA-KV decoder now produces correct
transcripts on hardware.

**This document supersedes its own first revision from earlier the same
day**, which claimed a scale-dependent failure appearing "beyond ~18 layers"
and a "validated 2×12-layer split-decoder workaround." Both claims were
wrong, and *how* they were wrong is half the value of this writeup — see
"The false trail" below. The git history preserves the first revision.

## Environment

- rknn-toolkit2 2.3.2 (conversion, x86), rknn-toolkit-lite2 2.3.2 + librknnrt 2.3.2 (device), RKNPU driver 0.9.7, kernel 6.1.0-1025-rockchip, RK3588 (TuringPi RK1), IOMMU mode
- Whisper medium SA-KV decoder (`_DecoderSAKVStep`, tagx `export_onnx.py --mode sa-kv`): 99 graph inputs — token, step, sa_mask, 48 SA-cache tensors `(1,16,448,64)`, 48 cross-attention tensors `(1,1500,1024)`

## The defect, precisely

The RKNN compiler assigns each graph input a layout based on its first
consumer:

| Input | First consumer | Assigned layout | Delivered on real HW? |
|---|---|---|---|
| `token`, `step` | Gather | UNDEFINED (linear) | ✓ |
| `xa_k_*`, `xa_v_*` (48×) | Reshape | UNDEFINED (linear) | ✓ |
| `sa_mask` | Conv — but via a compiler-inserted on-device `New_input` Transpose | linear at the boundary | ✓ |
| `sa_k_in_*`, `sa_v_in_*` (48×) | Concat, directly | **NC1HWC2 (native tiled)** | **✗ — read as zeros** |

The NC1HWC2 inputs require a host-side tiling conversion inside
`rknn_inputs_set`. That conversion silently produces nothing on this stack:
the graph then executes *perfectly* (per-op profiling shows the Concats
running on the NPU with normal timing and full-size reads) over buffers that
were never written. This holds at **every model size tested — including a
1-layer, 7-input model** — so it is not a resource/limit issue at all.

## How it was proven: hypothesis fingerprinting

The decisive instrument (committed as tagx
`images/whisper-stt/rknn/debug/fingerprint_cache_delivery.py`): capture the
raw step-1 hardware outputs, then replay the exact same inputs through the
proven-correct PyTorch reference under explicit corruption hypotheses and
ask which one the hardware actually matches.

At 24 layers (fresh build, real speech audio):

| hypothesis | logits cos vs HW | mean per-layer k_new cos |
|---|---|---|
| correct computation | -0.17 | 0.87 |
| **all caches read as zeros** | **0.9996** | **0.9992** |
| mask stuck at step-0 | 0.71 | 0.73 |
| mask ignored | -0.52 | 0.12 |

The hardware isn't computing noise — it is computing the **exact model
function with the cache inputs replaced by zeros**. The same fingerprint wins
at every depth tested (1, 12, 18, 21, 23, 24 layers), for both the
June-era production artifact and fresh rebuilds.

Everything else that pointed elsewhere was ruled out en route: input dtype
(values never read can't matter), mask magnitude (same), output ordering
(cross-correlated all 49 outputs — declared order is correct), ONNX graph
connectivity (all inputs consumed), the isolated attention op and the
Concat-including variant (both bit-correct in the simulator), the June
artifact's provenance (fresh builds fail identically), kernel-side CMA/DMA
failures (none — dmesg silent, IOMMU mode), and the runtime's own
memory-table layout (identical strategy in passing and failing configs).

## The false trail — and why the first revision got it wrong

The first investigation used "cosine vs the correct reference at decode
step 1" as its pass/fail test, which produced this table on real hardware:

| layers | cosine vs correct | first-pass verdict |
|---|---|---|
| 12 | 0.9995 | "PASS" |
| 18 | 0.9992 | "PASS" |
| 21 | 0.9975 | "PASS-ish" |
| 23 | 0.9081 | partial failure |
| 24 | -0.586 | total failure |

It looks exactly like a scale-dependent hardware limit appearing between 18
and 24 layers. It isn't. **The caches are dead at every one of those
depths** — the fingerprint shows "all dead" beating "none dead" at 12, 18,
21, 23 and 24 alike. What actually varies with depth is only the *distance
between the all-dead and correct trajectories* at step 1: with one cached
token, a shallow stack barely diverges (0.9995 ≈ indistinguishable from
FP16 noise), a deep stack diverges wildly. The "threshold" was the
statistical power of a weak test, not a property of the hardware. This is
also why the first revision's "validated 2×12 split-decoder workaround" was
invalid: the 12-layer halves it validated were exactly as cache-dead as the
full model; the validation test just couldn't see it.

Lesson worth keeping: *a correctness test whose sensitivity varies with the
thing you're bisecting will hand you a beautifully convincing, entirely
fictional threshold.* Fingerprint against explicit failure hypotheses
instead of measuring distance-from-correct.

## The fix: the input shim

If NC1HWC2-at-the-boundary is what breaks, don't let any input be
NC1HWC2-at-the-boundary. `_DecoderSAKVStepShim` (tagx
`debug/minimal_repro_nlayer.py`) accepts the caches as 3D
`(n_head, n_ctx, head_dim)` and unsqueezes to 4D *inside* the model. The
input's first consumer is then a shape op, the compiler assigns linear
layout, the host-side copy becomes a plain memcpy, and the NC1HWC2
conversion happens on-device — where it demonstrably works.

Validated end-to-end on real hardware, 2026-08-14:

| test | result |
|---|---|
| 2-layer shim, fingerprint | "none dead" wins (0.9997 / 1.0000); "all dead" collapses to 0.44 |
| **24-layer (full) shim vs reference** | **cosine 0.999951, top-5 tokens identical** |
| 24-layer shim, real speech, full driver (`infer_rknn_sa_kv.py --shim`) | transcript: **"The quick brown fox jumps over the lazy dog."** — correct |

Decode speed with the shim: ~2,028 ms/step (FP32 host feeds; ~1,834 ms/step
with `--fp16-feeds`), vs ~5,009 ms/step for the naive full-recompute
decoder — **~2.5× measured**. The canonical artifact (built by the
productionized `export_onnx.py`/`convert_rknn.py` shim pipeline, same graph)
lives on node1 at
`/mnt/ssd/whisper-models/rknn/medium/whisper_decoder_sa_kv_step_medium.rknn`,
replacing the broken 4D build.

## Minimal upstream repro

A **1-layer, 7-input** model (`debug/minimal_repro_nlayer.py --layers 1
--export-rknn m.rknn` + `debug/real_hw_check.py`) reproduces the full
defect: hardware cosine 0.40 vs correct, fingerprint matches all-dead at
0.9955. Nothing about model size, input count, or memory pressure is
involved. Not yet filed upstream (gated on this repo going public, same as
the INT8 report — see `RKNN-INT8-WHISPER-314.md`'s vendor-response tracker
for why expectations are low); no matching known issue found
([airockchip/rknn-toolkit2#460](https://github.com/airockchip/rknn-toolkit2/issues/460)
is the nearest neighbor — same toolkit/target, attention-related accuracy
loss, no maintainer response).

## Reproduction toolkit (tagx `images/whisper-stt/rknn/debug/`)

- `test_sa_kv_reference.py` — PyTorch-only correctness of the exported module (bit-perfect).
- `minimal_repro_attn.py`, `minimal_repro_attn_concat.py` — isolated-op simulator repros (both correct; the bug is not in the op).
- `minimal_repro_nlayer.py --layers N [--n-ctx C] [--input-shim] [--export-rknn out.rknn]` — real-weights N-layer slice: simulator run, or hardware-loadable export + exact test inputs/reference.
- `real_hw_check.py --rknn m.rknn --testdata t.npz [--save-outputs hw.npz]` — device-side check + raw-output capture.
- `fingerprint_cache_delivery.py --layers N --testdata t.npz --hw-outputs hw.npz` — the corruption-hypothesis matcher; the tool that cracked this.

## Status

**W-03 fixed and productionized (2026-08-14).** The shim is the canonical
export form (`_DecoderSAKVStepShim` in tagx `export_onnx.py`;
`convert_rknn.py` updated to match); a canonical re-export/convert was
deployed to node1 as `whisper_decoder_sa_kv_step_medium.rknn` (replacing
the broken 4D artifact) and validated on hardware — cosine 0.999951,
fingerprint "caches DELIVERED", correct real-audio transcript through both
the bare driver and a full `charts/whisper/` Kubernetes Job
(`rknn.decoder: sa-kv`). FP16 input feeds (`--fp16-feeds`) were also
fingerprint-verified: measured ~1.10× (2,027 → 1,834 ms/step), notably
below the ~1.5× projected in tagx's live-transcription notes — that
projection came from a deleted script and does not reproduce through
`rknnlite.inference()`; a real 1.5× likely requires the zero-copy
pass-through C-API path.

## Postscript: the large-v3 attempt (2026-08-15)

With the shim proven at medium, the same pipeline was run for large-v3
(32 layers / 20 heads / 1280 d_model / 128 mels): export and conversion
succeeded on-cluster (1.77 GB `.rknn`, simulator pipeline OK — note the
driver needs `num_languages=100` plumbed to the tokenizer or the task
token shifts by one). On real hardware it never got as far as this
document's bug: **`rknn_init` itself is pathological at this model size.**

- Uncapped, initialization consumed effectively all of the RK1's 32 GB and
  hard-wedged the node at kernel level: ping answered, but sshd and the
  k8s API were dead for 35+ minutes, the system OOM killer never
  completed (the Mali driver's OOM notifier logged `0 kB` reclaimable),
  and recovery required a BMC power-cycle.
- Re-run under a 20 GB cgroup cap, the init was OOM-killed ~30 s in at
  **20.9 GB anon-RSS — a >12× blowup over the 1.77 GB model file**
  (kernel evidence: `Memory cgroup out of memory: Killed process …
  total-vm:21509288kB, anon-rss:20928968kB`).
- As with the input-loss bug: zero RKNPU or runtime log lines, and the
  x86 simulator is immune (the same artifact passes the simulator
  pipeline).

Verdict: **medium is the practical SA-KV model-size ceiling on
librknnrt 2.3.2 / 32 GB RK1s.** The medium decoder initializes and runs
in production; the 1.77 GB large-v3 decoder cannot be initialized at
all. Operational lesson folded into `HARDWARE-FIRMWARE-ISSUES.md`: never
run RKNN workloads without a memory cap — a runaway init inside a capped
container costs you the container; uncapped, it costs you the node.

**Refinement (same day): it is not model size.** Two capped init-only
probes (peak RSS via `ru_maxrss`, same runtime/driver, same node):

| Model | Size | Init result | Peak RSS | Overhead |
|---|---|---|---|---|
| medium SA-KV step | 0.94 GB | OK, 1.2 s | 2.10 GB | ~2.2× |
| June large-v3 cached-xa decoder | **1.80 GB** | OK, 2.0 s | 3.83 GB | ~2.1× |
| large-v3 SA-KV step | 1.77 GB | killed at 20 GB cap, ~30 s, not done | >20.9 GB | **>11×, unbounded?** |

Normal `rknn_init` overhead is ~2× at every size tested, including a
model *larger* than the failing one. The runaway is specific to the
**SA-KV step graph at large-v3 dimensions** — candidate drivers: ~130
graph I/O tensors, 64 in-model `Unsqueeze` ops (the input shim), the
concat-at-449 static shapes, or an interaction between them and the
larger head count/width. This mirrors the main bug's lesson: it looked
like a scale wall and is actually a structure-sensitive defect — which is
good news, because structure-sensitive defects have workarounds. The
experiment ladder to localize it (layer-count sweep via
`minimal_repro_nlayer.py --export-rknn`, shim-on/off control, n_ctx
sweep, C-API memory instrumentation) is tracked as **W-05** in the
backlog.
