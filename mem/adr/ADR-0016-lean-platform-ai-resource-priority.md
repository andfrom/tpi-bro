# ADR-0016: Platform Infrastructure Must Not Compete with AI Workloads for Resources

**Status:** Accepted  
**Date:** 2026-05-10

## Context

The cluster has 128 GB of RAM spread across 4 nodes (32 GB each). The primary purpose of the cluster is to run AI workloads — LLM inference (Ollama), embedding models, RAG pipelines, and multi-agent orchestration. These workloads are memory-bound: a 7B model at 4-bit quantization consumes ~4–6 GB; a 13B model ~8–10 GB; multiple models or agents running simultaneously can easily consume 20–30 GB on a single node.

Infrastructure components (orchestrator, CNI, GitOps controller, observability stack, service mesh, message bus, ingress controller) all consume RAM and CPU. On a workstation or cloud node with hundreds of GB of RAM this is negligible. On a 32 GB node running LLMs it is a direct trade-off: every GB consumed by platform machinery is a GB the model cannot use.

## Decision

**Platform components are chosen and configured for minimum resource footprint. AI workloads are the reason the cluster exists; the platform exists only to the extent it enables those workloads efficiently.**

This is not a principle about under-investing in infrastructure. It is a principle about *which properties matter most* when evaluating frameworks:

| Property evaluated | Weight |
|---|---|
| RAM + CPU overhead at idle | **Primary** |
| Correctness and reliability | **Primary** |
| Operational simplicity | High |
| Feature richness | Secondary — only if the feature is actually needed |
| Industry adoption / ecosystem | Tertiary |

A framework is not chosen because it is the industry standard or because it has the most features. It is chosen because it does its job well while consuming the least possible platform RAM and CPU.

### Applied selection criteria

**For every platform component, ask in order:**

1. Is this component needed at all right now? If not, do not install it.
2. If needed, is there a version or distribution that provides the required function with less overhead?
3. If multiple candidates are equivalent in correctness and simplicity, choose the one with the smaller idle footprint.
4. After choosing, disable any sub-features not yet needed.

### Current decisions that follow this principle

| Component | Chosen | Heavier alternative not chosen | Reason |
|---|---|---|---|
| Orchestrator | k3s (single binary, SQLite, ~512 MB overhead) | kubeadm + etcd (~2+ GB overhead) | ADR-0002 |
| CNI | Flannel (lightweight) | Cilium (eBPF, more capable, higher overhead) | Cilium noted as future option only |
| Service mesh | None | Istio / Linkerd (sidecars: ~100–200 MB per pod) | ADR-0017 |
| Observability | `/healthz` + `/ready` only | kube-prometheus-stack (~1–2 GB) | Deferred: "later; for hello just rely on /healthz" |
| GitOps controller | Argo CD (one controller) or Flux | Full Argo stack (Argo CD + Workflows + Events + Rollouts) | Install only what is needed |
| Ingress | Traefik (k3s built-in, already present) | NGINX + cert-manager + external-dns | Reuse what k3s provides |
| Message bus | None until needed; then Redis or NATS (small footprint) | Kafka / RabbitMQ | Only when actually required |
| Agent runtime | Uvicorn + FastAPI (lightweight) | Django / Spring / Express with full ORMs | Not needed |

### Configuration discipline

Installing a component does not mean enabling all its features. Components are installed in their minimal configuration with all optional sub-systems disabled. Enabling a sub-system requires justification that it provides value that outweighs its overhead.

Examples:
- k3s: `--disable traefik` only if replacing it — otherwise keep the built-in (it's already there)
- Argo CD: install the core controller; do not install Argo Workflows, Argo Events, or Argo Rollouts unless a specific use case requires them
- kube-prometheus-stack: not installed by default; add when there is a specific alerting or dashboarding need

### Yield under pressure

Beyond initial selection, components should be configured to **yield resources under memory pressure** rather than hold them:

- Set `requests` conservatively (what the component actually needs at idle)
- Set `limits` to cap runaway usage
- Assign infrastructure components `PriorityClass: background` (see ADR-0008); AI inference pods get `interactive` priority and preempt infrastructure under pressure

## Consequences

**Positive:**
- Maximum RAM available to LLM inference and agent processes on every node
- Simpler platform: fewer components = fewer failure modes and less cognitive overhead
- Each component that is added must justify its footprint — this keeps the platform intentionally lean over time

**Negative:**
- Some features that heavier platforms provide out-of-the-box (distributed tracing, zero-trust mTLS, advanced traffic management) require deliberate addition and justification
- "We might need it later" is not sufficient justification to install something now — it must be needed now

## Relationship to other ADRs

- ADR-0002 (k3s): a direct application of this principle to the orchestrator choice
- ADR-0008 (resource allocation priority): the runtime enforcement of this principle — AI workloads preempt platform components under pressure
- ADR-0017 (no service mesh): a direct application of this principle to the networking layer
