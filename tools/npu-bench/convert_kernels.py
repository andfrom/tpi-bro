#!/usr/bin/env python3
"""
npu-bench stage 2 — convert synthetic ONNX kernels to RKNN at a chosen precision.

Reads <in>/manifest.json + each <in>/<name>.onnx, builds an RKNN per kernel, and
writes <out>/<name>.<precision>.rknn. Records per-kernel build success/failure
and any operator-fallback warnings into <out>/convert_report.<precision>.json —
which feeds the Layer-4 operator-support map (a kernel that won't convert, or
emits "Unkown op target", is the feasibility answer).

Precision points the rknn-toolkit2 2.3.2 path actually exposes:
  fp16  — do_quantization=False (RK3588's native non-quantized compute is FP16)
  int8  — do_quantization=True with random calibration (NOTE: some graphs emit
          empty/broken output, airockchip/rknn_model_zoo#314 — verify with run_bench)

Needs rknn-toolkit2 (x86 laptop Poetry env, or the tagx whisper-rknn-convert
ARM64 image). Does NOT need an NPU.

Usage:
    poetry run python convert_kernels.py --in kernels --out rknn --precision fp16
    poetry run python convert_kernels.py --in kernels --out rknn --precision int8
"""
import argparse
import contextlib
import io
import json
import sys
import types
from pathlib import Path

import numpy as np
import onnx

# rknn-toolkit2 2.3.2 calls onnx.mapping.{TENSOR_TYPE_TO_NP_TYPE,NP_TYPE_TO_TENSOR_TYPE}
# both removed in onnx 1.14+. Shim both directions (matches tagx convert_rknn.py).
if not hasattr(onnx, "mapping"):
    _m = types.ModuleType("onnx.mapping")
    _m.TENSOR_TYPE_TO_NP_TYPE = {
        int(onnx.TensorProto.FLOAT): np.dtype("float32"),
        int(onnx.TensorProto.FLOAT16): np.dtype("float16"),
        int(onnx.TensorProto.DOUBLE): np.dtype("float64"),
        int(onnx.TensorProto.INT8): np.dtype("int8"),
        int(onnx.TensorProto.INT16): np.dtype("int16"),
        int(onnx.TensorProto.INT32): np.dtype("int32"),
        int(onnx.TensorProto.INT64): np.dtype("int64"),
        int(onnx.TensorProto.UINT8): np.dtype("uint8"),
        int(onnx.TensorProto.UINT16): np.dtype("uint16"),
        int(onnx.TensorProto.UINT32): np.dtype("uint32"),
        int(onnx.TensorProto.UINT64): np.dtype("uint64"),
        int(onnx.TensorProto.BOOL): np.dtype("bool"),
    }
    _m.NP_TYPE_TO_TENSOR_TYPE = {v: k for k, v in _m.TENSOR_TYPE_TO_NP_TYPE.items()}
    onnx.mapping = _m
    sys.modules["onnx.mapping"] = _m

from rknn.api import RKNN  # noqa: E402

TARGET = "rk3588"


def convert_one(entry, in_dir: Path, out_dir: Path, precision: str, skip_existing: bool):
    name = entry["name"]
    onnx_path = in_dir / f"{name}.onnx"
    rknn_path = out_dir / f"{name}.{precision}.rknn"

    if skip_existing and rknn_path.exists():
        print(f"  SKIP {name}.{precision} (exists)")
        return {"name": name, "op": entry["op"], "precision": precision,
                "ok": True, "skipped": True}

    log = io.StringIO()
    result = {"name": name, "op": entry["op"], "precision": precision, "ok": False}
    try:
        rknn = RKNN(verbose=False)
        rknn.config(target_platform=TARGET, optimization_level=3)
        with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
            if rknn.load_onnx(model=str(onnx_path)) != 0:
                raise RuntimeError("load_onnx failed")
            if precision == "int8":
                # random calibration — one .npy per input; dataset line lists all
                # inputs space-separated (rknn format). Synthetic kernels have no
                # real data, so this measures INT8 *speed* only — numerical
                # correctness (#314) must be checked on a real workload.
                paths = []
                for k, shape in entry["input_shapes"].items():
                    p = out_dir / f"{name}.calib.{k}.npy"
                    np.save(p, np.random.randn(*shape).astype(np.float32))
                    paths.append(str(p))
                ds = out_dir / f"{name}.dataset.txt"
                ds.write_text(" ".join(paths) + "\n")
                ret = rknn.build(do_quantization=True, dataset=str(ds))
            else:
                ret = rknn.build(do_quantization=False)
            if ret != 0:
                raise RuntimeError("build failed")
            if rknn.export_rknn(str(rknn_path)) != 0:
                raise RuntimeError("export_rknn failed")
        rknn.release()
        result["ok"] = True
    except Exception as e:  # noqa: BLE001
        result["error"] = str(e)

    text = log.getvalue()
    # surface the tell-tale operator-fallback / unsupported markers
    flags = [m for m in ("Unkown op target", "not support", "fallback", "CPU")
             if m.lower() in text.lower()]
    if flags:
        result["warnings"] = flags
    print(f"  {'OK ' if result['ok'] else 'FAIL'} {name}.{precision}"
          + (f"  [{', '.join(flags)}]" if flags else ""))
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_dir", default="kernels")
    ap.add_argument("--out", default="rknn")
    ap.add_argument("--precision", choices=["fp16", "int8"], default="fp16")
    ap.add_argument("--skip-existing", action="store_true",
                    help="skip kernels whose .rknn already exists (resume)")
    args = ap.parse_args()

    in_dir, out_dir = Path(args.in_dir), Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((in_dir / "manifest.json").read_text())

    report = [convert_one(e, in_dir, out_dir, args.precision, args.skip_existing)
              for e in manifest]
    rep_path = out_dir / f"convert_report.{args.precision}.json"
    rep_path.write_text(json.dumps(report, indent=2))
    ok = sum(r["ok"] for r in report)
    print(f"\n{ok}/{len(report)} converted ({args.precision}) -> {out_dir}/")
    print(f"report: {rep_path}")


if __name__ == "__main__":
    main()
