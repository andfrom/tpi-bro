#!/usr/bin/env python3
"""
npu-bench Layer-7 probe — sustained-load thermal / DVFS behavior.

Hammers the NPU with a heavy kernel continuously and logs, per ~2s window:
throughput (GFLOP/s), npu-thermal temperature, and NPU clock. Burst peak vs
steady-state throughput reveals whether the device throttles under sustained
load — the derate factor that long-running agents actually live on.

Reads /sys/class/thermal (npu-thermal) and /sys/class/devfreq/*npu*/cur_freq
(works in a privileged container, which mounts /sys).

Run on a node via tagx/whisper-stt:rknn (privileged; see run_bench.py invocation).

    python thermal_test.py --rknn /bench/rknn --manifest /bench/manifest.json \
        --kernel conv_64x128x128_64k3 --precision fp16 --cores 7 --seconds 120
"""
import argparse
import glob
import json
import time
from pathlib import Path

import numpy as np
from rknnlite.api import RKNNLite

_TYPES = {0: "fp32", 1: "fp16", 2: "int8", 3: "uint8", 8: "int64"}
_NP = {"fp32": np.float32, "fp16": np.float16, "int8": np.int8, "int64": np.int64}


def find_npu_temp_path():
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        try:
            if "npu" in open(f"{z}/type").read().strip().lower():
                return f"{z}/temp"
        except OSError:
            pass
    return None


def find_npu_freq_path():
    for d in glob.glob("/sys/class/devfreq/*"):
        try:
            if "npu" in open(f"{d}/name").read().strip().lower():
                return f"{d}/cur_freq"
        except OSError:
            pass
    return None


def read_int(path, div=1):
    try:
        return int(open(path).read().strip()) / div
    except (OSError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rknn", default="rknn")
    ap.add_argument("--manifest", default="kernels/manifest.json")
    ap.add_argument("--kernel", default="conv_64x128x128_64k3")
    ap.add_argument("--precision", default="fp16")
    ap.add_argument("--cores", type=int, default=7)
    ap.add_argument("--seconds", type=float, default=120)
    ap.add_argument("--window", type=float, default=2.0)
    ap.add_argument("--run-only", action="store_true",
                    help="bind inputs once then loop run() only (max NPU duty cycle)")
    args = ap.parse_args()

    man = {e["name"]: e for e in json.loads(Path(args.manifest).read_text())}
    entry = man[args.kernel]
    flops = entry["flops"]
    rknn_path = Path(args.rknn) / f"{args.kernel}.{args.precision}.rknn"

    temp_path = find_npu_temp_path()
    freq_path = find_npu_freq_path()
    print(f"kernel={args.kernel} flops={flops/1e6:.1f}M cores={args.cores} "
          f"dur={args.seconds}s")
    print(f"temp={temp_path} freq={freq_path}\n")

    m = RKNNLite()
    m.load_rknn(str(rknn_path))
    m.init_runtime(core_mask=args.cores)
    r = m.rknn_runtime
    inputs = []
    for i in range(r.get_in_out_num()[0]):
        a = r.get_tensor_attr(i, is_output=False)
        dt = _NP.get(_TYPES.get(a.type, "fp32"), np.float32)
        inputs.append(np.random.randn(*list(a.dims[:a.n_dims])).astype(dt))

    for _ in range(10):  # warmup
        r.set_inputs(inputs, None, None); r.run(False); r.get_outputs(False)

    if args.run_only:
        r.set_inputs(inputs, None, None)  # bind once; hot loop is run() only
        def one_iter():
            r.run(False)
    else:
        def one_iter():
            r.set_inputs(inputs, None, None); r.run(False); r.get_outputs(False)

    print(f"{'t(s)':>6} {'GFLOP/s':>9} {'temp(C)':>8} {'freq(MHz)':>9} {'iters':>7}")
    t_start = time.perf_counter()
    series = []
    while time.perf_counter() - t_start < args.seconds:
        w0 = time.perf_counter()
        iters = 0
        while time.perf_counter() - w0 < args.window:
            one_iter()
            iters += 1
        dt = time.perf_counter() - w0
        gflops = flops * iters / dt / 1e9
        temp = read_int(temp_path, 1000) if temp_path else None
        freq = read_int(freq_path, 1e6) if freq_path else None
        t = time.perf_counter() - t_start
        series.append((t, gflops, temp, freq))
        print(f"{t:6.0f} {gflops:9.1f} "
              f"{(temp if temp is not None else -1):8.1f} "
              f"{(freq if freq is not None else -1):9.0f} {iters:7d}")
    m.release()

    gf = [s[1] for s in series]
    burst = max(gf[:3]) if len(gf) >= 3 else gf[0]
    steady = float(np.mean(gf[-3:]))
    temps = [s[2] for s in series if s[2] is not None]
    freqs = [s[3] for s in series if s[3] is not None]
    print(f"\nburst peak:   {burst:.0f} GFLOP/s")
    print(f"steady-state: {steady:.0f} GFLOP/s   "
          f"-> thermal derate {steady/burst:.2f} ({(1-steady/burst)*100:.0f}% drop)")
    if temps:
        print(f"temp: {min(temps):.0f} -> {max(temps):.0f} C")
    if freqs:
        print(f"freq: {max(freqs):.0f} -> {min(freqs):.0f} MHz "
              + ("(throttled)" if freqs and min(freqs) < max(freqs) else "(no freq drop)"))


if __name__ == "__main__":
    main()
