# Future Ideas

Ideas that are not ready for the backlog or ADRs — either because they need more thought, require prior phases to be complete first, or because the technical landscape is still evolving. Captured here so they are not lost.

---

## Hybrid Compute: Cluster + High-RAM Laptop

**Idea:** A powerful laptop (e.g., with 64–192 GB unified RAM) could serve as the primary inference powerhouse for heavy models, while the TuringPi cluster handles distributed, parallel, or lower-intensity agent work. The two would be orchestrated by a separate layer that routes tasks based on model size, latency requirements, and current load.

**Why not an ADR yet:** The routing/orchestration layer between laptop and cluster has not been designed. The question of whether this project (tpi-bro) grows to cover both, or whether a separate project handles multi-compute-target orchestration, is open. The ARM64 vs. x86 architectural split between the cluster and a laptop also needs to be thought through — it may affect image build pipelines, quantisation format choices, and model compatibility.

**What's clear:** The cluster does not need to be the only inference resource. The infrastructure should not assume it is.

---

## Multi-Agent Architecture Principles

**Idea:** As more agents are added (beyond the initial Agent A), there will need to be clear principles for how agents interact, share context, and divide work. Topics not yet thought through:

- **Agent-to-agent communication protocol** — direct HTTP calls, a shared message bus (NATS/Redis), or a coordination agent that acts as dispatcher?
- **Shared vs. per-agent memory** — what context is shared across agents (e.g., user profile, conversation history) vs. private to an agent instance?
- **RAM pooling for context windows** — on a single node with 32 GB, multiple agents sharing one Ollama instance can pool RAM for a larger effective context window (via multiple concurrent sessions), but contiguous memory for a single model load is still node-bound
- **Failure isolation** — if one agent crashes, others should continue; what are the contracts between agents?
- **Orchestrator vs. peer topology** — does one agent coordinate others (hierarchical) or do agents communicate as peers?

**Why not an ADR yet:** The agent architecture belongs primarily in the `sibling-app` project. tpi-bro provides the platform; `sibling-app` defines how agents use it. These questions should be revisited once the first 2–3 agents are running and actual patterns emerge.

---

## RAG and Embeddings Infrastructure

**Idea:** RAG (Retrieval-Augmented Generation) pipelines require an embeddings model and a vector database. Infrastructure questions not yet resolved:

- **Vector DB choice** — pgvector (PostgreSQL extension, familiar ops), Qdrant (purpose-built, Rust, low memory), Weaviate (feature-rich, heavier), Milvus (scalable, complex). On a memory-constrained cluster, the lightweight options (pgvector or Qdrant) are likely correct.
- **Embeddings model hosting** — a separate Ollama model (e.g., `nomic-embed-text`), or a dedicated embeddings service? Sharing the Ollama instance with inference models may cause contention.
- **Index storage** — persistent volume on the SSD; sizing depends on corpus. The `nfs-rwx` StorageClass (Phase B) may be needed if multiple pods need to read the same index.
- **Re-indexing pipeline** — when source documents change, how is the index updated? Batch job (scheduled) or streaming (on write)?

**Why not an ADR yet:** The specific RAG use cases for `sibling-app` are not yet defined in enough detail to make these decisions well. Premature choices here are likely to be wrong.

---

## Model Management at Scale

**Idea:** As the number of models in use grows, managing which models are pulled to which nodes, when to evict vs. keep in memory, and how to handle model updates becomes non-trivial.

- Ollama's model store is per-node by default — no shared model registry
- If two nodes both need the same 7B model, it is pulled and stored twice
- Model warm-up time (loading from disk into RAM) is 10–30 seconds; keeping frequently-used models hot requires explicit management

No action needed yet — with 1–2 models this is not a problem. Worth revisiting when more than 3–4 distinct models are in regular use.

---

## Observability and Monitoring

**Idea:** Proper observability (metrics, logs, traces) is deferred to keep the platform lean (ADR-0016). When it is added, considerations:

- **kube-prometheus-stack** is the standard but heavy (~1–2 GB). Consider lighter alternatives: VictoriaMetrics (~200 MB), or bare Prometheus + Grafana without the full operator stack.
- **Log aggregation** — Loki (lightweight) over Elasticsearch (very heavy) if centralised logs are needed
- **Tracing** — OpenTelemetry SDK in agent code; Jaeger or Tempo as backend when needed; no sidecar
- **NPU utilisation metrics** — the RK3588's 6 TOPS NPU is not yet used; monitoring NPU utilisation will require custom exporters once NPU inference is attempted

---

## NPU Utilisation

**Idea:** Each RK1 module has a 6 TOPS NPU (Neural Processing Unit). This is not yet used — Ollama runs on CPU/GPU (Mali G610, which is display-only for our purposes, so effectively CPU-only). If a future Ollama version or alternative runtime (e.g., `rknn-toolkit2`) supports the RK3588 NPU for inference, this could significantly improve throughput or reduce power consumption.

**Blocker:** NPU inference requires model conversion to RKNN format, which is not currently supported by standard open-weight model pipelines. Track upstream Ollama and llama.cpp for RK3588/RKNN support.
