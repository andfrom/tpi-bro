"""#314 correctness probe: FP16 vs INT8 Whisper encoder on the same real mel.

Runs both encoders on an identical mel window and compares the audio features.
The #314 bug manifests as empty/all-zero or garbage (near-zero cosine) output.
A high cosine + similar norm means INT8 quantization is numerically usable.

Run on node1 via tagx/whisper-stt:rknn (privileged).
"""
import numpy as np
from rknnlite.api import RKNNLite

FP16 = "/models/whisper_encoder_medium.rknn"
INT8 = "/models/whisper_encoder_medium_int8.rknn"
MEL = "/calib/mel_06.npy"  # offset 600s — same window used in decode tests


def run(path, mel):
    m = RKNNLite()
    assert m.load_rknn(path) == 0
    assert m.init_runtime() == 0
    out = m.inference(inputs=[mel])[0]
    m.release()
    return out.astype(np.float32)


mel = np.load(MEL).astype(np.float32)
print(f"mel {mel.shape} norm={np.linalg.norm(mel):.1f}\n")

af16 = run(FP16, mel)
af8 = run(INT8, mel)
print(f"FP16 features: shape={af16.shape} norm={np.linalg.norm(af16):.1f} "
      f"mean={af16.mean():.4f} std={af16.std():.4f}")
print(f"INT8 features: shape={af8.shape} norm={np.linalg.norm(af8):.1f} "
      f"mean={af8.mean():.4f} std={af8.std():.4f}")

a, b = af16.ravel(), af8.ravel()
cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))
maxerr = float(np.max(np.abs(a - b)))
rel = float(np.linalg.norm(a - b) / (np.linalg.norm(a) + 1e-9))
zero_frac = float(np.mean(np.abs(b) < 1e-6))

print(f"\ncosine(FP16,INT8) = {cos:.4f}")
print(f"relative L2 error  = {rel:.4f}")
print(f"max abs error      = {maxerr:.3f}")
print(f"INT8 zero fraction = {zero_frac:.3f}")

print("\n=== #314 verdict ===")
if zero_frac > 0.5 or np.linalg.norm(af8) < 1e-3:
    print("BROKEN — INT8 output is empty/near-zero (#314 reproduced)")
elif cos > 0.95:
    print(f"USABLE — INT8 features track FP16 closely (cos={cos:.3f})")
elif cos > 0.8:
    print(f"DEGRADED — INT8 diverges but not empty (cos={cos:.3f}); check transcription")
else:
    print(f"BROKEN — INT8 output is garbage (cos={cos:.3f}, not empty)")
