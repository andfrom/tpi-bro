# ADR-0031 — Self-healing node recovery as layered watchdogs

**Date:** 2026-08-16
**Status:** Accepted (implemented; see `../SELF-HEALING.md` for mechanics)

---

## Context

Two real incidents (2026-08-15) established that this cluster must recover
from node-level failure without a human: a runaway allocation kernel-wedged
the control-plane node (ping alive, sshd and the k8s API dead, the system
OOM killer unable to recover), and a warm reboot lost a node's NVMe to
flaky PCIe link training while the node booted "healthy." Both needed
manual BMC power-cycles. An unattended cluster that needs a human for its
worst failure mode isn't operational.

The k8s-native remediation ecosystem (node-problem-detector, medik8s
NodeHealthCheck/self-node-remediation, Cluster API machine remediation)
was considered and rejected as the primary mechanism for one structural
reason: **it lives inside the thing that fails.** This cluster has a
single control-plane node; the first incident wedged exactly that node,
taking the API server — and any in-cluster remediation controller's eyes
and hands — down with it. Software-only remediation also cannot fix the
second incident class (a hard power-cycle is the only thing that retrains
a failed PCIe link).

## Decision

Recovery is built as independent layers, each with its own failure-class
coverage, and the outer layer lives on the only always-on vantage point
that survives all four nodes failing: the BMC.

1. **On-SoC hardware watchdog** (first line): systemd pets the SoC
   watchdog; a starved PID1 hard-resets the node with no external
   dependency at all. Catches kernel starvation/hang.
2. **BMC-resident prober** (outer loop): a BusyBox-sh daemon on the BMC
   probes each node (ssh banner; plus a node-exporter deep probe for
   "booted but NVMe missing") and power-cycles through the BMC's own
   `tpi` — the one actuator that fixes every observed failure class,
   including PCIe retraining.
3. **Workload layer**: the ADR-0029 queue contract makes lost work
   re-enqueueable; no new mechanism needed.
4. **Visibility**: a Flux-synced PrometheusRule mirrors the deep-probe
   condition so a human learns when the automation gave up.

Two boundaries are load-bearing:

- **No cluster credentials on the BMC.** The BMC daemon acts only through
  power state and unauthenticated probes (TCP banner, public metrics
  endpoint). Post-recovery *verification* (`check-cluster.sh`) stays a
  human/laptop step by design — shipping a kubeconfig to a
  vendor-firmware BusyBox box is a worse trade than a one-command runbook
  line.
- **Boot-loop protection is enforced by fixed guards, not left to
  operator judgment.** A cycle happens only when the BMC reports the node
  On, failures crossed a threshold over minutes, boot grace expired, a
  per-node cooldown passed, and a 24-hour cycle cap isn't hit — after
  which the daemon logs GIVE-UP and leaves the node down for a human.
  The guard logic is unit-tested in CI
  (`tests/check-bmc-watchdog-logic.sh`).

## Consequences

- A fresh bring-up gets self-healing by default (two
  `bootstrap-operational.sh` stages; the BMC stage runs first so it
  guards the hardware-watchdog stage's own rolling reboot).
- The BMC's `/etc` overlay can be reset by firmware updates — the daemon
  must be re-provisioned afterwards (installer is idempotent; runbook in
  `../SELF-HEALING.md`).
- Watchdog power-cycles make hard kills a *normal* event; ADR-0029
  documents the consequence for producers (re-enqueue on result-TTL
  timeout for at-least-once needs).
- The on-SoC watchdog required enabling a DT-disabled device — a per-OS
  sharp edge documented in `scripts/enable-hw-watchdog.sh`.

## Related

- `../SELF-HEALING.md` — mechanics, guards, log vocabulary, runbook
- ADR-0029 — hard-kill delivery semantics
- ADR-0007 — tpi CLI for BMC power control (the actuator this builds on)
- `../HARDWARE-FIRMWARE-ISSUES.md` — the two motivating incidents
