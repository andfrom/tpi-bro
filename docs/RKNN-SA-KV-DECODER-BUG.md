# Self-attention KV-cache RKNN decoder produces wrong output on real hardware

Root-cause investigation for a bug found while implementing W-03 (self-attention
KV cache for the RKNN Whisper decoder, `docs/backlog/BACKLOG.md`). The exported
model (`export_onnx.py --mode sa-kv`, tagx) and its PyTorch source module are
verified mathematically correct. The **compiled `.rknn` model produces wrong
output once real (non-degenerate) masked self-attention is exercised** — i.e.
from the second decode step onward. Not yet filed upstream (no known matching
issue found; closest is airockchip/rknn-toolkit2#460, see below). Kept open
here until root-caused further or fixed upstream.

## Environment

- rknn-toolkit2 2.3.2, rknn-toolkit-lite2 2.3.2, librknnrt 2.3.2, RKNPU driver 0.9.7, RK3588 (TuringPi RK1)
- Whisper **medium**, self-attention KV-cache decoder (`_DecoderSAKVStep` in tagx's `export_onnx.py`), FP32 ONNX / FP16 RKNN build (`do_quantization=False`)
- Model architecture: 24 transformer blocks, 16 heads, head_dim 64, n_ctx 448

## Symptom (measured, real hardware)

Real-audio transcription (a synthesized "The quick brown fox jumps over the
lazy dog" clip) produces a degenerate, repeating transcript: `"The The The
The"` — decoder confidence (top-token logit) *decreases* each step while the
predicted token stays constant, then flips to EOT. Classic signature of the
model not incorporating new cache content.

## Root cause isolation

### Step 0 is not a valid correctness test

At decode step 0, the self-attention mask has exactly **one** valid position
(nothing in the cache yet, only the token's own new K/V slot). `softmax` over
one valid element always outputs weight `1.0` regardless of whether the
underlying score computation is correct — so step 0 matching a reference
proves nothing about masking/softmax correctness. It only validates the token
embedding, K/V projections, cross-attention, and MLP paths (all confirmed
correct — see below).

### Step 1 is the first real test, and it fails

Step 1 introduces the first non-trivial mask (2 valid positions: cache slot 0
+ the new-K slot) — the first real softmax normalization. Comparing real
hardware's step-1 output against a proven-correct PyTorch reference (fed the
*exact* real hardware cache state from step 0, not an idealized one):

```
logits cosine(reference, hardware) = -0.170464   (top5 tokens don't even match)
```

Per-layer divergence (K/V cache slice cosine similarity, step 1):

| layer | k cos | v cos |
|---|---|---|
| 0 | 1.00000 | 1.00000 |
| 1 | 0.97101 | 0.92599 |
| 2 | 0.74589 | 0.88474 |
| 3 | **-0.04056** | 0.83212 |
| 4–23 | oscillates 0.87–0.98 | oscillates 0.87–0.97 |

Layer 0 is exact — its K/V outputs are pure projections of the token
embedding, independent of any attention weighting, so this doesn't exercise
masking either. Layer 1 is the first layer whose *input* (`x`, coming from
layer 0's self-attention-weighted output) already reflects a real
softmax-over-2-positions computation, and it's already measurably wrong.

## Ruled out

- **Dtype** (feeding the cache/mask as float16 vs. float32): byte-identical
  output either way — `rknnlite` coerces internally regardless of what's
  passed in.
- **Mask literal magnitude** (`-1e9` vs. `-30000`, to dodge FP16 overflow to
  `-inf`): byte-identical output either way.
- **Output tensor ordering**: cross-correlated all 49 real-hardware step-0
  outputs against the reference's per-layer values — the declared ONNX
  `output_names` order (`logits`, then `sa_k_new_0..23`, then
  `sa_v_new_0..23`) is exactly what `rknn.inference()` returns. (A raw
  `verbose=True` build log shows internal graph-scheduling operator order is
  scrambled — e.g. `sa_k_new_0` and `sa_k_new_12` scheduled adjacently — but
  that's an internal compiler artifact, not the API's actual return order.)
- **ONNX graph wiring**: confirmed by direct graph inspection that `sa_mask`
  is a real input to all 24 layers' score-`Add` nodes, not folded away.
- **The core masked-attention operation, in isolation**: a minimal
  standalone model (same shapes — 16 heads, head_dim 64, 449-length masked
  axis, same 2-valid-position mask as step 1) built and run through
  rknn-toolkit2's x86 simulator produces output matching the PyTorch
  reference to cosine 1.000000, including when the `Concat(cache, new-slice)`
  operation is part of the traced graph (not pre-computed).
- **Encoder, XA-KV encoder, cross-attention, MLP**: all confirmed correct —
  step 0 (despite not testing self-attention masking) *does* exercise these
  paths for all 24 layers, and matches the reference exactly there.

## Scale-dependent: the bug needs enough layers to appear

Re-running the same isolated-op test as a **stacked, real-weights slice of
the real model** (first N of medium's 24 blocks, via
`decoder.blocks = decoder.blocks[:N]`, then the same export→convert→simulate
pipeline used for the real model) at increasing depth:

| N layers | cosine(ref, rknn-simulator) | Result |
|---|---|---|
| 2 | 0.999999 | MATCH |
| 12 | 0.999999 | MATCH |
| 18 | 0.999999 | MATCH |
| 24 (full model, simulator) | 0.999993 | MATCH (see next section — needed more RAM headroom to build) |
| 24 (full model, real hardware) | **-0.17** | **MISMATCH** (confirmed above) |

So at every layer count, including the full 24, **the x86 simulator agrees
with the PyTorch reference.** Only real hardware diverges, and only at full
depth (real hardware also confirmed correct at 12 and 18 layers — see next
section). This isn't a scale-dependent compiler bug — it's a real-hardware
execution issue that needs enough concurrent attention blocks to trigger.

## The simulator does NOT reproduce this — it's real-hardware-specific

Building the **full 24-layer** model (real weights, real audio, exact
production shapes) and running it through rknn-toolkit2's x86 CPU simulator
— the same simulator that's been used for every bisection point above —
produces **correct** output: `cosine(reference, simulator) = 0.999993`, top5
tokens identical. Two independent attempts to route around this via
configuration (disabling the aggressive fusion pass with
`optimization_level=0`; shrinking the KV-cache size 14× to rule out a
tensor-size-driven OOM/precision issue) both hit the same simulator-build
memory ceiling on a 15 GB laptop before reaching 24 layers, and neither
changed the outcome at layer counts where they *could* run — so this isn't a
config knob. But the plain, unmodified full-depth build works fine **in the
simulator**.

This means the divergence isn't a graph-compilation bug at all — the same
compiled model, on the same day, is correct in the simulator and wrong on
real RK3588 silicon. That reframes the leading hypothesis entirely: this is
about real NPU execution (actual FP16 hardware arithmetic, on-chip
scratch/buffer allocation for many concurrent attention blocks, or similar),
not the compiler's graph transformations.

**Validated on real hardware, not just the simulator:** built and ran
actual `.rknn` files (not simulated) for 12-layer and 18-layer slices,
via `rknnlite` on rk1-node1:

| N layers | cosine(reference, **real hardware**) | Result |
|---|---|---|
| 12 | 0.999468 | MATCH |
| 18 | 0.999224 | MATCH |
| 24 (full model) | -0.170464 (step 1, see above) | **MISMATCH** |

**This gives a working workaround, not just a diagnosis:** splitting the
24-layer decoder into two sequential 12-layer `.rknn` models (passing the
intermediate residual stream `x` between them as two separate
`rknnlite.inference()` calls per decode step) should sidestep the bug
entirely — both 12-layer halves are independently confirmed correct on real
silicon. Not yet implemented (`export_onnx.py`/`convert_rknn.py` only
support single monolithic decoders today); this is the natural next step if
picking this back up. Reproduction: `debug/minimal_repro_nlayer.py --layers N
--export-rknn out.rknn` builds a real, hardware-loadable N-layer slice of the
actual model; `debug/real_hw_check.py` runs it on real hardware and compares
against the saved reference.

## Leading hypothesis: real-silicon execution of the fused SDPA op, at scale

`rknn-toolkit2` recognizes the `MatMul → Add(mask) → Softmax → MatMul`
pattern and fuses it into an internal SDPA-family operator
(`fuse_matmul_softmax_matmul_to_sdpa`, confirmed present in the build log —
this fusion happens identically at every layer count tested, including the
2-layer case that's correct everywhere and the 24-layer case that's correct
in the simulator but wrong on real hardware). So the fusion *decision* isn't
the bug — the compiled graph is the same either way. What differs is only
*where* it runs: the x86 simulator's software emulation of the fused op vs.
the RK3588's actual NPU silicon executing it. Combined with the real-hardware
12/18-layer results above, the most consistent explanation is that real NPU
execution of many concurrent/pipelined fused-SDPA blocks hits a hardware or
driver-level resource limit (on-chip scratch buffer capacity, scheduling,
FP16 arithmetic edge case under load) that the simulator — running on a CPU
with no such constraint — cannot reproduce.

**Closely related, independently-filed, still-open upstream issue:**
[airockchip/rknn-toolkit2#460](https://github.com/airockchip/rknn-toolkit2/issues/460)
— same toolkit version (2.3.2), same target (RK3588), same fusion family
(`exSDPAttention`/`exNorm`), reporter also suspects FP16 Softmax precision,
no maintainer response. Not confirmed to be the same root cause, but the
closest match found after a dedicated search — see also
[#415](https://github.com/airockchip/rknn-toolkit2/issues/415) (FP16-range
overflow silently cascading through downstream layers, structurally the same
failure shape: fine early, degrades with depth) and
[#463](https://github.com/airockchip/rknn-toolkit2/issues/463) (unanswered
question about whether RKNN ops protect intermediate values from FP16 range
at all).

## Reproduction

All scripts below are self-contained (real pretrained weights, no dataset
needed beyond `openai-whisper`'s own model download) and run via
`poetry run python3 <script>` from the `tagx` repo root:

- `images/whisper-stt/rknn/debug/test_sa_kv_reference.py` — PyTorch-only
  correctness check of `_DecoderSAKVStep` against Whisper's own full-context
  decode. Confirms the exported module's math is correct in isolation.
- `images/whisper-stt/rknn/debug/minimal_repro_attn.py` — isolated masked
  self-attention op (no Concat), simulator-only. Confirms the base op is
  correct.
- `images/whisper-stt/rknn/debug/minimal_repro_attn_concat.py` — same, with
  the `Concat(cache, new-slice)` op included in the traced graph. Confirms
  Concat isn't the issue either.
- `images/whisper-stt/rknn/debug/minimal_repro_nlayer.py --layers N
  [--export-rknn out.rknn]` — real model, real weights, truncated to the
  first N transformer blocks; exports and converts, then either runs both
  decode steps through the RKNN simulator, or (with `--export-rknn`) writes
  a real hardware-loadable `.rknn` plus a `.testdata.npz` of the exact
  inputs and reference logits, for testing on the actual device. Used to
  bisect the layer-count threshold above, on both the simulator and real
  hardware.
- `images/whisper-stt/rknn/debug/real_hw_check.py --rknn out.rknn --testdata
  out.testdata.npz` — the real-hardware counterpart: loads an
  `--export-rknn`'d model via `rknnlite`, runs it, and compares against the
  saved reference. Run this on the RK3588 node (inside the
  `tagx/whisper-stt:rknn` image or anywhere `rknnlite` is installed), not on
  the conversion laptop.

`infer_rknn_sa_kv.py` (the full driver, wired for `charts/whisper/` the same
way `infer_rknn_kv.py` is) exists and runs end-to-end, but **do not treat its
output as correct** — it faithfully reproduces this bug. It's kept committed
(rather than left as gitignored scratch work, which is what happened to the
*previous* SA-KV investigation and is why this bug went unnoticed until now)
specifically so the next person picking this up has working scaffolding
instead of starting over.

## Status

**W-03 is blocked, not just unimplemented — but a workaround path exists.**
The chart-side infrastructure and the driver exist; the compiled 24-layer
model produces incorrect output for any decode beyond the first token, on
real hardware specifically (the x86 simulator is correct at every layer
count tested, including the full 24). Real hardware is independently
confirmed correct at 12 and 18 layers. Do not wire `infer_rknn_sa_kv.py`
into `charts/whisper/` as-is — it would ship a decoder that silently
produces wrong transcripts, worse than the current (slower, but correct)
full-recompute decoder already in the chart.

**Next step if picked back up:** implement a split decoder — two sequential
12-layer `.rknn` models (extending `export_onnx.py`'s `_DecoderSAKVStep` to
optionally take/return an intermediate residual `x` at a layer boundary,
and `convert_rknn.py` to build both halves) instead of one monolithic
24-layer graph, chained via two `rknnlite.inference()` calls per decode
step. Both halves are independently validated correct on real silicon
above; this hasn't been built yet, only validated as a viable approach.
