#!/usr/bin/env python3
"""
npu-bench — wall-clock calculator + Whisper validation.

Composes the measured RK3588 device constants (NPU-DATASHEET.md) into a serial
wall-clock prediction for an arbitrary kernel DAG, then validates against the
Whisper medium numbers we measured directly.

Per-kernel model (roofline + overhead):
    run   = max( flops / peak_compute[op,precision,cores],     # compute-bound
                 bytes / bandwidth[precision,cores] )           # memory-bound
            + dispatch_floor
    host  = in_bytes / marshall_set + out_bytes / marshall_get  (skip if resident)
    serial wall-clock = Σ (host + run + dispatch) over the critical path

`efficiency` (<=1) derates the compute/memory ceilings for a workload class that
the clean synthetic kernels don't capture (e.g. M=1 GEMV on a conv-optimised NPU).
Measured: encoder ≈ 0.82 (compute-bound, large matmuls); single-token decode ≈ 0.18
(GEMV + hundreds of tiny ops). The calculator without a derate is a *lower bound*.

No thermal derate is applied: sustained 100%-duty NPU load does not throttle on
this hardware (L7), so steady-state = burst.

INT8 speed ceilings are real (~2.5–3× matmul) but INT8 is numerically BROKEN for
transformer models on rknn 2.3.2 (#314 — Whisper encoder collapses to 94% zeros).
Do not use the INT8 profile to budget Whisper-class workloads; use fp16.

Runs anywhere (pure Python). No NPU, no rknn.
"""
from dataclasses import dataclass, field

# ── Measured device constants (RK3588, librknnrt 2.3.2) — see NPU-DATASHEET.md ─
# peak sustained GFLOP/s by (op_class, precision, cores)
PEAK_GFLOPS = {
    ("matmul", "fp16", 1): 133, ("matmul", "fp16", 3): 228,
    ("matmul", "int8", 1): 454, ("matmul", "int8", 3): 564,
    ("conv",   "fp16", 1): 665, ("conv",   "fp16", 3): 1474,
    ("conv",   "int8", 1): 1237, ("conv",  "int8", 3): 2287,
}
BANDWIDTH_GBPS = {("fp16", 1): 6.5, ("fp16", 3): 13.2,
                  ("int8", 1): 6.2, ("int8", 3): 12.6}

# CPU compute ceiling — RK3588 8 cores, numpy/BLAS fp32 (measured 2026-06-18):
# ~57 GFLOP/s matmul (generic ONNX-on-CPU path). Note: optimised INT8 runtimes
# (CTranslate2/faster-whisper) achieve higher *effective* throughput — the
# RK3588-CPU faster-whisper baseline is medium 58 s / large-v3 93 s for a 2-min
# clip (tpi-bro NPU-MODELS.md). LPDDR5 is shared with the NPU (~same bandwidth).
CPU_PEAK_GFLOPS = 57.0
CPU_BANDWIDTH_GBPS = 13.0
DISPATCH_FLOOR_MS = 0.06      # per-kernel NPU run launch (L3)
# Host marshalling is fixed-overhead + per-byte: tiny L3 transfers see ~190 MB/s
# effective, but bulk transfers amortize to ~560 MB/s (calibrated to Whisper's
# 191 MB fp16 set_inputs = 344 ms). Use the bulk rate for sizeable workloads.
MARSHALL_SET_MBPS = 557       # host set_inputs, native dtype, bulk
MARSHALL_GET_MBPS = 300       # host get_outputs (note: dominated by per-output
                              # fixed cost when there are many output tensors)
DTYPE_CONV_PENALTY = 1.45     # per-byte slowdown feeding fp32 into an fp16 model
BYTES = {"fp16": 2, "int8": 1, "fp32": 4}


@dataclass
class Kernel:
    name: str
    flops: float = 0.0
    weight_bytes: float = 0.0   # weights streamed from DRAM (GEMV/low-reuse)
    act_bytes: float = 0.0      # activation bytes touched on-device
    op_class: str = "matmul"    # matmul | conv
    count: int = 1              # how many such ops (for dispatch floors)


