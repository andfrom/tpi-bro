# ADR-0025: Clean-Room Container Principle — Exploration Artifacts Are Ephemeral

**Status:** Accepted  
**Date:** 2026-06-17

---

## Context

Working on the cluster involves two modes:

1. **Exploration / debugging** — running ad-hoc scripts, diagnostic tools, or
   iterative experiments directly on node hosts. This work is necessary and
   legitimate. It leaves artifacts: scripts in `/home/ubuntu/`, model files in
   `/tmp/`, config edits, pip installs in system Python, scratch data files.

2. **Production workloads** — containerized, declarative, managed by k3s
   (ADR-0024). These must be reproducible from a clean state.

The risk is that exploration residue gradually shapes the cluster environment in
ways that are invisible to version control, untraceable, and non-reproducible.
A workload that accidentally depends on a library installed by hand during
debugging, or a config file left by a previous experiment, will silently break
when the node is re-flashed or another cluster member tries to reproduce the setup.

## Decision

**Container environments are clean-room by definition.** Each container starts
from a known image with no exploration residue. This is the enforcing mechanism
for ADR-0024.

Operationally:

- **Exploration is ephemeral.** Files written to node hosts during debugging
  (scripts in `~`, data in `/tmp`, ad-hoc `pip install`, test configs) are
  considered temporary. They will be lost on node re-flash and that is expected.
- **No production dependency on host-side residue.** A containerized workload
  must not rely on files or packages that exist only because a prior exploration
  session left them on the host.
- **Scratch artifacts in repos go in `scratch/`.** Any artifact generated during
  exploration that is worth keeping must be committed to a repo's `scratch/`
  directory (or equivalent). Files on cluster nodes are not a substitute for
  version control.
- **Conversion and build pipelines are not exceptions.** Scripts run on cluster
  nodes to convert models (e.g., RKNN conversion, ONNX export) leave similar
  residue. These pipelines must be containerized (see tagx ADR-0004, tpi-bro
  ADR-0024 backlog item: build container).

## Consequences

- Cluster nodes may accumulate exploration residue; this is tolerated but not
  managed. Node re-flash restores clean state.
- When a previously-working ad-hoc script breaks, the correct fix is to
  containerize it — not to re-install the dependency by hand.
- Documented exploration findings (ADRs, backlog items, pipeline scripts) are
  the durable output of exploration work, not the files left on nodes.
- New exploration sessions should assume the node may not have state from a
  previous session unless it was containerized and committed.
