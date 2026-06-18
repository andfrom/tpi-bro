"""#314 root-cause: per-layer accuracy analysis of the INT8 Whisper encoder.

Builds the encoder INT8 and runs rknn.accuracy_analysis to compute per-layer
cosine similarity between the float and quantized graphs. The layer where cosine
collapses is where INT8 quantization breaks — the candidate to spare in hybrid
quantization. Runs in tagx/whisper-rknn-convert on node2 (full toolkit).
"""
import sys, types
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

ONNX = "/onnx/medium/encoder/whisper_encoder_medium.onnx"
DATASET = "/calib/dataset.txt"
SAMPLE = "/calib/mel_06.npy"
OUTDIR = "/out/accuracy"

rknn = RKNN(verbose=False)
rknn.config(target_platform="rk3588", optimization_level=3)
assert rknn.load_onnx(model=ONNX, inputs=["mel"], input_size_list=[[1, 80, 3000]]) == 0
print("building INT8...")
assert rknn.build(do_quantization=True, dataset=DATASET) == 0
print("running accuracy_analysis (float vs quantized, per layer)...")
ret = rknn.accuracy_analysis(inputs=[SAMPLE], output_dir=OUTDIR)
print(f"accuracy_analysis ret={ret}")
rknn.release()
