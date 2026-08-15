# ADR-0019: Storage Architecture — Local SSD, Dynamic Placement, No Shared Filesystems

**Status:** Accepted (revised 2026-05-11 — removed static node pin; platform-first framing)  
**Date:** 2026-05-11

## Context

The cluster has 4× RK1 nodes. Three nodes (1–3) have a 2TB NVMe SSD; node4 has
only eMMC. The platform's job is to expose resources and get out of the way — it
should not dictate which application lands on which node. Applications should be
able to express their storage requirements as capabilities (`I need NVMe`) rather
than as specific hostnames (`I need rk1-node4`).

Three storage topologies were considered:

1. **Shared NFS volume** — one node serves NFS; all pods mount the same volume.
2. **Local SSD with dynamic scheduling** — each node's SSD is a local volume. k3s schedules pods freely to any node that has storage, via `WaitForFirstConsumer` binding.
3. **Per-node per-app silos** — every application gets its own DB instance pinned to a specific node. No sharing, no flexibility.

## Decision

**Local SSD with dynamic placement. No hardcoded node assignments. No shared
filesystems.**

### Rules

**No NFS or distributed filesystem for database files.** PostgreSQL and similar
systems require local-disk fsync semantics. NFS can silently corrupt a database
on network disruption. The added complexity of Longhorn/Ceph is not justified at
this scale.

**Storage is a capability, not an address.** Applications request storage via
`storageClassName: local-ssd`. k3s schedules the pod to any node that has an SSD
mounted, and the provisioner creates the PV there. No application manifest should
reference a specific node hostname for storage reasons.

**Node labels express capability.** `mount-ssd.sh` labels each node with
`storage.tpi-bro/nvme=true` when it successfully mounts the SSD. Applications
that need SSD storage express this as a `nodeAffinity` on that label — not a
hostname pin. This means the platform can gain or lose SSD-capable nodes without
changing application manifests.

**Hardcoded hostname pins are only justified by hardware constraints**, not by
storage policy. Current exceptions:
- Registry: pinned to `rk1-node1` because of HostPort 5000 (a networking
  constraint, not a storage one). Permanent in practice: MetalLB was evaluated and dropped 2026-08-15 (see backlog C-01 note).
- Ollama: pinned to the node where model weights are downloaded (avoids
  re-downloading 10–30 GB on reschedule). This is an Ollama concern, not a
  platform policy.

**`WaitForFirstConsumer` binding mode.** PVCs are not bound at creation time; the
provisioner waits until a pod is scheduled. This gives k3s full scheduling
freedom: it places the pod based on resource availability across nodes 1–3, then
the PV is created there. If a node is busy or unavailable, k3s routes the pod to
the next best option automatically.

**Node4 has no NVMe.** It is excluded from the `local-ssd` provisioner's
ConfigMap. Workloads that claim `local-ssd` storage will never land there. Node4
is available for workloads that need no persistent storage or that use eMMC
(acceptable for small config data, not for DB files or model weights).

### Registry storage

The registry PVC uses `local-ssd` on node1. It is the one legitimate hostname-
pinned case because the HostPort is also on node1 — and since the PVC's data
lives on node1's NVMe regardless, a LoadBalancer VIP wouldn't unpin it;
MetalLB was evaluated and dropped 2026-08-15.

### Model weights (Ollama)

Ollama weights are on each node's local SSD. The Ollama Deployment uses a
`nodeAffinity` on `storage.tpi-bro/nvme=true` to restrict scheduling to SSD
nodes. Individual Ollama instances may still get hostname-level affinity to avoid
re-downloading weights, but that is an application concern managed in the Ollama
chart — not a platform policy.

### Database pods

DB pods (PostgreSQL, vector DB) claim `local-ssd` storage and are scheduled
dynamically by k3s to whichever SSD node has capacity. No nodeSelector is set in
the platform. If a DB pod is rescheduled to a different node, it gets fresh
storage there (the old data stays on the original node's SSD until the PV is
reclaimed — `Delete` policy cleans it up). This is acceptable for a dev cluster;
production would add a replica or backup before allowing rescheduling.

## Consequences

**Positive:**
- Applications express requirements (`local-ssd`), not locations — easier to
  manage, simpler manifests, no breakage when nodes change
- k3s bin-packs workloads freely across nodes 1–3 based on actual resource usage
- Adding node4's SSD later requires only plugging in the hardware and running
  `mount-ssd.sh` — no manifest changes needed
- The `storage.tpi-bro/nvme` label makes SSD capability discoverable and
  addressable without inspecting individual node specs

**Negative:**
- Local storage is inherently single-node — if that node goes down, the PV is
  unavailable. Acceptable for a 4-node dev cluster; revisit with Longhorn if HA
  becomes a requirement.
- Rescheduling a stateful pod to a different node gives it empty storage.
  Applications must handle this (re-seed, restore from backup, or accept loss).
  For the registry this is fine (re-push). For a DB this requires operational care.

## Notes

- NFS or a distributed filesystem may be reconsidered if multi-node HA becomes
  necessary. At 4 nodes and single-user workloads, the added complexity is not
  justified.
- The `local-ssd` StorageClass uses `reclaimPolicy: Delete` — PVs are cleaned up
  when PVCs are deleted. Use `Retain` for data that must survive PVC deletion.
- If node4 gets an NVMe later, run `mount-ssd.sh` — it auto-detects, formats,
  mounts, labels the node, and adds it to the ConfigMap. No other changes needed.
