#!/usr/bin/env python3
"""
npu-bench stage 3 — run RKNN kernels on the RK3588 NPU and emit datasheet rows.

For each converted kernel it queries the model's native input attrs (dtype +
layout), feeds matching random inputs (so no host-side conversion pollutes the
measurement — the FP16-vs-FP32 lesson from the Whisper work), runs warmup + N
timed iterations, and records the phase split:

    set_inputs  — host -> NPU marshalling (Layer 2/3)
    run         — NPU compute            (Layer 1)
    get_outputs — NPU -> host retrieval

From the manifest's flops/bytes it derives achieved GFLOP/s (L1 compute ceiling)
and GB/s (L2 bandwidth). Output: <results>.json, one row per kernel × core-mask.

Runs on a node via the tagx/whisper-stt:rknn image (rknnlite + librknnrt):

    docker run --rm --privileged \
      -v /path/to/rknn:/rknn:ro \
      -v /path/to/kernels/manifest.json:/rknn/manifest.json:ro \
      -v /tmp/librknnrt_2.3.2.so:/usr/lib/librknnrt.so:ro \
      -v $PWD/run_bench.py:/app/run_bench.py:ro \
      --entrypoint python tagx/whisper-stt:rknn /app/run_bench.py \
        --rknn /rknn --manifest /rknn/manifest.json --precision fp16 --cores 0,7
"""
import argparse
import json
import os
import time
from pathlib import Path

import numpy as np
from rknnlite.api import RKNNLite

_TYPES = {0: "fp32", 1: "fp16", 2: "int8", 3: "uint8", 4: "int16",
          5: "uint16", 6: "int32", 7: "uint32", 8: "int64", 9: "bool"}
_NP = {"fp32": np.float32, "fp16": np.float16, "int8": np.int8, "uint8": np.uint8,
       "int16": np.int16, "int32": np.int32, "int64": np.int64}
_CORE = {0: "auto", 1: "core0", 2: "core1", 4: "core2", 3: "core0_1", 7: "core0_1_2"}

WARMUP, MEAS = 3, 10


def bench_one(rknn_path: Path, entry: dict, core_mask: int):
    m = RKNNLite()
    row = {"name": entry["name"], "op": entry["op"], "suite": entry.get("suite"),
           "precision": entry["precision"], "cores": _CORE.get(core_mask, core_mask)}
    if m.load_rknn(str(rknn_path)) != 0:
        row["error"] = "load_rknn failed"
        return row
    if m.init_runtime(core_mask=core_mask) != 0:
        row["error"] = "init_runtime failed"
        return row
    r = m.rknn_runtime

    # build native-dtype random inputs from queried attrs (index order = input order)
    n_in, n_out = r.get_in_out_num()
    inputs, in_types, moved_bytes = [], [], 0
    for i in range(n_in):
        a = r.get_tensor_attr(i, is_output=False)
        dt = _TYPES.get(a.type, "fp32")
        in_types.append(dt)
        moved_bytes += int(a.size)  # actual on-device bytes (dtype-correct)
        shape = list(a.dims[:a.n_dims])
        np_dt = _NP.get(dt, np.float32)
        if np.issubdtype(np_dt, np.integer):
            arr = np.zeros(shape, dtype=np_dt)
        else:
            arr = np.random.randn(*shape).astype(np_dt)
        inputs.append(arr)
    for j in range(n_out):
        moved_bytes += int(r.get_tensor_attr(j, is_output=True).size)
    row["input_dtypes"] = in_types
    row["moved_bytes"] = moved_bytes

    def phases():
        t0 = time.perf_counter(); r.set_inputs(inputs, None, None)
        t1 = time.perf_counter(); r.run(False)
        t2 = time.perf_counter(); out = r.get_outputs(False)
        t3 = time.perf_counter()
        return (t1 - t0) * 1e3, (t2 - t1) * 1e3, (t3 - t2) * 1e3, out

    try:
        for _ in range(WARMUP):
            phases()
        s, rn, g = [], [], []
        for _ in range(MEAS):
            a, b, c, _ = phases()
            s.append(a); rn.append(b); g.append(c)
    except Exception as e:  # noqa: BLE001
        row["error"] = f"inference: {e}"
        m.release()
        return row

    row["set_inputs_ms"] = round(float(np.mean(s)), 2)
    row["run_ms"] = round(float(np.mean(rn)), 2)
    row["run_ms_min"] = round(float(np.min(rn)), 2)
    row["get_outputs_ms"] = round(float(np.mean(g)), 2)

    run_s = float(np.min(rn)) / 1e3  # best-case compute time
    if entry.get("flops", 0) > 0 and run_s > 0:
        row["gflops"] = round(entry["flops"] / run_s / 1e9, 1)
    if entry.get("suite") == "l2" and run_s > 0:
        row["gbps"] = round(moved_bytes / run_s / 1e9, 1)  # actual dtype bytes
    m.release()
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rknn", default="rknn")
    ap.add_argument("--manifest", default="kernels/manifest.json")
    ap.add_argument("--precision", choices=["fp16", "int8"], default="fp16")
    ap.add_argument("--cores", default="0", help="comma list of core masks: 0=auto 7=all3")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    rknn_dir = Path(args.rknn)
    manifest = json.loads(Path(args.manifest).read_text())
    core_masks = [int(c) for c in args.cores.split(",")]

    rows = []
    for entry in manifest:
        entry = {**entry, "precision": args.precision}
        rknn_path = rknn_dir / f"{entry['name']}.{args.precision}.rknn"
        if not rknn_path.exists():
            print(f"  skip {entry['name']} (no {rknn_path.name})")
            continue
        for cm in core_masks:
            row = bench_one(rknn_path, entry, cm)
            rows.append(row)
            extra = ""
            if "gbps" in row:
                extra = f"  {row['gbps']} GB/s"
            elif "gflops" in row:
                extra = f"  {row['gflops']} GFLOP/s"
            elif "error" in row:
                extra = f"  ERROR: {row['error']}"
            print(f"  {row['name']:24s} {row['cores']:9s} "
                  f"run={row.get('run_ms','-')}ms{extra}")

    out = args.out or f"results.{args.precision}.json"
    Path(out).write_text(json.dumps(rows, indent=2))
    print(f"\n{len(rows)} rows -> {out}")


if __name__ == "__main__":
    main()
