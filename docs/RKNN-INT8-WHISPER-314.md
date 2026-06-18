# INT8 Whisper on RK3588 — root cause of the empty/garbage output (#314)

Root-cause analysis for [airockchip/rknn_model_zoo#314](https://github.com/airockchip/rknn_model_zoo/issues/314):
Whisper converts and runs correctly in FP16 on the RK3588 NPU, but **INT8
quantization produces empty or garbage transcriptions**. This documents where
and why it breaks, with per-layer evidence, and a working hybrid-precision
workaround. Kept open here until fixed upstream.

## Environment
- rknn-toolkit2 2.3.2, librknnrt 2.3.2, RKNPU driver 0.9.7, RK3588 (TuringPi RK1)
- Whisper **medium** encoder, FP16 baseline vs INT8 (`do_quantization=True`)
- Calibration: **10 real 30 s mel windows** from actual speech (not random)

## Symptom (measured)
FP16 transcribes correctly. INT8 encoder output collapses:

| | norm | std | near-zero fraction | cosine vs FP16 |
|---|---|---|---|---|
| FP16 features | 1972 | 1.59 | — | (baseline) |
| INT8 features | 236 | 0.19 | **93.7 %** | **0.25** |

The model runs without a runtime error — the output is just numerically dead.
This rules out the reporter's calibration-data hypothesis (real, representative
calibration produces the same collapse).

## Where it breaks (per-layer `accuracy_analysis`)
Per-layer cosine (float "golden" vs INT8 "simulator"), encoder blocks 0→4:

| layer (per block) | blk0 | blk1 | blk2 | blk3 | blk4 |
|---|---|---|---|---|---|
| `mlp_0_MatMul` (FFN) | 0.999 | 0.999 | 0.999 | 0.999 | 0.999 |
| `attn_MatMul_1` (softmax·V) | 0.983 | 0.909 | 0.893 | 0.884 | **0.788** |
| `attn_out_Add` (attn output) | 0.994 | 0.934 | 0.934 | 0.908 | 0.895 |

Two facts stand out:
1. **The FFN matmuls quantize perfectly (0.999)** — the linear, high-FLOP part of
   the model is fine under INT8.
2. **The attention scaled-dot-product path is the failure point**, and the error
   **compounds with depth** (0.98 → 0.79 across five blocks). Over 24 blocks this
   accumulates into the end-to-end collapse above.

## Root cause
It is **not** the calibration data and **not** the INT8 datapath — it is INT8 of
the **attention softmax path**:
- Softmax output ∈ [0, 1]. Under symmetric INT8 the entire −128…0 half of the
  range is unused; values are squeezed into ~0–64, so attention weights lose most
  of their resolution.
- Non-linear ops (Softmax, LayerNorm, GeLU) are well known to be far less
  quantization-resilient than linear matmuls.
- The per-block attention error compounds across the 24-layer stack → dead output.

This matches the transformer-quantization literature (e.g. softmax being the INT8
attention bottleneck; non-linearities needing higher precision).

## Workaround — hybrid precision (attention FP16, FFN INT8)
Keep the attention path (SDPA / softmax / attention-output, and LayerNorms) in
**FP16** and quantize the **FFN matmuls** (the FLOP bulk) to **INT8**, via
`rknn.hybrid_quantization_step1` / `step2`. Because the FFN is where most of the
compute is and it quantizes cleanly, this recovers usable output while keeping
most of the INT8 speedup.

> Status: hybrid build + empirical validation in progress; results will be
> appended here. The diagnosis above is complete and reproducible regardless.

## Reproduce
Scripts in [`tools/npu-bench/`](../tools/npu-bench/):
- `whisper_int8_convert_encoder.py` — convert the encoder ONNX to INT8 with real
  mel calibration
- `whisper_int8_accuracy_analysis.py` — run `accuracy_analysis` (per-layer
  float-vs-quantized snapshots)
- `whisper_int8_layer_cosine.py` — compute per-layer cosine to localize the collapse
- `compare_encoder_int8.py` / `gen_calib_mels.py` — FP16-vs-INT8 feature comparison
  and real-mel calibration generation

Broader RK3588 NPU characterization (where this finding originated):
[`docs/NPU-CHARACTERIZATION.md`](NPU-CHARACTERIZATION.md),
[`docs/NPU-DATASHEET.md`](NPU-DATASHEET.md).

---

## Draft upstream comments (post when this repo is public)

**Comment 1 — root cause:**

> Reproduced on rknn-toolkit2 2.3.2 / RK3588 with Whisper **medium** and **real**
> calibration (10 mel windows). FP16 transcribes correctly; the INT8 encoder
> output collapses (93.7 % near-zero, cosine 0.25 vs FP16).
>
> Localized it with `accuracy_analysis`: the **attention scaled-dot-product path**
> (softmax·V) is the failure point and **degrades with depth** — per-layer cosine
> 0.98 → 0.79 over blocks 0→4 — while the **FFN matmuls quantize perfectly
> (0.999)**. Root cause is INT8 of the softmax path: softmax output ∈ [0,1] uses
> only ~half the symmetric-INT8 range (squeezed into 0–64), and non-linear ops
> (softmax/LayerNorm/GeLU) are quantization-fragile; the per-block error compounds
> across the 24-layer stack into the end-to-end collapse. **So it's not the
> calibration data — it's INT8 of the attention softmax.**
>
> Full per-layer data + reproduction scripts:
> https://github.com/andfrom/tpi-bro/blob/main/docs/RKNN-INT8-WHISPER-314.md

**Comment 2 — workaround (followup):**

> Workaround that recovers usable output: **hybrid quantization** — keep the
> attention path (SDPA/softmax + attention output + LayerNorms) in **FP16**, and
> quantize the **FFN matmuls** (the FLOP bulk, which quantize cleanly at cos 0.999)
> to **INT8**, via `hybrid_quantization_step1/step2`. Retains most of the INT8
> speedup since the FFN is where the compute is. Config + measured results:
> https://github.com/andfrom/tpi-bro/blob/main/docs/RKNN-INT8-WHISPER-314.md
