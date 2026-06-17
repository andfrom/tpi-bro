# ADR-0024: All Cluster Workloads Run as Containers from the Local Registry

**Status:** Accepted  
**Date:** 2026-06-17

---

## Context

The TuringPi cluster runs k3s. Any workload deployed on the cluster — AI agents,
inference pipelines, data processing jobs, one-off batch tasks — must be managed
by k3s or at minimum by Docker. Running scripts directly on node hosts creates
untracked state, bypasses k3s scheduling, and makes workloads invisible to the
cluster's resource management.

The cluster has a local Docker registry deployed and verified (ADR-0004, ADR-0021).
All images built by the tagx project target ARM64 and are designed to be pushed
to this registry.

## Decision

**All applications running on the cluster must run as containers.** Containers
must be pulled from the cluster-local Docker registry (ADR-0004).

This applies to:

- AI agent processes (LLM inference, pipeline workers)
- Model serving (Ollama, RKNN inference containers)
- Data processing pipelines
- Scheduled or one-off batch jobs (conversion, preprocessing, indexing)
- Any background daemon that is not a cluster infrastructure component
- **Image build jobs:** if images need to be built on-cluster, the build process
  itself must run inside a designated build container (Kaniko, Buildah, or
  equivalent). Running `docker build` directly on a node host is prohibited by
  the same principle. The specific build-container mechanism is not yet decided —
  tracked as a backlog item.

The following are explicitly **excluded** (bootstrap/infra only):

- The `tpi` BMC CLI tool (pre-cluster, flash tool)
- k3s node agent and containerd (cluster infrastructure)
- The Docker registry itself (bootstrap requirement, ADR-0004)
- OS-level services (sshd, cron)

## Consequences

- No workload runs as a raw Python script, binary, or systemd service on a node.
- Kubernetes `Job` or `CronJob` are the deployment unit for batch tasks.
- The tagx image pipeline is the source of all workload container images.
- Workloads not yet containerized are tracked as backlog items, not acceptable
  permanent state.
- Exploration and debugging sessions that run scripts directly on nodes are
  acceptable temporarily but are subject to ADR-0025 (clean-room principle).
