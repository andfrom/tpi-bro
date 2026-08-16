# Self-Healing Node Recovery

The cluster recovers autonomously from hung, crashed, and half-booted
nodes. Built as independent layers (originally backlog item C-04, completed
2026-08-15/16), each validated with a live destructive test. Both incident
classes that motivated the design happened for real on 2026-08-15: a
runaway allocation kernel-wedged node1 (ping alive, sshd/API dead, OOM
killer stuck — manual BMC power-cycle needed; the allocator was later
traced to our own test harness, not the NPU runtime — see
`RKNN-SA-KV-DECODER-BUG.md` §Postscript — which changes nothing about the
recovery need), and node2's warm reboot hit
flaky PCIe link training (booted "healthy", NVMe absent, never reachable).

| Layer | Catches | Mechanism | Validated by |
|---|---|---|---|
| 1. On-SoC hardware watchdog | Kernel starvation/hang (PID1 can't pet) | Synopsys DW watchdog + systemd `RuntimeWatchdogSec=60`; `kernel.panic=10`, `panic_on_oops=1` | sysrq-forced kernel crash on node3 → self-reset in **50 s**, no BMC |
| 2. BMC watchdog, ssh track | Node unreachable (wedge, dead boot, net down) | BMC daemon probes TCP/22 for an `SSH-2.0` banner; power-cycles after guards | sshd stopped on node4 → autonomous `WEDGED` → cycle → back, cluster 15/0; guard logic (cooldown/give-up/cap) unit-tested in CI (`tests/check-bmc-watchdog-logic.sh`) |
| 3. Workload layer | Lost/evicted work | Queue contract (ADR-0029): SIGTERM-trap requeue for graceful eviction; producers re-enqueue on result-TTL timeout for hard kills | Real node power-cycles: 15/0 quick suite, zero manual repair |
| 4. Deep probe + alerts | "Healthy but hollow" (booted, ssh fine, NVMe absent) | BMC daemon checks node-exporter for `/mnt/ssd` on NVMe nodes → cold cycle (the PCIe-flake fix); PrometheusRule mirrors it in Grafana | Deep probe smoke-tested from the BMC; alert rule Flux-synced |

## Layer 1 — on-SoC hardware watchdog

`scripts/enable-hw-watchdog.sh` (idempotent; per-node or all; `--verify`;
`--rolling-reboot` for the activation reboot, workers first, control plane
last). The RK1's `watchdog@feaf0000` ships DT-disabled; a DT overlay
(`/boot/overlays/enable-wdt.dtbo`) flips it to `okay`, wired through
`u-boot-update`'s overlay support.

Sharp edge, encoded in the script: `U_BOOT_FDT_OVERLAYS_DIR` must be the
rootfs-absolute `"/boot/overlays"` — this u-boot-update build never sets
`_BOOT_PATH`, so the configured dir is used verbatim in both the filesystem
check and extlinux.conf. The dir is not kernel-versioned → overlays survive
kernel updates.

Armed state looks like: `systemd: Using hardware watchdog 'Synopsys
DesignWare Watchdog', device /dev/watchdog0` (shown by `--verify`).

## Layers 2 + 4 — BMC-resident watchdog

`scripts/bmc/bmc-watchdog.sh`, runs ON the BMC (BusyBox/Buildroot — the
only always-on vantage that survives all four nodes hanging), installed by
`scripts/install-bmc-watchdog.sh` (`--verify` / `--test-mode` /
`--uninstall`). Two probe tracks per node:

- **ssh track**: `curl telnet://<node>:22` must return an `SSH-2.0` banner.
  Covers both measured unreachable signatures (kernel-starved wedge: ping
  OK, banner dead; failed boot: nothing).
- **deep track** (nodes flagged `ssd` in `NODES`): node-exporter
  (`:9100/metrics`) must report the `/mnt/ssd` mount. Catches the
  PCIe-flake state, which layer 1 *cannot* see (PID1 pets happily) and the
  ssh track *cannot* see (sshd answers). A cold power-cycle is exactly that
  state's fix. Longer grace (DaemonSet pods appear later than sshd).

A power-cycle happens only when ALL guards pass: BMC reports the node On
(a deliberately-off node is never touched), threshold consecutive failures
(production: 10 × 30 s = 5 min), boot grace expired, 30 min per-node
cooldown, and < 3 cycles in 24 h — after which it logs `GIVE-UP` and leaves
the node down for a human. No boot loops by construction — a claim pinned
by unit tests (Suite 6, `tests/check-bmc-watchdog-logic.sh`, runs in CI
with a stubbed clock and `tpi`).

Log: `/mnt/sdcard/bmc-watchdog.log` on the BMC (persistent). Lines to know:
`FAIL`/`DEEP-FAIL` (first failure), `WEDGED`/`DEEP-WEDGED` (threshold, will
act), `ACTION` (cycling), `RECOVERED`/`DEEP-RECOVERED`, `HOLD` (cooldown),
`GIVE-UP` (cycle cap — human needed).

## Visibility — Prometheus alerts

`gitops/apps/node-health-rules.yaml` (Flux-synced PrometheusRule):

- `NodeNvmeMissing` (critical, 10 m): fewer than 3 nodes report `/mnt/ssd`.
  The BMC deep track normally fixes this before the alert resolves on its
  own; **if it stays firing, the watchdog hit its cycle cap — go look**.
- `NodeExporterAbsent` (warning): scraping is down somewhere; the NVMe
  alert can't be trusted while this fires.

## Runbook

- After any `ACTION`/`RECOVERED` in the BMC log (or a fired alert):
  `tests/check-cluster.sh --quick`. This deliberately stays a human step —
  the BMC has no kubectl, and shipping cluster credentials to it is a worse
  trade than a one-command runbook line.
- `GIVE-UP` in the log / `NodeNvmeMissing` still firing: the node needs a
  human. Serial console via the BMC: `tpi uart -n <N> get`.
- **After any BMC firmware update**: the BMC's `/etc` overlay may be reset —
  re-run `scripts/install-bmc-watchdog.sh` (same caveat as the static-IP
  setup's `setStaticNet.sh`).
- Status checks: `scripts/enable-hw-watchdog.sh --verify` (layer 1),
  `scripts/install-bmc-watchdog.sh --verify` (layers 2+4).

## Hard kills and workloads (layer 3)

Watchdog power-cycles are hard kills — an automated, normal event. The
queue contract's SIGTERM-trap requeue covers graceful eviction only; a
popped job dies with the node and nothing requeues it. Producers needing
at-least-once re-enqueue on their own `result:<id>` timeout; chunk payloads
are idempotent under the chunked-work obligation, so re-running is always
safe. Full statement in ADR-0029 §Delivery semantics.

## Bring-up

Both layers are `bootstrap-operational.sh` stages: `C04_bmc_watchdog` runs
BEFORE `C04_hw_watchdog` so the outer-loop prober already guards the
hw-watchdog stage's rolling reboot against the warm-reboot PCIe flake. A
fresh bring-up gets self-healing by default.

## See also

- `HARDWARE-FIRMWARE-ISSUES.md` — the two motivating incidents (rknn_init
  runaway wedge; warm-reboot PCIe link-training flake)
- `adr/ADR-0029-job-queue-contract-v1.md` — delivery semantics incl. hard kills
- `docs/backlog/BACKLOG.md` — S-03 and other future resilience work
