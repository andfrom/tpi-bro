# ADR-0019: Storage Architecture — Local SSD, DB-as-Service, No Shared Filesystems

**Status:** Accepted  
**Date:** 2026-05-11

## Context

The cluster has 4× RK1 nodes. Each node has an NVMe SSD slot (to be mounted in B-09). The `sibling-app` application has 7 agents: 4 need read/write access to a item database; 3 are stateless (no persistent storage beyond model inference).

Three storage topologies were considered:

1. **Shared NFS volume** — NFS server on one node; all agents mount the same volume for the DB files.
2. **DB-as-Service** — a single DB pod (e.g., PostgreSQL) pinned to one node's local SSD, exposed as a Kubernetes Service; agents connect over the LAN.
3. **Per-agent local DB** — each agent gets its own DB instance on its local SSD; agents stay fully self-contained.

## Decision

**DB-as-Service on node4, backed by local SSD. No shared filesystems.**

### Rules

- **No NFS for database files.** PostgreSQL (and similar RDBMSs) require local-disk fsync semantics. NFS can silently corrupt a database on network disruption or unexpected unmount.
- **Single DB pod, pinned to node4** (`nodeSelector: kubernetes.io/hostname: rk1-node4`). node4 is already designated for RAG / vector DB / supporting infra.
- **DB exposed as a K8s Service** (`ClusterIP`). The 4 agents that need it connect via `postgresql.sibling-app.svc.cluster.local`. LAN latency for a pod-to-Service query is ~0.1–0.3 ms — acceptable for batch item queries.
- **Stateless agents float freely.** The 3 agents with no DB dependency are scheduled by the default K8s scheduler, following model placement (see ADR-0003).
- **DB-dependent agents colocate or accept the network hop.** For sibling-app, query latency over the LAN is not a bottleneck; the DB is not in the hot inference path.

### Registry storage

The container registry PVC (currently backed by eMMC rootfs via local-path) must be relocated to node1's local SSD in B-09. The registry is a write-seldom, read-often workload — local SSD is the right tier.

### Model weights

Ollama model weights are stored on each node's local SSD. Pods are scheduled to the node where weights are already present (node affinity / nodeSelector). This eliminates cross-node model transfer on pod startup.

## Consequences

**Positive:**
- DB files on local SSD: safe fsync, predictable IOPS, no NFS dependency
- Single DB pod: easy to backup, no replication complexity at this scale
- Service abstraction: agents are location-independent; DB can move nodes by changing nodeSelector + PVC, no agent code changes
- No shared filesystem: eliminates NFS as a single point of failure

**Negative:**
- DB node (node4) is a single point of failure for all 4 DB-dependent agents; if node4 goes down, those agents stop
- Adding a replica (read replica or standby) is future work — not needed at this scale
- Agents on nodes 1–3 incur ~0.1–0.3 ms LAN latency per DB query; acceptable now, revisit if query rate grows significantly

## Notes

- NFS or a distributed filesystem (Longhorn, Ceph) may be reconsidered if multi-node DB replication becomes necessary. At 4 nodes and single-user workloads, the added complexity is not justified.
- If the item dataset grows beyond node4's SSD capacity, the first lever is a larger SSD, not a distributed filesystem.
- Registry replication across nodes is explicitly **not** needed. containerd caches image layers on each node after first pull; subsequent pod restarts are local-cache hits. A single registry on node1 is sufficient.
