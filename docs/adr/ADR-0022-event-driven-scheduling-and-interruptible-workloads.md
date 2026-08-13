# ADR-0022: Event-Driven On-Demand Scheduling and Interruptible Background Workloads

**Status:** Accepted
**Date:** 2026-06-15

## Context

ADR-0008 established two PriorityClasses (`interactive` = 1000, `background` = 100)
and noted that Kubernetes will preempt lower-priority pods under resource pressure.
Two gaps remain:

1. **Scale-from-zero**: on-demand workloads (STT transcription, one-shot inference)
   should spin up only when a device requests them and scale back to zero when idle.
   Keeping idle pods running wastes node resources and accelerator slots.

2. **Interruptibility**: Kubernetes preemption evicts lower-priority *pending* pods
   automatically, but does not interrupt *running* background pods unless the node
   is resource-constrained. On 32 GB nodes, CPU/RAM pressure rarely occurs. Longer-
   running background jobs (e.g. a 90-minute STT transcription, a nightly scan)
   would block a device's on-demand request for their entire duration without an
   explicit interruption mechanism.

## Decision

### Node capability labels

The TuringPi 2 board accepts heterogeneous compute modules — RK1, CM4, and Jetson
Orin Nano can coexist in the same chassis. Each module type has different
acceleration hardware. Workloads must express hardware requirements via node labels;
the scheduler and the eviction logic both use these labels as the source of truth.

**Capability label convention:** `tpi-bro/<capability>: <value>`

| Label | Value | Module | Notes |
|-------|-------|--------|-------|
| `tpi-bro/npu` | `rk3588` | RK1 | RKNN NPU, 6 TOPS; use `rknn-toolkit2` models |
| `tpi-bro/npu` | `jetson-orin-nano` | Jetson Orin Nano | CUDA/DLA; different runtime from RKNN |
| `tpi-bro/npu` | *(absent)* | CM4 | No NPU |
| `storage.tpi-bro/nvme` | `true` | RK1 (nodes 1–3) | NVMe SSD mounted at `/mnt/ssd` (ADR-0019) |

Bootstrap scripts detect and apply capability labels at node setup time, same
pattern as `storage.tpi-bro/nvme=true` in `mount-ssd.sh`. A node that gains or
loses a capability (e.g. a slot swap from RK1 to CM4) must have its labels updated
by re-running the relevant setup script.

Workloads that require a specific accelerator express this as `nodeAffinity`:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: tpi-bro/npu
              operator: In
              values: [rk3588]
```

A CUDA workload would require `jetson-orin-nano`; a CPU-only workload omits the
NPU affinity entirely and is free to land on any node.

### Event-driven scale-from-zero via KEDA + Redis

**KEDA** (Kubernetes Event-Driven Autoscaling) watches an event source and scales
a Job from 0 to N replicas when work arrives, back to 0 when the queue is empty.

**Redis** serves as the job queue. Devices publish job requests to a Redis list;
KEDA watches queue depth via a `ScaledJob`; pods spin up to consume the queue and
exit when done.

```
device  →  Redis queue  →  KEDA ScaledJob  →  pod (interactive PriorityClass)
                                                   ↓ done
                                               pod exits; KEDA scales to 0
```

Each workload type gets its own Redis key and KEDA ScaledJob. On-demand pods
use the `interactive` PriorityClass (ADR-0008) and declare their capability
requirements via `nodeAffinity` as above.

### Scheduling decision flow

When KEDA scales up an interactive job, the following decision sequence applies
before any eviction is considered:

```
1. Is there a node with the required capability labels AND sufficient free
   capacity to schedule the pod immediately?
        YES → schedule directly. Done. No eviction needed.
        NO  ↓

2. Is there a node with the required capability labels that is currently
   running one or more pods labelled tpi-bro/interruptible: "true"?
        YES → evict interruptible pod(s) on that node; schedule interactive job.
        NO  → queue the job; retry when capacity becomes available.
```

Eviction is the last resort. A capable node with headroom always wins. Nodes
without the required capability labels are never considered at either step —
evicting a workload on a CM4 node to run an RKNN job gains nothing.

### Interruptibility contract

Background workloads that are long-running and safe to interrupt carry the label:

```yaml
metadata:
  labels:
    tpi-bro/interruptible: "true"
```

This label is a **platform contract**. It declares:

1. The workload handles `SIGTERM` gracefully — it checkpoints its state before
   exiting and can resume from that checkpoint on restart.
2. The platform is permitted to evict this pod when step 2 of the scheduling
   flow applies. The eviction is deliberate, not a failure.
3. `terminationGracePeriodSeconds` is set generously (minimum 60s, typically
   300s) to allow checkpointing before `SIGKILL`.

Checkpoint implementation is the **application's responsibility**. The platform
guarantees SIGTERM delivery and the grace period. What constitutes a valid
checkpoint (e.g. last processed audio segment timestamp, last processed item ID) is
defined per workload and must be documented alongside the label declaration.

The label does **not** mean the workload will always be interrupted — only that
it *may* be. On a cluster with free capacity on a capable node, interruptible
background jobs run to completion undisturbed.

**What is NOT interruptible:**
- Jobs with expected runtime < 60s: overhead exceeds the benefit.
- Jobs without checkpoint support: if state cannot be saved safely, do not apply
  the label — the job will block until complete.
- Jobs on nodes that lack the capability the interactive job requires: evicting
  them frees nothing useful and the scheduling flow will not target them.

### Eviction mechanism

An init container on the interactive KEDA job implements step 2 of the scheduling
flow. It runs only when the main pod is pending (i.e. the scheduler could not
place it despite matching node affinity):

1. Query nodes matching the job's `nodeAffinity` capability labels
2. Find running pods on those nodes labelled `tpi-bro/interruptible: "true"`
3. Issue graceful deletes: `kubectl delete pod --grace-period=<seconds>`

This requires a ServiceAccount with `pods/get`, `pods/list`, and `pods/delete`
permissions, scoped tightly to the relevant namespaces.

## Relationship to ADR-0008

ADR-0008 defines PriorityClass values and resource request/limit conventions.
This ADR adds the dynamic layer: KEDA for demand-driven pod lifecycle, node
capability labels as the hardware capability vocabulary, and the
`tpi-bro/interruptible` label as explicit eviction consent. All three must be
applied together for the full scheduling model to work.

## Consequences

**Positive:**
- On-demand workloads spin up in seconds and consume no resources when idle
- Eviction only occurs on nodes that can actually run the interactive job —
  capability-first matching prevents pointless evictions
- The scheduling model is hardware-agnostic: adding a Jetson or CM4 slot requires
  only updating the node's capability labels; no scheduler or KEDA changes needed
- The interruptibility contract is opt-in; workloads that cannot checkpoint are
  never evicted
- KEDA + Redis is lightweight and runs on k3s without scheduler changes

**Negative:**
- Workloads declaring `tpi-bro/interruptible: "true"` must implement SIGTERM
  handling and checkpointing — non-trivial application-level work
- Cold-start latency of 10–30s per pod scaled from zero (mitigated by local
  registry and NVMe model cache)
- The init-container eviction hook requires pod-delete permissions — scope must
  be reviewed whenever namespaces are added
- Node capability labels must be kept accurate as modules are swapped; stale
  labels cause the scheduler to make wrong placement decisions silently
