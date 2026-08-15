# ADR-0028 — The job queue is the sole boundary to external orchestration

**Date:** 2026-08-15
**Status:** Accepted

---

## Context

This cluster is not an end in itself. Its purpose is to serve as the
**execution tier** of a larger, distributed personal-automation system — one
that notices what its user is focused on and switches supporting work
accordingly. The "brain" of that system (signal detection, judgment about
what a focus shift means, deciding what work should happen next) lives
off-cluster, spread across a laptop and other compute, and is developed
independently of this repo. The cluster's job is narrower: run the work it
is handed, on the right node, at the right priority, preempting what no
longer matters — the muscle, not the brain.

Three distinct things have historically shared the word "orchestrator" here,
and this ADR separates them:

1. **Bring-up orchestration** — one command from a flashed board to a fully
   operational cluster (chaining the existing phase scripts with
   verification gates). A tpi-bro concern; mechanical.
2. **The cluster-side execution contract** — the event-driven scheduling
   machinery of ADR-0022 (typed job queue, KEDA ScaledJobs, interruptible
   workloads/eviction, capability + model-affinity routing per ADR-0027).
   A tpi-bro concern; this ADR is about its role as a *boundary*.
3. **The focus orchestrator itself** — external, off-cluster, out of scope
   for this repo entirely.

The design question: how do layers 2 and 3 talk to each other?

## Decision

**The typed job queue (ADR-0022's Redis queue) is the only interface between
this cluster and any external orchestrator or consumer. Nothing external
drives the Kubernetes API, and the cluster knows nothing about what sits
upstream.**

Concretely:

- An external system participates by **enqueuing typed jobs** (and reading
  results/status by whatever convention the job type defines). That is the
  entire integration surface.
- The cluster guarantees the execution semantics behind the queue:
  scale-from-zero per job type, capability-based placement
  (`tpi-bro/<capability>` labels, ADR-0022/E-02), model-affinity warm
  routing (ADR-0027), priority and eviction of interruptible work (E-03),
  containerized workloads only (ADR-0024).
- **The queue is the system boundary, not a cluster-internal detail.** The
  same queue may be consumed by workers *outside* the cluster — a laptop
  process picking up job types the cluster shouldn't run (too heavy, needs
  local context, needs a far larger model). Job types that exceed this
  cluster's realistic envelope (small/structured/latency-tolerant tasks;
  ~3B-class LLM work, not large-model reasoning) simply have their
  consumers elsewhere. The cluster neither knows nor cares.

## Rationale

- **Decoupling is the property that makes the flow work at all.** Any
  richer coupling (external systems shaping Deployments, shared config,
  direct k8s access) means coordination and versioning that compounds with
  every added consumer — both sides end up less than they could be.
- **It makes tpi-bro publishable.** The repo can ship the bring-up story,
  the execution contract, and a demo pipeline without shipping — or even
  referencing — anyone's personal automation brain. Conversely, anyone can
  point their own producers at the queue and use the cluster as a general
  processing machine; the focus-following story is one user of the
  contract, not a prerequisite for it.
- **It matches the dependency discipline on the other side of the fence.**
  The external orchestrator ecosystem this was designed against follows a
  strict "consumers depend on the orchestrator, never the reverse" rule;
  a queue-only boundary means this cluster is just another consumer-side
  facility, imposing nothing upstream.

## Consequences

- **Sequencing.** (1) Bring-up orchestrator first — it gates the public
  release regardless of this ADR. (2) E-01 (KEDA + Redis) next — the queue
  *is* the contract, and E-03/E-04/E-05 all build behind it. (3) A
  demonstration pipeline: chunked audio → Whisper STT job (warm worker via
  model affinity) → trigger-extraction job → event handed off at the
  boundary. Close-to-live with a deliberate delay — an honest non-real-time
  trigger loop, and the flagship example of the contract in use.
- **E-05's dispatcher-state questions stay cluster-internal.** Whatever the
  dispatcher needs to know (warm nodes, capacity) it learns from the k8s
  API on its side of the queue; none of it leaks into the contract.
- **E-06 (image labels) becomes the job-type ↔ capability glue**: job types
  reference container images whose labels declare capability needs; the
  dispatcher matches those against node labels. Still gated on the upstream
  image-label implementation.
- **Job-type schema is deliberately not designed in this ADR.** Queue key
  naming, payload shape, result convention, and versioning are E-01/E-05
  work — designing them without a first real consumer would be speculation.
- **Possible generalization, noted but not pursued:** nothing in the
  contract is TuringPi-specific. With CM4/RPi or Jetson Orin Nano modules
  (DOC-04), the same queue-fronted execution tier generalizes to arbitrary
  small ARM clusters. Branding aside, that is a future direction, not a
  commitment.

## Related

- ADR-0022 — event-driven scheduling and interruptible workloads (the
  machinery behind the boundary)
- ADR-0024 — all workloads in containers
- ADR-0026 / ADR-0027 — parallel dispatch, model-affinity scheduling
- `backlog/BACKLOG.md` E-01, E-03, E-04, E-05, E-06
