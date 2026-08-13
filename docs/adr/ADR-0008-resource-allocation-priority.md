# ADR-0008: Priority-Based Resource Allocation for Multi-Agent Workloads

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The cluster runs multiple agents concurrently — some handling the user's current active task, others running background work (batch scoring, re-indexing, model pre-warming, etc.). All share the same finite CPU and RAM per node.

Two failure modes to avoid:
1. **Starvation** — a background job monopolizes a node, freezing interactive agents.
2. **Over-restriction** — background jobs are killed or never scheduled, wasting idle capacity.

The desired behaviour: the current "focus" workload gets a larger compute slice and low latency; background tasks share the remaining capacity and make progress, but yield under pressure.

## Decision

Use Kubernetes priority and resource management primitives:

### PriorityClass

Define at least two PriorityClasses:

| Class | Value | Who uses it |
|-------|-------|-------------|
| `interactive` | 1000 | Agents handling live user requests (e.g., scoring an ad the user just opened) |
| `background`  | 100  | Batch jobs, re-scoring queues, pre-warming, observability scrapers |

A pod with `interactive` priority preempts a `background` pod if the node is under memory pressure. The `background` pod is evicted (and rescheduled when capacity is available), not deleted.

### ResourceRequests and Limits

Every agent Deployment sets both `requests` and `limits`:

- **`requests`**: the scheduler uses this to bin-pack pods onto nodes. Set conservatively (what the pod actually needs at idle).
- **`limits`**: the hard cap. CPU limits throttle (no eviction); memory limits trigger OOM kill.

Ollama (the LLM runtime) is the dominant consumer. Its pod gets a generous memory request matching the model size, and no CPU limit (it should use all available cores during inference).

Agent wrapper pods (FastAPI processes) are typically 200–500 MB RAM, 0.5–1 CPU. They should have both requests and limits set.

### Namespace ResourceQuota (optional, Phase D+)

If multi-tenancy is added later, each user/application gets a Namespace with a ResourceQuota capping their total CPU and memory. This enforces the per-user allocation ceiling independent of PriorityClass.

### LimitRange

A LimitRange in each namespace sets default requests/limits for pods that don't specify them, preventing unconstrained pods from starving neighbours.

## Example: sibling-app with 7 agents

Assume all 7 agents use one Ollama instance on `rk1-node1` running a 7B model (~4–6 GB at 4-bit):

```
rk1-node1 (32 GB RAM):
  ollama          requests=8Gi   limits=12Gi   priority=interactive
  agent-a       requests=256Mi limits=512Mi  priority=interactive
  agent-2         requests=256Mi limits=512Mi  priority=background
  agent-3..7      requests=256Mi limits=512Mi  priority=background
  system overhead ~2–3 GB
  ─────────────────────────────
  total requests  ~11 GB  ✓ fits
```

Under load, the scheduler gives CPU time first to `interactive` pods. `background` pods get whatever remains. No pod is starved to zero — Kubernetes guarantees each pod its requested CPU share.

## Consequences

**Positive:**
- Interactive agents stay responsive even when background work is running
- Background jobs make steady progress on idle capacity — no wasted compute
- Preemption is automatic — no manual intervention needed when load spikes
- Standard K8s primitives — no custom scheduler needed

**Negative:**
- PriorityClass, ResourceQuota, and LimitRange must be applied per-namespace — some setup overhead
- Getting request/limit values right requires profiling each agent under load
- Memory limits that are too tight cause OOM kills — initial values should be generous, then tuned down

## What "current focus" means operationally

"Current focus" is expressed by labeling a Deployment (or its pods) with `priority: interactive`. A simple approach: the API gateway routes active-session requests to pods that have been annotated as interactive. Background batch jobs use a separate Deployment with `priority: background`. The operator (or a future orchestration layer) promotes/demotes jobs by patching the PriorityClass annotation.
