# NPU Model Management

Guide to running LLMs on the RK3588 NPU via rknn-llm. Covers storage layout,
downloading pre-converted models, the conversion pipeline for new models, and
automation scripts.

---

## Background

Ollama does not use the RK3588 NPU — it falls back to CPU-only inference.
The rknn-llm toolkit (Rockchip official) exposes the NPU for LLM inference
and can deliver 5–40 tok/s depending on model size, versus ~1–5 tok/s on CPU.

**Memory architecture:** The NPU uses the same LPDDR5 DRAM as the CPU (unified
memory). The 6 MB NPU SRAM is a per-layer compute buffer, not a model size
limit. With 32 GB per RK1 module, models up to 13B Q4 (~7 GB) fit easily.

**Supported model families (rknn-llm 1.1.x):**
Llama 2/3/3.1/3.2, Qwen2/2.5, Phi-2/3/3.5, Gemma, MiniCPM, InternLM2.

---

## Storage layout

RKNN model files live on the NVMe SSD of whichever node runs rkllm-server.
The convention used in this cluster:

```
/mnt/ssd/rkllm-models/
  Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm
  <model-name>.rkllm
  ...
```

**Permissions note:** `/mnt/ssd` is owned by root (mounted via fstab by the
bootstrap scripts). Writes require `sudo`. The rkllm-server pod runs privileged
so it can read root-owned files without issue. To allow non-root writes:

```bash
sudo chown -R $USER:$USER /mnt/ssd/rkllm-models
# or create a shared group:
sudo groupadd rkllm
sudo usermod -aG rkllm $USER
sudo chown -R root:rkllm /mnt/ssd/rkllm-models
sudo chmod -R 775 /mnt/ssd/rkllm-models
```

---

## Downloading pre-converted models

Pre-converted `.rkllm` files are available on HuggingFace. No x86 toolchain
needed — download directly to the target node.

### Recommended: c01zaut's Llama 3.1 8B collection

Repository: `https://huggingface.co/c01zaut/Llama-3.1-8B-Instruct-rk3588-1.1.2`

24 variants with different quantization and NPU/CPU split:

| Parameter | Values | Notes |
|---|---|---|
| quantization | `w8a8`, `w8a8_g128`, `w8a8_g256`, `w8a8_g512` | g128 = finest group, best quality |
| opt level | `opt-0`, `opt-1` | opt-1 = better NPU utilization |
| hybrid-ratio | `0.0`, `0.5`, `1.0` | fraction running on NPU (1.0 = all NPU) |

**Best starting point** (all NPU, best quality W8A8):
```
Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm
```

### Download to node1 via SSH

`/mnt/ssd` is owned by root — both `mkdir` and `wget` require `sudo`:

```bash
ssh rk1-node1 "sudo mkdir -p /mnt/ssd/rkllm-models"
ssh rk1-node1 "sudo wget -O /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm \
  'https://huggingface.co/c01zaut/Llama-3.1-8B-Instruct-rk3588-1.1.2/resolve/main/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm'"
```

The download is ~8.5 GB. On a fast home connection this takes ~5 minutes
(verified: 32.9 MB/s, 4m 23s on 2026-05-12).

### Alternative: jamescallander's single-file repo

```bash
# Simpler filename, same W8A8 g128 quality:
ssh rk1-node1 "sudo wget -O /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct_w8a8_g128_rk3588.rkllm \
  'https://huggingface.co/jamescallander/Llama-3.1-8B-Instruct_w8a8_g128_rk3588.rkllm/resolve/main/Llama-3.1-8B-Instruct_w8a8_g128_rk3588.rkllm'"
```

### Verify download

```bash
ssh rk1-node1 "ls -lh /mnt/ssd/rkllm-models/"
# Expected: ~8.5G for 8B W8A8
```

---

## rkllama directory structure and Modelfile

rkllama (ghcr.io/notpunchnox/rkllama) expects each model in its own
subdirectory with a `Modelfile` alongside the `.rkllm` file:

```
/mnt/ssd/rkllm-models/
  <model-name>/               ← directory name = model name used in API calls
    <model-name>.rkllm        ← the converted model file
    Modelfile                 ← required metadata file (see format below)
```

**Important:** the `.rkllm` file must be inside a subdirectory, not at the
top level. A flat file is not recognised.

### Modelfile format

rkllama uses `KEY="value"` syntax, **not** the `KEY value` format used by
Ollama. Both `FROM` and `HUGGINGFACE_PATH` are required:

```
FROM="<model-filename>.rkllm"
HUGGINGFACE_PATH="<huggingface-repo-id>"
```

Example for the Llama 3.1 8B c01zaut port:

```bash
sudo mkdir -p /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0

# Move the downloaded .rkllm into the subdirectory
sudo mv /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm \
  /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0/

# Write the Modelfile
sudo tee /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0/Modelfile << 'EOF'
FROM="Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm"
HUGGINGFACE_PATH="c01zaut/Llama-3.1-8B-Instruct-rk3588-1.1.2"
EOF
```

---

## Running rkllama

### Quick start (bare Docker, for testing)

