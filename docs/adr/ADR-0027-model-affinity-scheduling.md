# ADR-0027: Model Affinity Scheduling — Prefer Warm Nodes

**Status:** Accepted  
**Date:** 2026-06-17

## Context

Model weights for large inference workloads (e.g. Whisper large-v3 RKNN: encoder
664 MB + decoder 1 066 MB) reside on NVMe and are loaded into DRAM at container
start time. Loading a large-v3 RKNN encoder takes ~25s on an RK1 node; the
decoder another ~2s. For short jobs — a 30-second audio clip where transcription
takes a similar duration — model load overhead is a significant fraction of total
job time.

When the cluster runs multiple nodes with the same NPU capability and a stream of
jobs arrives, naive round-robin or random placement causes each job to load model
weights from scratch, even when another node is already holding the same model in
DRAM (warm). The warm node incurs zero load overhead for the same job type.

This is distinct from the capability matching in ADR-0022, which ensures a job
lands on *a* capable node. Affinity is a *preference* within the set of already-
capable nodes: pick the warm one first.

## Decision

When dispatching a job to a capable node, extend the ADR-0022 scheduling decision
flow with a model-warmth preference step before any cold-start or eviction step:

```
1. Is there a warm capable node (correct NPU + matching model already loaded)
   with free capacity?
        YES → schedule there. No model load overhead.
        NO  ↓

2. Is there any cold capable node (correct NPU, model not loaded) with free
   capacity?
        YES → schedule there. Accept cold-start latency.
        NO  ↓

3. (Existing ADR-0022 steps: evict interruptible → queue)
```

"Model already loaded" is signalled by a pod label on the running model-serving
pod:

```yaml
metadata:
  labels:
    tpi-bro/model-loaded: "<model-id>"   # e.g. "whisper-large-v3-rknn"
```

The dispatcher queries pod labels on each capable node to determine warmth before
placement. A node is warm if it has at least one pod with the matching
`tpi-bro/model-loaded` label in a Running state.

### Batching implication

Affinity scheduling naturally groups same-model jobs onto the same node as long
as that node has capacity, and routes different-model jobs to nodes where no
model-swap is needed. This reduces total model-load time across a mixed queue
without requiring explicit batching logic — it emerges from always preferring the
warm node.

### Soft affinity

Model affinity is a *preference*, not a hard requirement. If no warm node is
available (all are occupied or lack the capability), the job falls through to a
cold capable node (step 2). A job is never held in queue solely because no warm
node exists.

### Model identity

`<model-id>` in the label value is a stable, human-readable string that
identifies both the model weights and the runtime:

- `whisper-large-v3-rknn`
- `whisper-medium-rknn`
- `kb-whisper-large-rknn`

This allows different fine-tunes of the same architecture (e.g. base large-v3 vs
KBLab Swedish fine-tune) to be treated as distinct models for affinity purposes.

## Relationship to other ADRs

- **ADR-0022**: provides the capability labels and the interruptible-eviction flow
  that this ADR extends.
- **ADR-0026**: parallel dispatch decides how many nodes to use for independent
  subtasks; this ADR decides which node to prefer among capable candidates.
- **ADR-0008**: priority classes remain unchanged; model affinity is a placement
  preference within a priority level, not a priority override.

## Consequences

- Reduced cold-start overhead for jobs that arrive at a node already serving the
  same model — especially significant for large models on slower NVMe connections.
- Model-serving pods must apply the `tpi-bro/model-loaded` label on startup and
  remove it (or allow it to disappear with the pod) on shutdown; this is
  a lightweight application contract.
- A dispatcher that does not honour this ADR will still produce correct results —
  it just misses the optimisation. The label is advisory.
- The warm-node advantage disappears for scale-from-zero pod patterns (ADR-0022
  KEDA jobs) where every job creates a fresh pod; affinity is most valuable for
  persistent model-serving pods that handle multiple requests per lifecycle.
