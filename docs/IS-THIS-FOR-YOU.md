# Is a TuringPi 2 + RK1 Cluster For You?

A pragmatic answer, from actually running one — what it's genuinely good at,
what it struggles with, the roadblocks you'll hit getting there, and what
`tpi-bro` specifically buys you versus doing it all by hand. Performance
numbers here are measured on this cluster (4× RK1, RK3588, 32 GB/module),
not vendor marketing figures — sources are linked throughout.

## The short version

- **Good for:** learning real Kubernetes/GitOps operations on real ARM
  hardware, low-power always-on services, small-to-medium CPU workloads,
  batch speech-to-text, and NPU experimentation if you enjoy debugging
  closed-source vendor SDKs as a hobby.
- **Not good for:** running frontier-scale LLMs at good latency, anything
  that wants a real GPU (CUDA/ROCm), production multi-tenant serving, or
  low-latency real-time inference of any kind, today.
- **The catch:** the RK3588 NPU's headline "6 TOPS/module" doesn't translate
  to 6 TOPS of usable transformer throughput. Advertised TOPS is an INT8
  conv number; transformer inference is matmul-heavy and INT8 is currently
  broken for real transformer models on this stack, so you're on the much
  slower FP16 path. See the measured gap below — it's the single most
  important thing to understand before buying hardware for an LLM/Whisper
  project specifically.

## Hardware, honestly

| | Spec | Reality check |
|---|---|---|
| Compute modules | 4× RK1 (RK3588, ARM64), 32 GB LPDDR5 each, 128 GB total | Not a shared pool — a model's weights must fit in **one** module's RAM (~28–30 GB usable). No cross-node sharding. One model per node, max. |
| GPU | Mali G610 MP4 (OpenCL only) | Not viable for LLM/transformer inference — no CUDA/ROCm equivalent exists for it. Budget for CPU or NPU only. |
| NPU | 6 TOPS/module, 24 TOPS across 4 modules (marketing figure) | **Measured** FP16 ceiling: conv ~1.5 TFLOP/s (3-core), but matmul — what attention layers actually run — only **~230 GFLOP/s**, a ~6× gap from the conv number. INT8 would close that gap (2.3 TFLOP/s measured) but is numerically broken on real transformer models on this stack (collapses to ~94% near-zero output, cosine 0.25 vs FP16) — so FP16 is mandatory today, and you don't get the fast path. [Full measurements](NPU-DATASHEET.md). |
| CPU | Same silicon, general-purpose cores | Comparable to the NPU on real workloads more often than you'd expect — a flat ~58 GFLOP/s across 8 cores, and CPU-side INT8 (via `faster-whisper`, a mature software stack) currently **beats** the NPU's default decode path for Whisper (see below). The CPU isn't a fallback you begrudgingly accept; sometimes it's the better tool for the job as-is today. |
| Power | ~10 W idle/module | Genuinely low. The NPU stays silent even at 100% duty (+4 °C in thermal testing) — the CPU is what spins the fans (+20 °C at 100% across 8 cores). |

## What you can actually do today

**Speech-to-text (Whisper)** is the one workload validated end-to-end — real
Helm chart, real Kubernetes Job, real hardware, real audio in, correct
transcript out, on both paths:

- **CPU** (`faster-whisper`): ~3–4× slower than real-time at `medium`/FP16
  quality; INT8-quantized CPU decode gets to ~2× real-time. `small` is the
  first model size that hits real-time (~1×), at "first usable quality" —
  don't expect `large-v3` accuracy in real time on this hardware.
- **NPU**: the encoder step is genuinely fast — roughly 2× the CPU encoder.
  The decoder, as originally wired (no KV cache), was
  not: our own live test (`medium` model, RK1 hardware, a 3-second
  clip) measured **10.4 s to encode, 55.1 s to decode** (11 tokens, greedy,
  no cache) — much slower than real-time for this exact configuration.
  KV-cache decoder variants fix that: the full self-attention KV-cache
  decoder (**W-03**) now runs correctly on hardware at ~2.0 s/step —
  **~2.5× measured** over the naive decoder (a further ~1.10× measured
  from FP16 input feeds, not the ~1.5× once projected) — after a two-day
  hunt for a genuine runtime bug (the vendor's runtime silently drops
  native-layout inputs; see
  [RKNN-SA-KV-DECODER-BUG.md](RKNN-SA-KV-DECODER-BUG.md)). It's wired
  into `charts/whisper/` (`rknn.decoder: sa-kv`), but even so, the honest
  recommendation for anything latency-sensitive is still CPU, not NPU.
  Even `large-v3` runs end-to-end on the NPU (validated: word-perfect
  transcript, ~3.6 s/step, 26.9 s encode per 30 s window) — batch-quality
  transcription at the highest model quality, nowhere near real time. (An
  earlier claim that large-v3 "cannot even initialize" was retracted: the
  20+ GB allocation that wedged a node was a bug in our own test harness,
  not in the vendor runtime — the full story, including the retraction, is
  in [RKNN-SA-KV-DECODER-BUG.md](RKNN-SA-KV-DECODER-BUG.md).)