@dataclass
class Workload:
    name: str
    precision: str = "fp16"
    cores: int = 1
    efficiency: float = 1.0     # empirical derate for this workload class
    resident_io: bool = True    # weights/KV already on NPU (no host marshalling)
    host_in_bytes: float = 0.0  # per-call host->NPU transfer (if not resident)
    host_out_bytes: float = 0.0
    native_dtype: bool = True
    kernels: list = field(default_factory=list)

    device: str = "npu"             # npu | cpu

    def predict(self):
        if self.device == "cpu":
            peak = peak_conv = CPU_PEAK_GFLOPS
            bw = CPU_BANDWIDTH_GBPS * 1e9
        else:
            peak = PEAK_GFLOPS[("matmul", self.precision, self.cores)]
            peak_conv = PEAK_GFLOPS[("conv", self.precision, self.cores)]
            bw = BANDWIDTH_GBPS[(self.precision, self.cores)] * 1e9
        eff = self.efficiency

        compute_ms = mem_ms = dispatch_ms = 0.0
        for k in self.kernels:
            pk = (peak_conv if k.op_class == "conv" else peak) * 1e9 * eff
            compute_ms += k.flops / pk * 1e3
            mem_ms += (k.weight_bytes + k.act_bytes) / (bw * eff) * 1e3
            dispatch_ms += k.count * DISPATCH_FLOOR_MS
        # roofline: a kernel is bounded by the larger of compute/memory; we sum the
        # branch totals and take the max (whole-graph approximation), + dispatch.
        run_ms = max(compute_ms, mem_ms) + dispatch_ms

        host_ms = 0.0
        if not self.resident_io:
            sset = self.host_in_bytes / (MARSHALL_SET_MBPS * 1e6) * 1e3
            if not self.native_dtype:
                sset *= DTYPE_CONV_PENALTY
            host_ms = sset + self.host_out_bytes / (MARSHALL_GET_MBPS * 1e6) * 1e3
        return {"compute_ms": compute_ms, "mem_ms": mem_ms,
                "dispatch_ms": dispatch_ms, "run_ms": run_ms,
                "host_ms": host_ms, "total_ms": run_ms + host_ms}


# ── Whisper medium model (dims) ──────────────────────────────────────────────
L, D, H, HD, FFN, FRAMES, VOCAB, CTX = 24, 1024, 16, 64, 4096, 1500, 51865, 449
FP16 = 2


def whisper_encoder(cores=1, eff=1.0, precision="fp16"):
    # per layer: SA proj (4·2·F·D²) + attn (4·H·HD·F²) + FFN (4·F·D·FFN)
    f_sa = 4 * 2 * FRAMES * D * D
    f_attn = 4 * H * HD * FRAMES * FRAMES
    f_ffn = 4 * FRAMES * D * FFN
    per_layer = f_sa + f_attn + f_ffn
    return Workload(
        "encoder (medium)", precision, cores, eff, resident_io=True,
        kernels=[Kernel("layers", flops=per_layer * L, op_class="matmul",
                        count=L * 10)],
    )


def whisper_decoder_step(cores=1, eff=1.0, native_dtype=True, precision="fp16"):
    # M=1 (one token). FLOPs per layer:
    f_sa = 8 * D * D                       # q,k,v,out
    f_xa = 4 * D * D                       # q,out (k,v precomputed)
    f_ffn = 4 * D * FFN
    f_attn_sa = 4 * H * HD * CTX
    f_attn_xa = 4 * H * HD * FRAMES
    per_layer = f_sa + f_xa + f_ffn + f_attn_sa + f_attn_xa
    f_logits = 2 * D * VOCAB
    wb = BYTES[precision]   # decode is memory-bound on weights → precision halves bytes
    # weights streamed per step (GEMV reads the whole weight matrix for 1 token)
    w_per_layer = (6 * D * D + 2 * D * FFN) * wb     # SA(4)+XA(2) proj + FFN
    w_logits = D * VOCAB * wb
    # cross-attn K/V + SA cache stay FP16 (cache precision)
    xa_kv = 2 * L * FRAMES * D * FP16
    sa_cache = 2 * L * H * CTX * HD * FP16
    return Workload(
        "decoder step (medium)", precision, cores, eff, resident_io=True,
        native_dtype=native_dtype,
        kernels=[
            Kernel("layers", flops=per_layer * L, weight_bytes=w_per_layer * L,
                   act_bytes=xa_kv + sa_cache, op_class="matmul", count=L * 17),
            Kernel("logits", flops=f_logits, weight_bytes=w_logits,
                   op_class="matmul", count=1),
        ],
    )


def _row(label, pred, measured):
    t = pred["total_ms"]
    ratio = t / measured if measured else float("nan")
    bound = "compute" if pred["compute_ms"] >= pred["mem_ms"] else "memory"
    print(f"  {label:28s} pred={t:8.1f} ms  measured={measured:8.1f} ms  "
          f"ratio={ratio:.2f}  [{bound}-bound; "
          f"cmp={pred['compute_ms']:.0f} mem={pred['mem_ms']:.0f} "
          f"disp={pred['dispatch_ms']:.0f}]")


