"""Generate real Whisper mel calibration windows for INT8 quantization.

Extracts several 30s windows from the Swedish recording, computes 80-mel
log-spectrograms (1,80,3000) float32, saves .npy + a dataset.txt for rknn.build.
Run in the tagx/whisper-stt:rknn container on node1 (has whisper + audio).
"""
import numpy as np
import whisper

AUDIO = "/audio/Rec_20260615_124615.wav"
OUT = "/calib"
OFFSETS_S = [0, 60, 120, 240, 360, 480, 600, 720, 900, 1080]  # varied content

import os
os.makedirs(OUT, exist_ok=True)
audio = whisper.load_audio(AUDIO)
sr = whisper.audio.SAMPLE_RATE
paths = []
for i, off in enumerate(OFFSETS_S):
    seg = audio[int(off * sr):]
    seg = whisper.pad_or_trim(seg)
    mel = whisper.log_mel_spectrogram(seg, n_mels=80).numpy()[np.newaxis, :].astype(np.float32)
    p = f"{OUT}/mel_{i:02d}.npy"
    np.save(p, mel)
    paths.append(p)
    print(f"  {p}  shape={mel.shape} norm={np.linalg.norm(mel):.1f}")

with open(f"{OUT}/dataset.txt", "w") as f:
    f.write("\n".join(paths) + "\n")
print(f"wrote {len(paths)} calibration mels + {OUT}/dataset.txt")
