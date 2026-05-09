# ADR-0003: One LLM-Backed Agent Per RK1 Module (No Cross-Module Model Sharding)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

Large language models require contiguous memory — the full model weight set must reside in a single address space on a single physical machine. It is not possible to shard a single LLM across multiple RK1 modules the way you might shard a database or stateless service.

Each RK1 module (RK3588 SoC) provides 32 GB LPDDR5 RAM. At 4× modules, total cluster RAM is 128 GB — but usable for any single model is ≤ 32 GB per node.

The RK3588 includes a Mali G610 GPU (not useful for LLM inference — no CUDA/ROCm support) and a 6 TOPS NPU. Practically, LLM inference runs on CPU+RAM at this scale.

## Decision

**Each LLM-backed agent service is deployed to exactly one RK1 module.** Kubernetes scheduling must enforce this via `nodeSelector` or `nodeName`. The model weights must fit in the node's available RAM after OS and system overhead (roughly 28–30 GB usable).

Non-LLM supporting services (API gateway, vector DB, queue, etc.) can be freely scheduled across nodes as normal K8s workloads.

A suggested initial workload distribution (for a multi-agent coding assistant use case):
- `rk1-node1`: Control plane + Agent A agent (scoring LLM)  
- `rk1-node2`: Future agent (e.g., Pair Programmer)  
- `rk1-node3`: Future agent (e.g., Code/Build Optimizer)  
- `rk1-node4`: RAG / vector DB / supporting infra  

## Consequences

**Positive:**
- Models load reliably without OOM; RAM is the hard constraint and this respects it
- Simple reasoning: "which node runs which model" is a 1:1 mapping
- Node failure is predictable — only that node's agent goes down

**Negative:**
- Cannot run a model larger than ~28–30 GB on a single node
- Cluster cannot pool memory for one very large model — use a Jetson Orin Nano or cloud GPU for that
- Node count caps the number of simultaneously-running LLM agents

## Alternatives Considered

- **Tensor parallelism across nodes**: Not supported by llama.cpp/Ollama for ARM64 at this scale; requires high-bandwidth interconnect
- **Model quantization to fit smaller**: Valid technique — 4-bit quant of a 70B model can fit in ~35 GB, still exceeds single-node. Stay on models that fit in ≤28 GB.
