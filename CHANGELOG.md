# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is
[SemVer](https://semver.org/).

This is the project's first public release, so the initial entry is
Added-only: everything before it happened in private development, and
`Changed`/`Fixed` are only meaningful relative to a previous *public*
state.

## [Unreleased]

## [0.1.0] — TBD (first public release)

### Added

**Bootstrap**
- Phase A: resumable, staged Expect bootstrap from bare boards — BMC
  discovery (mDNS/nmap/manual), optional BMC firmware check/upgrade,
  image download with SHA256 cache + verification, flashing (sdcard and
  BMC flash modes), first-boot password handling, node naming, static
  IPs for BMC + nodes, laptop `/etc/hosts`; `--dry-run` everywhere;
  `--rediscover` for IP drift; full teardown script.
- `bootstrap-operational.sh`: one command from a flashed cluster to fully
  operational — k3s, TLS+auth registry (HostPort, NVMe-backed), local-ssd
  StorageClass, resource policy (PriorityClasses/LimitRanges), capability
  labels, Tailscale mesh + subnet routes + k8s operator, Flux GitOps,
  Ollama, kube-prometheus-stack monitoring, the job queue, and the
  self-healing watchdogs; staged/resumable with preflight and one manual
  gate (Tailscale route approval).

**Execution tier**
- Typed job queue (KEDA + Redis) as the cluster's sole external boundary
  (ADR-0028), with a minimal producer/worker contract (ADR-0029): one
  Redis list per job type, JSON envelope, result keys with TTL,
  at-most-once semantics with the chunked/interruptible producer
  obligation, and documented hard-kill behavior.
- Band-rotation focus scheduling (fixed PriorityClasses, reassigned—never
  escalated; ADR-0030): kube-scheduler-native preemption, SIGTERM-trap
  requeue with eviction counters, no dispatcher daemon.
- Focus-switching live demo (`charts/focusdemo/`, `run-focus-demo.sh`):
  tiered near-realtime speech transcription vs. a chunked compute job,
  focus rotated live, evictions and re-queues visible on a Grafana
  dashboard.

**Self-healing**
- On-SoC hardware watchdog armed fleet-wide via DT overlay + systemd
  (validated: sysrq-forced kernel crash → 50 s autonomous recovery).
- BMC-resident node watchdog: SSH-banner probe (wedge/dead-boot) + deep
  probe via node-exporter (the "booted but NVMe missing" PCIe-flake
  state), cold power-cycles under strict guards (power-state check,
  thresholds, boot grace, cooldown, 24 h cycle cap → give-up); guards
  unit-tested in CI. Prometheus alert rules mirror the deep-probe
  condition in Grafana.

**NPU / Whisper**
- Whisper STT chart (`charts/whisper/`) with CPU (faster-whisper) and
  RKNN NPU paths, including the self-attention KV-cache decoder (~2.5×
  measured over the naive decoder; validated up to large-v3) and
  fail-fast template guards.
- NPU characterization: measured datasheet (FP16/INT8 kernel ceilings,
  thermal behavior), reusable benchmark harness (`tools/npu-bench/`),
  and honest end-to-end Whisper numbers.
- Hardware/firmware issue index with root-caused vendor-stack bugs
  (silent NC1HWC2 input loss — worked around with an in-model shim;
  INT8 transformer collapse; warm-reboot PCIe link-training flake), a
  vendor-response tracker, and the project's visible-retractions record
  (including one where the accused runtime turned out innocent and the
  bug was our own test harness).

**Tests / CI**
- Six suites: offline dry-run + mock/fault-injection (31 tests, CI),
  hardware cluster cycles, 19-check live cluster health (incl. an
  end-to-end job-queue roundtrip), live scheduling-behavior validation
  (band rotation, equal-band inertness), and BMC-watchdog guard-logic
  unit tests (CI). CI also enforces shellcheck (bash + BusyBox sh),
  bash/sh syntax, Expect parse smoke, helm lint + a full chart render
  matrix with negative guard assertions, and markdown link integrity.

**Documentation**
- Full doc set: getting-started walkthrough, operations runbook (incl.
  BMC recovery), self-healing design + runbook, pragmatic
  "Is this for you?" hardware assessment, NPU characterization/datasheet,
  deep-dive bug write-ups, 30 ADRs, backlog, contributing guide.

[Unreleased]: https://github.com/andfrom/tpi-bro/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/andfrom/tpi-bro/releases/tag/v0.1.0
