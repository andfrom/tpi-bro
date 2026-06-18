#!/usr/bin/env python3
"""
npu-bench stage 1 — generate synthetic ONNX kernels for RK3588 characterization.

Each kernel is a single, pure operation with a known FLOP and byte cost, so the
on-device runner (run_bench.py) can convert measured latency into achieved
GFLOP/s (compute ceiling, Layer 1) or GB/s (bandwidth, Layer 2), or simply
confirm an op converts + runs at all (operator-support map, Layer 4).

Weights are baked as initializers (resident in the model, like real weights) so
the only per-call host transfer is the activation input — this isolates compute
from marshalling.

Outputs <out>/<name>.onnx plus <out>/manifest.json describing every kernel
(op, shapes, flops, in/out bytes) for the downstream stages.

Runs anywhere with onnx + numpy (no rknn-toolkit2, no NPU). Typically on the
laptop or in the tagx Poetry env.

Usage:
    python gen_kernels.py --out kernels --suite l1        # compute sweep
    python gen_kernels.py --out kernels --suite l2        # bandwidth sweep
    python gen_kernels.py --out kernels --suite ops       # L4 feasibility probes
    python gen_kernels.py --out kernels --suite all
"""
import argparse
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

OPSET = 14


def _save(graph, path: Path):
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", OPSET)])
    model.ir_version = 9  # rknn-toolkit2 2.3.2 expects ir_version <= 9
    onnx.checker.check_model(model)
    onnx.save(model, str(path))


def _init(name, arr):
    return numpy_helper.from_array(arr.astype(np.float32), name=name)


# ── L1: compute-bound matmul  C(1,M,N) = A(1,M,K) @ W(K,N) ───────────────────
def gen_matmul(out: Path, M: int, K: int, N: int):
    name = f"matmul_{M}x{K}x{N}"
    W = np.random.randn(K, N).astype(np.float32) * 0.02
    a = helper.make_tensor_value_info("A", TensorProto.FLOAT, [1, M, K])
    c = helper.make_tensor_value_info("C", TensorProto.FLOAT, [1, M, N])
    node = helper.make_node("MatMul", ["A", "W"], ["C"])
    graph = helper.make_graph([node], name, [a], [c], initializer=[_init("W", W)])
    _save(graph, out / f"{name}.onnx")
    return {
        "name": name, "op": "MatMul", "suite": "l1",
        "input_shapes": {"A": [1, M, K]},
        "flops": 2 * M * K * N,
        "in_bytes": M * K * 4, "out_bytes": M * N * 4,
    }


# ── L1: compute-bound conv2d (NPUs are conv-optimised) ───────────────────────
def gen_conv(out: Path, C: int, HW: int, Cout: int, k: int = 3):
    name = f"conv_{C}x{HW}x{HW}_{Cout}k{k}"
    W = np.random.randn(Cout, C, k, k).astype(np.float32) * 0.02
    b = np.zeros(Cout, np.float32)
    x = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, C, HW, HW])
    y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, Cout, HW, HW])
    node = helper.make_node("Conv", ["X", "W", "B"], ["Y"],
                            kernel_shape=[k, k], pads=[k // 2] * 4, strides=[1, 1])
    graph = helper.make_graph([node], name, [x], [y],
                              initializer=[_init("W", W), _init("B", b)])
    _save(graph, out / f"{name}.onnx")
    return {
        "name": name, "op": "Conv", "suite": "l1",
        "input_shapes": {"X": [1, C, HW, HW]},
        "flops": 2 * Cout * C * k * k * HW * HW,
        "in_bytes": C * HW * HW * 4, "out_bytes": Cout * HW * HW * 4,
    }


# ── L2: bandwidth-bound elementwise add  C = A + B over a 4D feature map ──────
# Use NCHW (1,C,HW,HW): flat (1,S) tensors make rknn-toolkit2 emit pathological
# artifacts (a 1M-elem flat add compiled to a 37 MB model and ran at ~0.06 GB/s).
# A 4D shape compiles cleanly, like conv.
def gen_elementwise(out: Path, C: int, HW: int):
    S = C * HW * HW
    name = f"add_{C}x{HW}x{HW}"
    shape = [1, C, HW, HW]
    a = helper.make_tensor_value_info("A", TensorProto.FLOAT, shape)
    b = helper.make_tensor_value_info("B", TensorProto.FLOAT, shape)
    c = helper.make_tensor_value_info("C", TensorProto.FLOAT, shape)
    node = helper.make_node("Add", ["A", "B"], ["C"])
    graph = helper.make_graph([node], name, [a, b], [c])
    _save(graph, out / f"{name}.onnx")
    return {
        "name": name, "op": "Add", "suite": "l2",
        "input_shapes": {"A": shape, "B": shape},
        "flops": S,
        "in_bytes": 2 * S * 4, "out_bytes": S * 4,  # read A,B write C
    }


# ── L4: single-op feasibility probes ─────────────────────────────────────────
def gen_op_probe(out: Path, op: str):
    """Minimal model exercising one op; run_bench reports convert/run success."""
    S = 256
    if op == "Softmax":
        x = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, S, S])
        y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, S, S])
        node = helper.make_node("Softmax", ["X"], ["Y"], axis=-1)
        graph = helper.make_graph([node], f"op_{op}", [x], [y])
        ishapes = {"X": [1, S, S]}
    elif op == "Transpose":
        x = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, S, S])
        y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, S, S])
        node = helper.make_node("Transpose", ["X"], ["Y"], perm=[0, 2, 1])
        graph = helper.make_graph([node], f"op_{op}", [x], [y])
        ishapes = {"X": [1, S, S]}
    elif op == "Gather":
        data = np.random.randn(S, 64).astype(np.float32)
        idx = helper.make_tensor_value_info("idx", TensorProto.INT64, [1])
        y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, 64])
        node = helper.make_node("Gather", ["data", "idx"], ["Y"], axis=0)
        graph = helper.make_graph([node], f"op_{op}", [idx], [y],
                                  initializer=[_init("data", data)])
        ishapes = {"idx": [1]}
    elif op == "Sigmoid":
        x = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, S, S])
        y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, S, S])
        node = helper.make_node("Sigmoid", ["X"], ["Y"])
        graph = helper.make_graph([node], f"op_{op}", [x], [y])
        ishapes = {"X": [1, S, S]}
    else:
        raise ValueError(f"unknown op probe: {op}")
    _save(graph, out / f"op_{op}.onnx")
    return {"name": f"op_{op}", "op": op, "suite": "ops",
            "input_shapes": ishapes, "flops": 0, "in_bytes": 0, "out_bytes": 0}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="kernels")
    ap.add_argument("--suite", choices=["l1", "l2", "ops", "all"], default="all")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = []

    if args.suite in ("l1", "all"):
        for S in (256, 512, 1024, 2048):
            manifest.append(gen_matmul(out, S, S, S))
        for HW in (32, 64, 128):
            manifest.append(gen_conv(out, 64, HW, 64))

    if args.suite in ("l2", "all"):
        for C, HW in ((64, 128), (128, 256), (256, 256)):  # 1M, 8.4M, 16.8M elems, 4D
            manifest.append(gen_elementwise(out, C, HW))

    if args.suite in ("ops", "all"):
        for op in ("Softmax", "Transpose", "Gather", "Sigmoid"):
            manifest.append(gen_op_probe(out, op))

    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"Generated {len(manifest)} kernels -> {out}/  (+ manifest.json)")


if __name__ == "__main__":
    main()
