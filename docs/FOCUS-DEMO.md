# Focus Demo — band rotation on the job queue, live

The flagship demonstration of what this cluster is *for* (ADR-0028): two
competing tasks flow through the typed job queue (ADR-0029), and a "focus
switch" rotates which one owns the compute — visibly, in real time, on a
Grafana dashboard, with evicted work re-queuing itself instead of being
lost.

## The cast

- **Task A — tiered audio transcription.** Audio is fed as ~15 s chunks
  onto `jobs:transcribe.small`. The *live tier* (Whisper `small`, CPU
  int8, greedy) transcribes each chunk in roughly real time; on completion
  each worker enqueues the **same chunk** onto `jobs:transcribe.medium`,
  where the *refinement tier* (Whisper `medium`, beam 5) later replaces
  the quick text with a more accurate pass. The refinement tier always
  runs in the `background` band — async catch-up is its job description.
- **Task B — `crunch`.** A chunked synthetic compute task (N-second CPU
  burns), the stand-in for "some other long-running thing you switch
  focus to."

## The arena

All demo workers are pinned to **one node** and request enough CPU that
**only one worker fits at a time**. That single slot is what makes focus
unambiguous: whoever holds the slot *is* the focused work.

## The mechanics (nothing bespoke)

- **Focus switch = band rotation** (see the E-track design principle in
  `backlog/BACKLOG.md`): `run-focus-demo.sh focus a|b` patches the two
  ScaledJobs' `priorityClassName` — the *fixed* bands
  `interactive`/`background` get reassigned, nothing is ever incremented —
  and evicts the demoted type's running worker.
- **Eviction is safe by contract**: every worker traps SIGTERM,
  re-enqueues its current chunk with `attempt+1`, and bumps
  `metrics:evicted:<type>`. A focus switch costs at most one chunk of
  redone work per side — the ADR-0029 producer obligation (chunked,
  interruptible) paying off.
- **Preemption is native**: with the arena contended, a Pending
  `interactive` worker preempts a Running `background` one via ordinary
  Kubernetes scheduling. No custom scheduler, no dispatcher daemon.
- **Background is deprioritized, not suspended**: when the focused queue
  goes momentarily empty, a background chunk grabs the slot — by design.

## Running it

```bash
./scripts/run-focus-demo.sh install    # chart into the jobqueue namespace
./scripts/run-focus-demo.sh audio      # synthesize + chunk demo speech
./scripts/run-focus-demo.sh scenario   # the full show (~4 min)
```

The scenario: focus on A while audio chunks stream in → after ~35 s,
focus to B (watch A's in-flight chunk get evicted and re-queued; crunch
takes the slot) → after ~35 s, focus back to A → queues drain → the arena
is handed back to B. `status` and `transcript` subcommands show the state
at any point; `transcript` prints both tiers side by side so the
refinement catching up is visible.

## Watching it

Grafana (on the Tailnet, `monitoring` namespace) auto-loads the
**"Focus Demo — job queue band rotation"** dashboard:

| Panel | What it shows |
|---|---|
| Who holds the arena slot | Running worker per type over time — the focus switches are plainly visible as the colored bands trade places |
| Queue depth per job type | `jobs:*` list lengths (redis_exporter) — A's backlog growing while B has focus, and vice versa |
| Chunks evicted (had to run again) | `metrics:evicted:*` — each focus switch steps these counters |
| Chunks completed | `metrics:completed:*` |
| Where demo workers run | Node placement (should be pinned to the arena node) |

## What this is a demo *of*

Everything here goes through the ADR-0029 contract — the demo driver is
just another queue producer, indistinguishable from an external
orchestrator's consumer. Replace `run-focus-demo.sh focus` with a real
focus signal source and `enqueue-chunk` with a live audio feed, and this
*is* the close-to-live STT trigger loop: transcription as an event source,
focus switching as band rotation, and a cluster that follows attention
without ever exposing more than a queue.
