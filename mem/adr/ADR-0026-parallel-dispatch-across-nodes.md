# ADR-0026: Parallel Dispatch of Independent Subtasks Across Nodes

**Status:** Accepted  
**Date:** 2026-06-17

## Context

The TuringPi cluster has multiple RK1 nodes with identical NPU capability. Many
pipeline workloads are structurally decomposable: encoder validation and decoder
benchmark are independent; testing two model sizes are independent; a PyTorch
reference trace and an RKNN hardware test exercise different runtimes and have no
data dependency between them.

When these are serialised on a single node, wall-clock time grows linearly with
the number of subtasks even though the cluster has idle NPU capacity on other
nodes. The capability-label machinery from ADR-0022 already provides the
vocabulary to express which nodes can run which workloads — parallel dispatch is
the natural extension.

## Decision

When a workload can be split into independent subtasks, dispatch each subtask to a
separate capable node simultaneously rather than serialising them on one node.

A subtask is independent if:

- It produces output the other subtasks do not need as input at dispatch time
- It does not write to shared mutable state (model files, databases) that other
  running subtasks read or write
- Failure of one subtask does not invalidate the results of others

The gain is proportional: two independent subtasks on two nodes finish in the
wall-clock time of the slower one, not the sum of both.

### Node preference for parallel dispatch

Node selection follows ADR-0022 capability labels. Among capable nodes, prefer:

1. A node with NVMe (`storage.tpi-bro/nvme=true`) for any subtask that reads or
   writes large model files — avoids slow network transfer of multi-GB weights.
2. Any other capable node for compute-only subtasks with small I/O.

Do not force every subtask onto node1 simply because it has NVMe — that
re-serialises the dispatch and negates the parallelism benefit.

### Current mechanism and roadmap

Current state: ad-hoc SSH + background processes. Sufficient for development
workflows. A cluster-level dispatch layer (backlog) will formalise this with job
queues, status tracking, and result aggregation.

Until the dispatch layer exists, workload owners are responsible for:

- Identifying which subtasks are independent
- Launching them in parallel manually (SSH background or `kubectl apply` of
  separate Jobs)
- Aggregating and comparing results after both complete

## Relationship to other ADRs

- **ADR-0022**: provides the capability labels and scheduling flow; this ADR adds
  the parallel-dispatch decision to that flow.
- **ADR-0027**: covers model affinity — which capable node to prefer when routing
  a job to avoid model reload overhead. Parallel dispatch and affinity are
  complementary: dispatch first decides *how many* nodes to use; affinity decides
  *which* node among the candidates.
- **ADR-0024 / ADR-0025**: the container and clean-room principles ensure each
  subtask is independently runnable without shared in-node state.

## Consequences

- Wall-clock time for independent multi-step workflows scales with the slowest
  subtask, not the sum — significant for long-running NPU inference or conversion
  jobs.
- Workload authors must explicitly identify and document independence before
  assuming parallel dispatch is safe.
- Output aggregation (comparing results across nodes after completion) is the
  caller's responsibility — no implicit synchronisation.
- The cluster-level dispatch layer, when built, must respect this ADR's
  independence definition before scheduling subtasks in parallel.
