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

```bash
ssh rk1-node1 "sudo mkdir -p /mnt/ssd/rkllm-models"
ssh rk1-node1 "sudo wget -O /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm \
  'https://huggingface.co/c01zaut/Llama-3.1-8B-Instruct-rk3588-1.1.2/resolve/main/Llama-3.1-8B-Instruct-rk3588-w8a8_g128-opt-1-hybrid-ratio-1.0.rkllm'"
```

The download is ~8 GB. Progress is shown by wget. On a typical home connection
this takes 5–20 minutes.

### Alternative: jamescallander's single-file repo

```bash
# Simpler filename, same W8A8 g128 quality:
ssh rk1-node1 "sudo wget -O /mnt/ssd/rkllm-models/Llama-3.1-8B-Instruct_w8a8_g128_rk3588.rkllm \
  'https://huggingface.co/jamescallander/Llama-3.1-8B-Instruct_w8a8_g128_rk3588.rkllm/resolve/main/Llama-3.1-8B-Instruct_w8a8_g128_rk3588.rkllm'"
```

### Verify download

```bash
ssh rk1-node1 "ls -lh /mnt/ssd/rkllm-models/"
# Expected: ~8.0G for 8B W8A8
```

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

## See also

- `mem/backlog/BACKLOG.md` — R-01: RK3588 NPU acceleration research item
- `docs/PREREQUISITES.md` — cluster prerequisites before deploying rkllm-server
- `charts/ollama/` — existing Ollama deployment (CPU-only, stays as fallback)
