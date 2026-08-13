# ADR-0017: No Service Mesh

**Status:** Accepted  
**Date:** 2026-05-10

## Context

Service meshes (Istio, Linkerd) provide mTLS between pods, advanced traffic management (retries, circuit breakers, canary), and distributed tracing. They work by injecting a sidecar proxy (Envoy or the Linkerd proxy) into every pod.

On this cluster:
- Each pod gains a sidecar consuming approximately 100–200 MB RAM and measurable CPU even at idle
- 10 pods × 150 MB sidecar = 1.5 GB of RAM consumed by proxies doing nothing
- A single node running one Ollama process and several agents could have 5–10 pods; sidecar overhead would consume 750 MB–2 GB of the node's memory budget

The AI inference workloads are memory-bound (see ADR-0016). Any RAM given to a sidecar proxy is RAM unavailable to the model.

## Decision

**No service mesh. Not now, not as a "we'll add it later."**

mTLS and advanced traffic management are valuable in large multi-team production clusters where the overhead is negligible relative to total cluster size. On a 4-node personal AI cluster where every GB matters, the overhead is not acceptable.

The features a service mesh provides are addressed by other means:

| Service mesh feature | Alternative |
|---|---|
| mTLS between pods | Kubernetes NetworkPolicy (restricts traffic at L3/L4 without sidecars); TLS at the application layer if end-to-end encryption is required |
| Retries / circuit breakers | Implemented in application code or via Traefik middleware rules on the ingress path |
| Distributed tracing | OpenTelemetry SDK in agent code, direct export to a collector — no sidecar needed |
| Canary / traffic splitting | Traefik weighted routing or Argo Rollouts (single controller, no per-pod sidecar) |
| Observability (golden signals) | `/healthz` and `/ready` endpoints; kube-state-metrics when needed |

## Consequences

**Positive:**
- No sidecar RAM overhead — all pod memory is available to the application process
- Simpler debugging: no proxy in the request path, no sidecar logs to correlate
- Faster pod startup: no sidecar injection, no proxy bootstrap

**Negative:**
- No automatic mTLS between pods — relies on Kubernetes RBAC + NetworkPolicy for pod-to-pod security
- Retry / circuit-breaker logic must be implemented in application code rather than delegated to infrastructure
- If the cluster ever scales to multi-team or multi-tenant use, revisit this decision — at sufficient scale the governance benefits of a service mesh may outweigh the overhead

## Relationship to other ADRs

- ADR-0016 (lean platform): this is a direct application of that principle to the networking layer
