"""Convert the Whisper medium encoder ONNX to INT8 RKNN with real mel calibration.

#314 test: does INT8 quantization of a real Whisper component produce a usable
model, or empty/broken output? Run on x86 with rknn-toolkit2 (tagx poetry env).
"""
import argparse
import sys
import types
import numpy as np
import onnx

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
        int(onnx.TensorProto.BOOL): np.dtype("bool"),
    }
    _m.NP_TYPE_TO_TENSOR_TYPE = {v: k for k, v in _m.TENSOR_TYPE_TO_NP_TYPE.items()}
    onnx.mapping = _m
    sys.modules["onnx.mapping"] = _m

from rknn.api import RKNN


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--onnx", required=True, help="Path to the input encoder ONNX")
    p.add_argument("--dataset", required=True, help="Path to the calibration dataset.txt")
    p.add_argument("--out", required=True, help="Output path for the INT8 .rknn")
    args = p.parse_args()

    rknn = RKNN(verbose=False)
    rknn.config(target_platform="rk3588", optimization_level=3)
    assert rknn.load_onnx(model=args.onnx, inputs=["mel"],
                          input_size_list=[[1, 80, 3000]]) == 0, "load_onnx failed"
    print("building INT8 (do_quantization=True) with 10 real mel windows...")
    ret = rknn.build(do_quantization=True, dataset=args.dataset)
    assert ret == 0, f"build failed: {ret}"
    assert rknn.export_rknn(args.out) == 0, "export failed"
    print(f"OK -> {args.out}")
    rknn.release()


if __name__ == "__main__":
    main()
