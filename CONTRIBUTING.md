# Contributing to tpi-bro

Thanks for your interest! This project has a particular culture around
evidence and honesty in engineering claims — reading this page first will
make your contribution land smoothly.

## The one rule that shapes everything: measured, or labeled

This repo's value is that its numbers are real. The NPU docs say
~230 GFLOP/s where the marketing says 6 TOPS; a projected 1.5× speedup was
re-measured at 1.10× and *both* numbers are in the docs; a wrong diagnosis
("breaks beyond 18 layers") was published, disproven, and the retraction
kept visible rather than erased. Contributions follow the same bar:

- **Performance/behavior claims come with the measurement** — what you ran,
  on what hardware/runtime versions, and the actual numbers. "Should be
  faster" is a hypothesis; label it as one.
- **Corrections don't erase history.** If you disprove something in the
  docs (including your own earlier PR), the fix states what was believed,
  what the evidence showed, and why the earlier conclusion was wrong.
  False trails are documentation, not embarrassment.
- **Silent-failure hardware demands paranoid validation.** For anything on
  the RKNN/NPU path, a passing similarity check is not proof (see
  `docs/RKNN-SA-KV-DECODER-BUG.md` for why) — use the fingerprint tooling
  referenced there, and run RKNN workloads memory-capped, always
  (`docs/HARDWARE-FIRMWARE-ISSUES.md`).

## What contributions are welcome

- **Bug reports with evidence** — logs, kernel messages, versions. For
  hardware weirdness, `tpi uart -n N get` output from the BMC is gold.
- **Fixes and hardening** for the bootstrap scripts, charts, and tests.
- **Docs** — especially "I followed this on fresh hardware and step X
  surprised me." First-run friction reports are some of the most valuable
  input this project can get.
- **Portability reports**: other TuringPi/RK3588 configurations, other
  NVMe/no-NVMe layouts. (Jetson/CM4 support is tracked as DOC-04 and is
  currently aspirational — groundwork PRs welcome, claims of support are
  not, until someone has run it on the hardware.)
- **No hardware? Still useful**: doc review, shell/Helm review, and
  reproducing the x86-simulator side of RKNN issues all work without a
  cluster.

## Practicalities

- **Shell scripts must pass `shellcheck`** — the pre-commit hook runs it
  on staged scripts. BusyBox-targeted scripts (`scripts/bmc/`) must stay
  POSIX sh.
- **Tests**: `tests/check-cluster.sh` (19 live checks) must stay green on
  real hardware for cluster-affecting changes; `tests/check-scheduling.sh`
  covers the priority/eviction behavior. Say in the PR which suites you
  ran and on what.
- **Commits**: imperative subject, body explains *why*. If a change was
  AI-assisted, that's fine — this whole project is, openly — the human
  judgment applied to verify it is what the PR description should show.
- **Scope**: this repo is the cluster bootstrap + execution tier. Model
  conversion pipelines and inference drivers live in their own repo
  (referenced from `docs/`); orchestrator/brain logic deliberately sits
  behind the queue boundary (ADR-0028) and does not belong here.

## Where things are

| You want | Look at |
|---|---|
| Architecture decisions | `docs/adr/` (ADR-0022/0028/0029/0030 are the spine) |
| What's planned/open | `docs/backlog/BACKLOG.md` |
| Hardware/firmware sharp edges | `docs/HARDWARE-FIRMWARE-ISSUES.md` |
| Ops runbook, BMC recovery | `docs/OPERATIONS.md` |
| Self-healing design | `docs/SELF-HEALING.md` |
| Is this platform even for me? | `docs/IS-THIS-FOR-YOU.md` |

## Conduct

Be kind, be specific, argue with evidence. Vendor-bashing without a repro
is noise; a minimal repro of a vendor bug is a gift (see the response
tracker in `docs/RKNN-INT8-WHISPER-314.md` for how those are handled).
