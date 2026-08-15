# ADR-0029 — Job queue contract, v1

**Date:** 2026-08-15
**Status:** Accepted

---

## Context

ADR-0028 makes the typed job queue the sole boundary between this cluster
and anything upstream. E-01 deploys that queue (KEDA + Redis,
`scripts/install-jobqueue.sh`, `charts/jobqueue`). This ADR fixes the
*minimum* contract a producer and a worker must agree on — deliberately
small, because designing a rich schema before real consumers exist would be
speculation. The demo `echo` job type in `charts/jobqueue` is the living
reference implementation.

## Decision

### Transport

- One Redis **list per job type**: key `jobs:<type>` (e.g. `jobs:echo`).
- Producers `LPUSH`; workers `RPOP` — FIFO per type.
- Redis runs in namespace `jobqueue` behind `requirepass` (secret
  `jobqueue-redis-auth`, password in `~/.turingpi/credentials.kv` as
  `REDIS_PASSWORD`, auto-generated on first install). Reachable in-cluster
  at `jobqueue.jobqueue.svc.cluster.local:6379` and off-cluster via the
  Tailscale subnet-routed ClusterIP — that off-cluster path *is* the
  ADR-0028 boundary in practice.

### Job envelope

A job is a single JSON object:

```json
{"id": "<producer-chosen, unique>", "payload": { ... }}
```

- `id` — required; the producer's handle for retrieving the result.
  Producers own uniqueness (a timestamp + random suffix is fine).
- `payload` — required; the job type defines its shape. The type itself is
  *not* in the envelope — the queue key is authoritative.

### Results

- Workers `SET result:<id> <json> EX <ttl>` (TTL ≥ 1h; `echo` uses 3600).
- The result JSON always carries `"ok": true|false`; on failure, an
  `"error"` field explains. Absence of the key means "not done yet (or
  expired)" — v1 has no separate status channel.

### Scaling

- One KEDA `ScaledJob` per job type, triggered on `listLength ≥ 1`,
  authenticated via the shared `TriggerAuthentication`. A worker run pops
  **one** job, processes it, writes the result, and exits; an empty pop
  (lost race with another worker) exits 0 quietly. Workers carry
  `tpi-bro/interruptible: "true"` and a priority band per the E-track
  band-rotation principle.

### Delivery semantics: at-most-once, on purpose (v1)

`RPOP` means a worker that crashes after popping loses the job. That is
accepted for v1 — and it is *load-bearing* that producers design for it:

**Producer obligation — chunked and interruptible, always.** All work
scheduled through this queue must be expressed as jobs small enough that
losing or redoing one is cheap, because band-rotation focus switching
evicts interruptible workers mid-run by design. Long-running work is many
small jobs, never one big one. This obligation sits with the *producers* —
in the focus-following architecture, that means the external orchestrator's
consumers, which do the dispatching (the orchestrator itself knows nothing
about compute). How those producers structure their work into resumable
chunks is their design problem, acknowledged as future work on their side
of the fence.

A reliable-delivery pattern (`RPOPLPUSH`/`LMOVE` to a per-worker processing
list with reaper, or Redis Streams with consumer groups) is deliberately
deferred until a real consumer demonstrates the need — likely alongside
E-05's dispatcher design.

### Versioning

None in v1. If a job type's payload must change incompatibly, mint a new
type name (`transcribe.v2`) — the old list keys keep working for old
producers. Revisit when there are enough real types for this to hurt.

## Consequences

- New job types are added by copying the `echo` pattern: a `ScaledJob` +
  worker container that speaks this contract. No changes to Redis, KEDA, or
  any producer-side plumbing.
- `tests/check-cluster.sh` C19 asserts the boundary end-to-end (enqueue →
  KEDA scale-from-zero → result) on every full health check, so
  "operational" now includes the contract being live.
- The E-04 focus-switching scenarios (band ping-pong, equal-band inertness)
  run *on top of* this contract once written.

## Related

- ADR-0028 — the queue as the sole external boundary
- ADR-0022 — event-driven scheduling and interruptible workloads
- `backlog/BACKLOG.md` — E-track preamble (band rotation), E-03/E-04/E-05
- `charts/jobqueue/` — reference implementation (`echo`)