**LLM inference via Ollama** (CPU-only — llama.cpp has no RK3588 NPU
backend; an NPU LLM path exists but its one local benchmark lost to the
CPU, so it's parked as [R-01](backlog/BACKLOG.md)) is faster than the
"small models only" framing suggests: measured on one RK1, `llama3.2:1b`
generates at **14.4 tok/s** and a 13B Q4 model (7.4 GB) at **2.6 tok/s**
— the latter usable for queue-batch work (a 100-token answer in ~40 s).
Output *quality* is a separate axis: `llama3.2:1b` produces unreliable
structured output on real evaluation tasks (too small for multi-step
instructions), and larger models' quality-per-task hasn't been validated
here yet — but the old assumption that 13B-class would be
throughput-prohibitive on CPU was measured away.

**General Kubernetes/GitOps platform work** is genuinely solid: k3s, Helm,
Flux GitOps, capability-based scheduling (NPU/NVMe as node labels instead of
hostname pins), a Tailscale mesh for remote access without exposing
anything publicly, a self-signed registry with real TLS. If your actual
interest is "learn real cluster operations on real ARM hardware," that part
of the experience is smooth — largely *because* `tpi-bro` exists (see
below).

## What you (currently) cannot do

- Run a model needing more than ~28–30 GB in one place — no cross-node
  sharding; see the [LLM Placement Constraint](../README.md#llm-placement-constraint) in the main README.
- Get GPU-class LLM throughput — no CUDA/ROCm path exists on this hardware;
  NPU transformer throughput tops out around 230 GFLOP/s FP16 today.
- Trust INT8 quantization for a transformer model — confirmed broken
  upstream ([airockchip/rknn_model_zoo#314](https://github.com/airockchip/rknn_model_zoo/issues/314)),
  open, no maintainer response as of this writing.
- Run NPU workloads without `--privileged` containers — no clean device
  allowlist exists yet on this SDK/kernel combination; not multi-tenant-safe.
- Get real-time NPU-accelerated Whisper transcription — even with the
  SA-KV decoder wired in (W-03, done), CPU still wins on decode latency;
  the NPU's edge is the encoder.

## Roadblocks, from actually doing this

None of these are hypothetical — each one cost real debugging time on this
project:

- **The RKNN SDK is closed-source and its own errors lie to you.** Its
  container sanity check prints "map these two files" — the real
  requirement was three different things, one of them (`/sys/firmware`)
  masked by Docker by default for security, discovered only by reading raw
  bytes out of the compiled `.so` for string literals since there's no
  source to read. See [ADR-0023](adr/ADR-0023-rknn-npu-device-access-pattern.md).
- **Version coupling between `librknnrt.so` and the kernel driver is
  undocumented and not forward/backward-compatible**, and a mismatch
  doesn't fail cleanly — it produces silently wrong output or job timeouts
  that can escalate to a hard NPU reset or kernel panic. There is no
  official compatibility matrix; ours came from testing on this exact
  hardware. See [HARDWARE-FIRMWARE-ISSUES.md](HARDWARE-FIRMWARE-ISSUES.md).
- **INT8 quantization breaks silently, not loudly** — the model runs
  without a runtime error and produces plausible-looking garbage. Root
  causing it took per-layer cosine-similarity analysis to find the actual
  collapse point (the attention softmax path); a naive test would have
  blamed calibration data and moved on.
- **A correctness bug that only exists on real hardware, that the vendor's
  own simulator cannot reproduce, and that produces zero errors anywhere.**
  The runtime silently never delivers model inputs that the compiler
  assigned the NPU's native tiled layout — the buffers just stay zero, the
  graph executes flawlessly over them, and nothing in userspace or the
  kernel says a word. Worse: the obvious test (output similarity vs a
  correct reference) *passes* on small models because the corruption is
  nearly invisible at shallow depth — it handed us a convincing, entirely
  fictional "breaks beyond 18 layers" theory for a day. What cracked it was
  fingerprinting the wrong outputs against explicit corruption hypotheses
  ("what if the caches were zeros?" matched at cosine 0.9996) and then
  routing around the broken path with a one-op graph change. Both the
  instrument and the fix are in the repos.
  See [RKNN-SA-KV-DECODER-BUG.md](RKNN-SA-KV-DECODER-BUG.md).
- **Don't count on airockchip to respond.** The upstream issue for the INT8
  bug above ([#314](https://github.com/airockchip/rknn_model_zoo/issues/314))
  was filed by a community member in April 2025; two more people independently
  hit the same bug over the following months. As of this writing, sixteen
  months later, **zero comments from an airockchip maintainer**. We have a
  root cause and a working workaround ready to post — see the tracker in
  [RKNN-INT8-WHISPER-314.md](RKNN-INT8-WHISPER-314.md) — but if you're
  planning around a vendor fix landing on any particular timeline, this
  project's own experience says don't.
- **BMC discovery is flaky by default** — mDNS resolution for
  `turingpi.local` fails on plenty of networks, and the auto-detect script's
  `nmap` reverse-DNS assumption rarely holds; manual IP entry ends up being
  the normal path, not the fallback.
- **Cross-compiling container images for ARM64 from an x86 laptop, against a
  self-signed registry, hits Docker buildx's isolated trust store** — the
  `docker-container` builder driver runs in its own network namespace with
  its own CA trust, so a straightforward `--push` silently can't verify the
  registry's cert even though `docker push` works fine from the host CLI.
- **Ubuntu's first-boot forced password change** breaks any bootstrap script
  that assumes a clean non-interactive SSH login on first connect.
- **The cluster's own network identity can change out from under you** —
  moving from LAN to a Tailscale-only network mid-project required
  reworking every script that had baked in a computed LAN IP instead of
  resolving nodes by hostname.

None of these are exotic — they're the standard tax of being an early
adopter on a young NPU software stack sitting on top of otherwise-solid ARM
SBC hardware.

## What `tpi-bro` actually buys you

Everything above is real, and none of it is specific to *this* project —
it's the tax of running a TuringPi 2 + RK1 cluster at all. What `tpi-bro`
does is absorb that tax once, in public, so you don't pay it again:

- A **phase-based, resumable bootstrap** (flash → name → network → k3s →
  registry → storage → mesh) instead of a wall of manual steps you have to
  get right in order, every time.
- **Capability-based scheduling** (`storage.tpi-bro/nvme`, `tpi-bro/npu`)
  instead of hostname pins, so workloads describe what they need instead of
  which specific box to land on.
- A **self-signed registry with real TLS** distributed to every node,
  instead of the `insecure-registries` shortcut that quietly becomes a
  liability the moment the cluster leaves your LAN.
- A **Tailscale mesh** so the cluster is reachable from anywhere without
  exposing anything to the public internet, and a kubeconfig that survives
  switching between LAN and Tailscale without manual editing.
- **GitOps via Flux** instead of ad-hoc `kubectl apply`, so cluster state is
  reconstructible from Git, not tribal knowledge.
- A **documented ADR/backlog process**, so tradeoffs like "RKNN containers
  run `--privileged` because the alternative is unresolved vendor-SDK
  archaeology" are recorded with their reasoning, not silently baked into a
  script someone has to reverse-engineer later. See
  [docs/adr/](adr/), [BACKLOG.md](backlog/BACKLOG.md), and
  [HARDWARE-FIRMWARE-ISSUES.md](HARDWARE-FIRMWARE-ISSUES.md) for the receipts.

The hardware and the vendor SDK are what they are — `tpi-bro` doesn't change
the NPU's real throughput or fix airockchip's INT8 bug. What it changes is
how much of the surrounding yak-shaving you have to redo yourself before you
get to the part you actually wanted to work on.

## Bottom line

Buy this hardware if you want a genuinely fun, low-power, real-ARM-hardware
platform to learn cluster operations on, and you're fine with the NPU being
a research toy rather than a production accelerator for now. Don't buy it
expecting GPU-class LLM inference, real-time transcription out of the box,
or a finished product — you're adopting early on a young stack, and this
project's whole job is to make that adoption cost as small as it can be.