```bash
sudo docker run -d --privileged --name rkllama \
  -p 8080:8080 \
  -v /mnt/ssd/rkllm-models:/opt/rkllama/models \
  ghcr.io/notpunchnox/rkllama:main
```

Flags:
- `--privileged` — required for NPU device access
- `-v` — mounts model directory; models are discovered at runtime

Check startup (look for "RK3588 frequencies optimized" and Flask listening):
```bash
sudo docker logs rkllama
```

### Verify inference

```bash
# Generate endpoint (streaming NDJSON)
curl -s -X POST http://localhost:8080/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0","prompt":"hello"}'

# Chat endpoint (Ollama-compatible, stream:false for single response)
curl -s -X POST http://localhost:8080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model":"Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0",
       "messages":[{"role":"user","content":"hello"}],"stream":false}'
```

### Observed performance (RK3588, 32 GB, W8A8 g128, hybrid-ratio 1.0)

- First token latency: ~8–9s (includes model load on first request)
- Generation throughput: ~1.6 tok/s
- Prompt processing: ~13.5 tok/s
- CPU fan: silent (NPU does the compute, not CPU cores)
- Model stays resident between requests (no unload overhead)

---

## Converting models from scratch (x86 host)

Use this when no pre-converted file exists for your target model.

### Prerequisites (laptop / x86 host)

```bash
# Clone rknn-llm toolkit
git clone https://github.com/airockchip/rknn-llm
cd rknn-llm

# Create conda environment (Python 3.10 recommended)
conda create -n rknn-llm python=3.10
conda activate rknn-llm
pip install -r rkllm-toolkit/requirements.txt
```

### Conversion pipeline

```
HuggingFace safetensors  ──→  rknn-llm toolkit (x86)  ──→  .rkllm file
```

Input: HuggingFace model directory (safetensors format).
Output: single `.rkllm` binary, deployed to the target node.

```python
# convert.py — minimal conversion script
from rkllm.api import RKLLM

llm = RKLLM()
llm.load_huggingface(
    model="meta-llama/Llama-3.1-8B-Instruct",  # HF repo or local path
    model_lm_head="lm_head.safetensors",
)
llm.build(
    do_quantization=True,
    optimization_level=1,           # 0 or 1; 1 = better NPU utilization
    quantized_dtype="w8a8_g128",    # w8a8, w8a8_g128, w8a8_g256, w8a8_g512
    target_platform="rk3588",
    hybrid_quant_config=None,       # None = all NPU (hybrid-ratio 1.0)
)
llm.export_rkllm("./output/mymodel.rkllm")
```

Conversion takes 10–30 minutes on a modern laptop depending on model size.

### Transfer to cluster node

```bash
scp output/mymodel.rkllm rk1-node1:/tmp/
ssh rk1-node1 "sudo mv /tmp/mymodel.rkllm /mnt/ssd/rkllm-models/"
```

---

## Hybrid ratio tuning

The `hybrid-ratio` controls what fraction of layers run on NPU vs CPU:

| Ratio | Meaning | Use when |
|---|---|---|
| `1.0` | All NPU | Default; fastest inference if model fits in DRAM |
| `0.5` | 50% NPU, 50% CPU | Useful if NPU memory pressure causes errors |
| `0.0` | All CPU | Debugging only — defeats the purpose |

Start with `1.0`. If inference crashes or produces garbage, try `0.5`.

---

## Quantization format comparison

| Format | Size (8B) | Quality | Notes |
|---|---|---|---|
| `w8a8` | ~8 GB | Good | No grouping; faster conversion |
| `w8a8_g128` | ~8 GB | Better | 128-weight groups; recommended |
| `w8a8_g256` | ~8 GB | Moderate | Larger groups = slightly lower quality |
| `w8a8_g512` | ~8 GB | Lower | Largest groups; fastest but less accurate |

The file size difference between group sizes is minimal — prefer `g128`.

---

## Automation (planned)

`scripts/pull-rkllm-model.sh` — not yet implemented. Planned interface:

```bash
# Download a named model to a target node
./scripts/pull-rkllm-model.sh --model llama3.1-8b-w8a8_g128-opt1 --node rk1-node1

# List available pre-converted models
./scripts/pull-rkllm-model.sh --list

# Convert from HuggingFace (requires x86 host with rknn-llm conda env)
./scripts/pull-rkllm-model.sh --convert meta-llama/Llama-3.1-8B-Instruct --node rk1-node1
```

This script does not exist yet — see R-01 in the backlog.

---

---

## Whisper STT on RK3588

Whisper (speech-to-text) is a much better fit for the RK3588 than large LLMs:
models are 75 MB – 3 GB, and the LPDDR5 memory bandwidth advantage is more
proportionally useful at this scale.

### Storage convention

Model weights go on the NVMe SSD, not the eMMC. Set `download_root` accordingly:

```
/mnt/ssd/whisper-models/      ← HuggingFace model cache root
```

`/mnt/ssd` is root-owned. Create the directory before first use:

```bash
sudo mkdir -p /mnt/ssd/whisper-models
sudo chown -R $USER:$USER /mnt/ssd/whisper-models
```

