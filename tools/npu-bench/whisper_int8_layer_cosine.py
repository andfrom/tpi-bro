#!/usr/bin/env python3
"""Compute per-layer cosine (float golden vs INT8 simulator) from an
rknn accuracy_analysis output dir, to localize where INT8 collapses.
Usage: point /out at the accuracy_analysis output_dir; run with numpy."""
import numpy as np, glob, os, re, sys
base = sys.argv[1] if len(sys.argv) > 1 else "/out/accuracy"
g, s = f"{base}/golden/npy", f"{base}/simulator/npy"
rows = []
for gp in glob.glob(f"{g}/*.npy"):
    name = os.path.basename(gp); sp = f"{s}/{name}"
    if not os.path.exists(sp): continue
    try:
        a = np.load(gp).ravel().astype(np.float64); b = np.load(sp).ravel().astype(np.float64)
    except Exception: continue
    if a.size != b.size or a.size == 0: continue
    rows.append((name, float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))))
bidx = lambda n: (int(m.group(1)) if (m := re.search(r'_blocks_(\d+)', n)) else -1)
rows.sort(key=lambda r: (bidx(r[0]), r[0]))
for n, c in rows:
    print(f"{c:7.3f}  {n}" + ("  <== COLLAPSE" if c < 0.9 else (" <- low" if c < 0.98 else "")))
print(f"\nlayers<0.9: {sum(1 for _,c in rows if c<0.9)}/{len(rows)}")
