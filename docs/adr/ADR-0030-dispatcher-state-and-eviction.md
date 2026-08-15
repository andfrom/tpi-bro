# ADR-0030 — Dispatcher state model: there is no dispatcher

**Date:** 2026-08-15
**Status:** Accepted
**Resolves:** backlog E-05 (dispatcher state management); disposes of E-03
(eviction init container) as superseded.

---

## Context

E-05 asked how "the dispatcher that implements ADR-0026/0027" should learn
which nodes are capable, warm, and free: query per dispatch, or maintain a
watch-fed cache — and whether the k8s API is a sufficient single state
source given warm-label staleness (a pod can be Running for ~25 s before
its model is actually in memory).

The question predates ADR-0028/0029 and the focus demo, which changed the
premise: the platform now works **without any dispatcher daemon at all**.
The dispatch function decomposed into three existing actors:

| Function | Actor | State it uses |
|---|---|---|
| How many workers per job type | KEDA | queue depth (Redis) |
| Where a worker runs | kube-scheduler | capability labels + requests/allocatable |
| Who yields to whom | kube-scheduler preemption | priority bands |
| Focus itself | an external actuator (today: a script; later: a queue producer's agent) | band assignments on ScaledJobs |

## Decision

**1. No dispatcher daemon.** Scheduling state lives where Kubernetes
already keeps it; the only custom "dispatch" action in the system is band
rotation (patching ScaledJob templates) plus the optional explicit evict of
demoted `tpi-bro/interruptible` pods — both stateless one-shots.

**2. The k8s API is the single state source — and warm-ness must be
written by the thing that got warm.** For any future warm-model routing
(ADR-0027), the `tpi-bro/model-loaded=<model>` label is set **by the
worker itself, after the model is actually in memory** — never inferred
from pod phase. That dissolves the staleness question by construction:
the label means "loaded now," and a crash leaves at worst a stale label
that the next scheduling decision treats as advisory (prefer, don't
require — `preferredDuringScheduling`, not `required`). Implementing this
labeler + preference is future work, tracked as **E-07**.

**3. Poll, don't watch, at this scale.** Any component that does need
cluster state (the focus actuator, E-04's test suite, a future E-07
router) re-queries the API per decision. Arithmetic: a decision costs 2–3
GETs (~10–30 ms each) against chunk runtimes of seconds to minutes —
<1 % overhead at 4 nodes. A watch-fed cache earns its complexity only when
sustained decision rate approaches ~1/s or the node count makes list calls
expensive (tens of nodes). Neither is on this cluster's horizon; revisit
then, not before.

**4. KEDA is complementary, with one documented seam.** KEDA holds no
placement or priority state — it turns queue depth into Job objects from
the ScaledJob template. Band rotation patches that template, which affects
**future** Jobs only; running Jobs keep their band until they finish or
are evicted. That asymmetry is not a bug — it *is* the rotation semantics
(admission-time banding), and the explicit-evict step in a focus switch
exists precisely to shorten the tail.

**5. E-03 is closed as superseded.** The init-container eviction design
(a pending job's init container deletes interruptible pods on its target
nodes) predates the demo. Native preemption plus the ADR-0029 TERM-trap
requeue contract demonstrably covers its use case — a strictly-higher-band
Pending pod evicts a lower-band Running pod under contention, and the
evicted chunk self-requeues. What the init container would add is eviction
*without* a band difference, which the band-rotation principle explicitly
forbids (equal-band work must be inert; pinned by E-04), or a duplicate of
scheduler logic that can race with it. The lasting residue of E-03 is the
**`tpi-bro/interruptible` label as a contract marker**: it declares "this
pod implements TERM-trap requeue and is safe to evict," and any explicit
eviction (focus switches, drains) must target only labeled pods.

## Consequences

- E-05's four backlog questions are answered (single source: yes, with
  worker-written warmth; poll; thresholds recorded; KEDA seam documented).
- E-03 closes; the interruptible-label contract moves into this ADR and
  ADR-0029's orbit.
- **E-07 (new):** warm-model affinity implementation — worker-written
  `tpi-bro/model-loaded` labels + `preferred` node affinity in model-bearing
  job templates + the E-04 warm/cold validation scenarios that are blocked
  until it exists.
- E-04 proceeds now on the runnable subset: band ping-pong without
  escalation, equal-band inertness, background progress on slack.

## Related

- ADR-0022 (event-driven scheduling), ADR-0027 (model affinity — design),
  ADR-0028 (queue boundary), ADR-0029 (job contract, TERM-trap requeue)
- `backlog/BACKLOG.md` E-track preamble (band rotation), E-04, E-07
- `docs/FOCUS-DEMO.md` — the evidence base for §5
