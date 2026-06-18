#!/usr/bin/env python3
"""
npu-bench Layer-6 probe — does async_mode overlap host marshalling with NPU compute?

Sync per-frame cost is set_inputs + run + get_outputs (serial sum). If rknnlite's
async_mode pipelines — submitting frame N+1's inputs while the NPU computes frame
N — steady-state per-frame cost should drop toward max(host, compute) instead of
the sum. That difference is what turns a serial cost model into a pipelined one.

Measures, per kernel:
  - phase split (set_inputs / run / get_outputs) for the serial reference
  - sync   steady-state: mean wall-time per inference() over a stream
  - async  steady-state: same, with init_runtime(async_mode=True)
  - overlap efficiency vs the theoretical pipelined floor max(host, run)

Run on a node via tagx/whisper-stt:rknn (see run_bench.py for the docker invocation).

    python async_test.py --rknn /bench/rknn --manifest /bench/manifest.json \
        --precision fp16 --kernels matmul_2048x2048x2048,add_256x256x256 --cores 7
"""
import argparse
import json
import time
from pathlib import Path

import numpy as np
from rknnlite.api import RKNNLite

_TYPES = {0: "fp32", 1: "fp16", 2: "int8", 3: "uint8", 4: "int16",
          5: "uint16", 6: "int32", 7: "uint32", 8: "int64", 9: "bool"}
_NP = {"fp32": np.float32, "fp16": np.float16, "int8": np.int8, "uint8": np.uint8,
       "int16": np.int16, "int32": np.int32, "int64": np.int64}

WARMUP, STREAM = 5, 40


def make_inputs(r):
    inputs = []
    for i in range(r.get_in_out_num()[0]):
        a = r.get_tensor_attr(i, is_output=False)
        dt = _NP.get(_TYPES.get(a.type, "fp32"), np.float32)
        shape = list(a.dims[:a.n_dims])
        inputs.append(np.zeros(shape, dt) if np.issubdtype(dt, np.integer)
                      else np.random.randn(*shape).astype(dt))
    return inputs


def phase_split(rknn_path, core_mask):
    m = RKNNLite()
    m.load_rknn(str(rknn_path)); m.init_runtime(core_mask=core_mask)
    r = m.rknn_runtime
    inp = make_inputs(r)
    for _ in range(WARMUP):
        r.set_inputs(inp, None, None); r.run(False); r.get_outputs(False)
    s = rn = g = 0.0
    for _ in range(STREAM):
        t0 = time.perf_counter(); r.set_inputs(inp, None, None)
        t1 = time.perf_counter(); r.run(False)
        t2 = time.perf_counter(); r.get_outputs(False)
        t3 = time.perf_counter()
        s += (t1 - t0); rn += (t2 - t1); g += (t3 - t2)
    m.release()
    return s / STREAM * 1e3, rn / STREAM * 1e3, g / STREAM * 1e3


def stream_time(rknn_path, core_mask, async_mode):
    m = RKNNLite()
    m.load_rknn(str(rknn_path))
    m.init_runtime(core_mask=core_mask, async_mode=async_mode)
    r = m.rknn_runtime
    inp = make_inputs(r)
    for _ in range(WARMUP):
        m.inference(inputs=inp)
    t0 = time.perf_counter()
    for _ in range(STREAM):
        m.inference(inputs=inp)
    dt = (time.perf_counter() - t0) / STREAM * 1e3
    m.release()
    return dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rknn", default="rknn")
    ap.add_argument("--manifest", default="kernels/manifest.json")
    ap.add_argument("--precision", default="fp16")
    ap.add_argument("--kernels", required=True, help="comma list of kernel names")
    ap.add_argument("--cores", type=int, default=7)
    args = ap.parse_args()

    rknn_dir = Path(args.rknn)
    for name in args.kernels.split(","):
        p = rknn_dir / f"{name}.{args.precision}.rknn"
        if not p.exists():
            print(f"  skip {name} (missing {p.name})"); continue

        s, rn, g = phase_split(p, args.cores)
        host = s + g
        serial = s + rn + g
        floor = max(host, rn)            # theoretical pipelined per-frame
        t_sync = stream_time(p, args.cores, False)
        t_async = stream_time(p, args.cores, True)

        print(f"\n{name}  ({args.precision}, cores={args.cores})")
        print(f"  phases:  set={s:.1f}  run={rn:.1f}  get={g:.1f} ms  "
              f"(host={host:.1f}, serial={serial:.1f})")
        print(f"  sync  per-frame:  {t_sync:.1f} ms")
        print(f"  async per-frame:  {t_async:.1f} ms   ({t_sync/t_async:.2f}x vs sync)")
        room = t_sync - floor  # overlap headroom (only meaningful if > a few ms)
        if room > 2.0:
            print(f"  pipelined floor max(host,run)={floor:.1f} ms  "
                  f"-> overlap efficiency {(t_sync - t_async)/room*100:.0f}%")
        else:
            print(f"  pipelined floor max(host,run)={floor:.1f} ms  "
                  f"(no overlap headroom: one phase dominates)")


if __name__ == "__main__":
    main()