### Containerisation principle

All Whisper inference on the cluster runs in containers — no bare pip installs
on nodes. The image source is the **tagx** auxiliary repo (working name; not yet
created) which provides reusable ARM64 base images shared across projects. Until
tagx exists, use `python:3.12-slim` for throwaway benchmarks:

```bash
sudo docker run --rm \
  -v /mnt/ssd/whisper-models:/models \
  -v /tmp/audio.wav:/audio/audio.wav:ro \
  python:3.12-slim \
  bash -c "pip install -q faster-whisper && python3 -c \"
from faster_whisper import WhisperModel
wm = WhisperModel('large-v3', device='cpu', compute_type='int8', download_root='/models')
segs, info = wm.transcribe('/audio/audio.wav', beam_size=5, language='sv', vad_filter=True)
[print(s.text.strip()) for s in segs]
\""
```

### CPU benchmark results (2-min clip, 2026-06-15)

faster-whisper/CTranslate2 is CPU-only on RK3588 — **the NPU is not used**.
CTranslate2 has no RKNN backend; NPU inference requires a separate RKNN
conversion pipeline (see NPU section below).

| Model    | Size   | Laptop AVX2 | RK3588 CPU | Slowdown |
|----------|--------|-------------|------------|----------|
| tiny     | 75 MB  | 9s          | TBD        | —        |
| base     | 145 MB | 4s          | TBD        | —        |
| small    | 462 MB | 6s          | TBD        | —        |
| medium   | 1.5 GB | 22s         | 58s        | 2.6×     |
| large-v3 | 3 GB   | 81s         | 93s        | 1.15×    |

Laptop: HP EliteBook x360 1030 G4, Intel i7 8th gen, AVX2, int8.
RK3588: TuringPi RK1 node, ARM64, LPDDR5 32 GB, CPU-only (faster-whisper).

**Key insight:** large-v3 gap (1.15×) is much smaller than medium (2.6×). Large
is more memory-bandwidth-bound, where LPDDR5 narrows the gap; medium is more
compute-bound, where AVX2 int8 dominates. For a 64-min recording, large-v3 on
a single RK3588 node is only ~10 min slower than the laptop.

### NPU inference via RKNN — medium (2026-06-16)

Whisper medium was converted to RKNN FP32 using `rknn-toolkit2` on an x86
laptop (see tagx repo for conversion scripts). Validated on node1 using the
`tagx/whisper-stt:rknn` container image.

**RKNN benchmark results (2-min clip, medium, 2026-06-16):**

| Component | RK3588 CPU | RK3588 NPU | Notes |
|-----------|------------|------------|-------|
| Encoder   | ~20s (est) | **10.4s**  | Single forward pass on NPU |
| Decoder   | —          | ~240s      | 47 steps, **no KV-cache** — not a valid benchmark |

The decoder time is not meaningful. The current RKNN decoder re-runs the full
448-token sequence on every decode step (no KV-cache). Each step takes ~5s —
47 steps = 240s. With a KV-cache decoder (cross-attention cached after step 1,
self-attention growing by 1 token/step), this should drop to ~1s total.
See W-03 in backlog.

**RKNN model sizes (FP32, medium):**

| File | Size |
|---|---|
| `whisper_encoder_medium.rknn` | 634 MB |
| `whisper_decoder_medium.rknn` | 1017 MB |

Models stored at `/mnt/ssd/whisper-models/rknn/medium/` on node1.

### NPU device access on this cluster

The RKNPU driver is compiled into the kernel (`CONFIG_ROCKCHIP_RKNPU=y`,
DRM GEM mode). **There is no `/dev/rknpu` device node.** The NPU is accessed
through the DRM render subsystem. `--privileged` is required for containers
until the exact device node mapping is confirmed (see ADR-0023).

The RKNN C runtime (`librknnrt.so`) is **not** installed on nodes by default
and is not bundled in `rknn-toolkit-lite2`. It must be either baked into the
container image at build time or mounted from the host. The `tagx/whisper-stt:rknn`
image downloads it from the Rockchip GitHub during build:

```
https://github.com/airockchip/rknn-toolkit2/raw/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so
```

**Version confirmed working: librknnrt.so 2.3.2** on driver 0.9.7, kernel 6.1.0-1025-rockchip (confirmed 2026-06-17; earlier concern about panics was not reproduced). Models must be compiled with rknn-toolkit2 matching the runtime version — do not mix 2.2.0 compiled models with 2.3.x runtime or vice versa. Note: rkllama uses `librkllmrt.so` (RKLLM stack), not `librknnrt.so` — this version constraint applies only to RKNN-based inference (Whisper, tagx images).

---

## See also

- `backlog/BACKLOG.md` — R-01: RK3588 NPU acceleration research item; W-03: Whisper STT self-attention KV cache
- `docs/PREREQUISITES.md` — cluster prerequisites before deploying rkllm-server
- `docs/HARDWARE-FIRMWARE-ISSUES.md` — index of outstanding NPU/RKNN hardware and firmware issues
- `charts/ollama/` — existing Ollama deployment (CPU-only, stays as fallback)
