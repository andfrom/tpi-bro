# ADR-0018: Local Inference Over Cloud APIs

**Status:** Accepted  
**Date:** 2026-05-10

## Context

AI agent workloads require an LLM inference backend. The two broad options are:
- **Cloud APIs** (OpenAI, Anthropic, Google, etc.): managed, scalable, no hardware overhead, pay-per-token
- **Local inference** (Ollama on owned hardware): self-managed, fixed capacity, no per-token cost, full data control

The cluster (4× RK1, 128 GB total RAM) has sufficient capacity to run models in the 7B–13B range at quantised precision across multiple agents simultaneously.

## Decision

**All AI inference runs locally on the cluster. No user data or prompt content is sent to external cloud APIs as part of normal operation.**

This is a foundational architectural decision. Every infrastructure and software choice in this project is made under the assumption that inference is local.

## Rationale

**Privacy and data locality.** User data, input documents, subject profiles, and agent reasoning traces never leave the local network. This is non-negotiable for the use cases this project targets. Cloud API calls create an implicit data-sharing agreement with the API provider.

**Cost model.** Local inference has zero marginal cost per token. Cloud APIs charge per token — at the scale of multi-agent workflows (many calls per session, running continuously) this becomes significant. The hardware cost is a fixed, one-time investment.

**Offline and autonomous operation.** The cluster operates independently of internet availability. Agents can run overnight jobs, batch processing, and scheduled tasks without depending on external service uptime or rate limits.

**Model freedom.** Local inference allows running any open-weight model: fine-tuned variants, domain-specific models, different quantisation levels, experimental checkpoints. Cloud APIs offer only what the provider exposes. Local inference removes that ceiling.

**Latency control.** On-cluster inference has predictable latency and no external network round-trip. For interactive agents this matters.

## Trade-offs accepted

- **Peak throughput ceiling.** The cluster has fixed compute. Cloud APIs scale elastically. For tasks that need bursts beyond cluster capacity, local inference is the bottleneck — accepted.
- **Hardware management.** The cluster requires maintenance (OS updates, node failures, storage). Accepted as the cost of control.
- **Model quality ceiling.** Frontier models (GPT-4, Claude Opus, Gemini Ultra) are not locally available. The project operates within the capability envelope of open-weight models. Accepted, with the expectation that open-weight quality continues to improve.
- **Operational complexity.** Running Ollama, managing model pulls, and tuning quantisation requires more effort than an API key. Accepted.

## What this does not preclude

- Using cloud APIs in development or evaluation contexts (comparing local vs. cloud output quality)
- A future hybrid architecture where some tasks route to cloud and others stay local (see FUTURE_IDEAS.md)
- Using cloud services for non-inference work (CI/CD, external DNS, Tailscale coordination)

## Relationship to other ADRs

- ADR-0016 (lean platform): local inference is why every GB of platform overhead matters — it is directly subtracted from model memory budget
- ADR-0008 (resource allocation priority): Ollama pods get `interactive` PriorityClass; they are the primary workload the cluster exists to serve