def main():
    print("=== Whisper medium validation (single core, FP16) ===\n")
    print("Roofline lower bound (efficiency = 1.0):")
    _row("encoder", whisper_encoder(1, 1.0).predict(), 10373)
    _row("decoder step", whisper_decoder_step(1, 1.0).predict(), 897)

    print("\nWith measured per-class efficiency derate:")
    _row("encoder (eff=0.82)", whisper_encoder(1, 0.82).predict(), 10373)
    _row("decoder step (eff=0.18)", whisper_decoder_step(1, 0.18).predict(), 897)

    print("\n=== INT8 projection — IF #314 were fixed (PROJECTED, not measured) ===")
    # compute/memory scaling from measured INT8 ceilings; decode efficiency derate
    # (0.18) assumed unchanged from FP16 — the one unverified assumption.
    enc_fp16 = whisper_encoder(1, 0.82).predict()["total_ms"]
    enc_int8 = whisper_encoder(1, 0.82, "int8").predict()["total_ms"]
    dec_fp16 = whisper_decoder_step(1, 0.18).predict()["total_ms"]
    dec_int8 = whisper_decoder_step(1, 0.18, precision="int8").predict()["total_ms"]
    print(f"  encoder/window:  FP16 {enc_fp16/1000:.1f} s  ->  full-INT8 {enc_int8/1000:.1f} s  ({enc_fp16/enc_int8:.1f}x)")
    print(f"  decoder/step:    FP16 {dec_fp16:.0f} ms  ->  full-INT8 {dec_int8:.0f} ms  ({dec_fp16/dec_int8:.1f}x)")
    # per minute of audio: 2 windows, ~200 decode tokens
    pm_fp16 = 2 * enc_fp16 + 200 * dec_fp16
    pm_int8 = 2 * enc_int8 + 200 * dec_int8
    print(f"  per min audio:   FP16 {pm_fp16/1000:.0f} s ({pm_fp16/60000:.1f}x realtime)"
          f"  ->  full-INT8 {pm_int8/1000:.0f} s ({pm_int8/60000:.1f}x realtime)")
    print("  caveats: full INT8 is numerically BROKEN for Whisper (#314) — speed")
    print("    upper-bound only. REALISTIC path is HYBRID (attn FP16 + FFN INT8):")
    print("    less encoder gain (attention stays FP16), most of the decode gain")
    print("    (FFN weights are the bulk). Decode 0.18 efficiency assumed unchanged.")

    print("\n=== NPU vs CPU (same workload) ===")
    # encoder is compute-bound and the calculator is validated there
    enc_npu1 = whisper_encoder(1, 0.82).predict()["total_ms"]
    enc_npu3 = whisper_encoder(3, 0.82); enc_npu3 = enc_npu3.predict()["total_ms"]
    enc_cpu = whisper_encoder(1, 1.0); enc_cpu.device = "cpu"
    enc_cpu = enc_cpu.predict()["total_ms"]
    print(f"  encoder (medium):")
    print(f"    NPU 1-core : {enc_npu1/1000:6.1f} s  (measured 10.4 s)")
    print(f"    NPU 3-core : {enc_npu3/1000:6.1f} s")
    print(f"    CPU 8-core : {enc_cpu/1000:6.1f} s  (fp32 BLAS, ~57 GFLOP/s)")
    print(f"    -> NPU 1-core is {enc_cpu/enc_npu1:.1f}x CPU; 3-core {enc_cpu/enc_npu3:.1f}x")
    print(f"  real-world anchor: faster-whisper INT8 CPU does the full 2-min clip in")
    print(f"    58 s (medium) — optimised INT8 runtime beats generic fp32 BLAS, so the")
    print(f"    NPU's edge over a *tuned* CPU stack is ~2x, not the raw-compute ratio.")

    print("\nMarshalling (decoder host set_inputs, not resident):")
    elems_in = 2 * L * FRAMES * D + 2 * L * H * CTX * HD  # XA K/V + SA cache
    for dt, lbl, measured in (("fp32", "fp32 inputs", 1001), ("fp16", "fp16 inputs", 344)):
        w = whisper_decoder_step(1, 1.0, native_dtype=(dt == "fp16"))
        w.resident_io = False
        w.host_in_bytes = elems_in * BYTES[dt]   # dtype-correct byte volume
        w.host_out_bytes = 0                      # get_outputs handled separately
        p = w.predict()
        print(f"  set_inputs {lbl:12s} pred={p['host_ms']:7.0f} ms  "
              f"measured={measured} ms  ratio={p['host_ms']/measured:.2f}")


if __name__ == "__main__":
    main()
