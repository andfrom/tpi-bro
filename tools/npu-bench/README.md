# npu-bench

Synthetic microbenchmark harness that fills the RK3588 NPU datasheet — the
measured constants behind `docs/NPU-CHARACTERIZATION.md`. Each run yields rows
you can use to predict feasibility + speed-at-precision for any future workload,
without building it.

## Three stages (each on its natural host)

```
gen_kernels.py   ──▶  convert_kernels.py  ──▶  run_bench.py
(anywhere:            (x86 / convert image:     (a node, via
 onnx+numpy)           rknn-toolkit2)            tagx/whisper-stt:rknn)
   ONNX                  .rknn @ precision         results.json
```

1. **gen** — pure single-op ONNX kernels with known FLOP/byte cost + `manifest.json`.
2. **convert** — ONNX → RKNN per precision (`fp16` / `int8`); records build
   success + op-fallback warnings (`convert_report.<prec>.json` → Layer-4 map).
3. **run** — on the NPU: native-dtype inputs, phase-split timing, derives
   GFLOP/s (Layer 1) and GB/s (Layer 2).

## What each suite measures

| Suite | Kernels | Yields |
|---|---|---|
| `l1` | matmul + conv sweep | compute ceiling per precision (GFLOP/s) → the speed-at-precision roofline |
| `l2` | elementwise add sweep | DRAM bandwidth (GB/s) → roofline slope; ridge point = L1peak/L2bw |
| `ops` | single-op probes | operator-support / fallback map (can/cannot) |

## Run it

```bash
# stage 1 — laptop / tagx poetry env
python gen_kernels.py --out kernels --suite all

# stage 2 — x86 with rknn-toolkit2 (tagx poetry env), per precision
poetry run python convert_kernels.py --in kernels --out rknn --precision fp16
poetry run python convert_kernels.py --in kernels --out rknn --precision int8

# deploy to a node and run on the NPU (1-core auto + all-3-core)
scp -r kernels rknn run_bench.py ubuntu@rk1-node1:/tmp/npu-bench/
ssh ubuntu@rk1-node1 "docker run --rm --privileged \
  -v /tmp/npu-bench/rknn:/rknn:ro \
  -v /tmp/npu-bench/kernels/manifest.json:/rknn/manifest.json:ro \
  -v /tmp/librknnrt_2.3.2.so:/usr/lib/librknnrt.so:ro \
  -v /tmp/npu-bench/run_bench.py:/app/run_bench.py:ro \
  --entrypoint python tagx/whisper-stt:rknn /app/run_bench.py \
    --rknn /rknn --manifest /rknn/manifest.json --precision fp16 --cores 0,7"
```

Collect `results.fp16.json` / `results.int8.json` and fold the headline numbers
into `NPU-DATASHEET.md`.

## Notes

- **Match input dtype.** `run_bench` queries each input's native dtype/layout and
  feeds matching arrays, so marshalling cost isn't conflated with compute. (The
  Whisper work showed feeding FP32 into an FP16 model adds a host-side conversion
  that doubled per-step latency.)
- **INT8 may be broken** for some graphs (airockchip/rknn_model_zoo#314). The
  convert report flags it; `run_bench` confirms whether output is sane.
- **`run` is the device floor.** `set_inputs`/`get_outputs` are stack overhead;
  `run` (best-of-N) is what scales with model architecture + precision.
- Tag every datasheet row's stability layer (silicon/driver/runtime/toolchain)
  so a version bump only invalidates affected rows.
