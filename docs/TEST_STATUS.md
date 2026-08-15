# tpi-bro — Test Status & Coverage Map

_Last updated: 2026-08-16_

## Current state

**Automated tests implemented.** `tests/run-ci.sh` runs 31 tests (Suites 1 + 2)
on every push/PR via GitHub Actions — no hardware required. `tests/run-hardware.sh`
orchestrates the full cluster-cycle verification (Suite 3) when real hardware is
available. `tests/check-cluster.sh` (Suite 4) tests a running cluster end to end:
**19 checks** covering node readiness, registry TLS + auth + push + per-node pod
pull, NVMe storage, capability labels, PriorityClasses, the Tailscale mesh, and a
full job-queue roundtrip (enqueue → KEDA scale-from-zero → result).
`tests/check-scheduling.sh` (Suite 5) validates the band-rotation scheduling
behavior live: equal-band inertness, 4-switch focus ping-pong with pinned
priority values, and background-progress-on-slack.
`tests/check-bmc-watchdog-logic.sh` (Suite 6) unit-tests the BMC watchdog's
cycle guards (cooldown, give-up cap, probe parsers) with stubbed clock/tpi —
no hardware, runs in CI.

**Coverage note:** Suites 1–3 cover Phase A (bootstrap) only. Phase B shell
scripts and Helm charts are validated by Suites 4–5 (manual, require a running
cluster) plus the `--verify` modes of the install scripts. Agent workloads are
deliberately not deployed on this cluster (they live upstream of the job-queue
boundary, ADR-0028) and are therefore not tested here.

---

## Path map

Every decision point in both scripts. `✗` marks a die/abort path.

```
bootstrap-turingpi-cluster.exp
│
├── --help / --usage ─────────────────────────────────── exit 0
│
├── --config loading (runs before stage loop)
│   ├── no --config + no ./bootstrap-config.kv ──── use hardcoded defaults
│   ├── no --config + ./bootstrap-config.kv exists ─ auto-load file
│   ├── --config FILE  (file exists) ─────────────── load; CLI flags override
│   └── --config FILE  (file missing) ────────────── die ✗
│
├── --rediscover [--dry-run]
│   ├── dry ────────────────────────────────────────── print plan, exit
│   ├── BMC found on subnet
│   │   ├── IP changed ──────────────────────────── update state + /etc/hosts
│   │   └── IP unchanged ────────────────────────── no-op
│   ├── BMC not found ──────────────────────────────── warning, continue
│   └── per expected node
│       ├── found (IP changed / unchanged) ──────── update state + MAC
│       └── not found ───────────────────────────── warning, keep old entry
│
└── stage loop  [--phase A]  [--from X --to Y]
    │
    ├── A0  bmc_firmware
    │   ├── skip (default) ─────────────────────────── "Skipping BMC firmware check"
    │   ├── dry (any mode) ─────────────────────────── print plan, exit before BMC_HOST check
    │   ├── check
    │   │   ├── tpi info → version matches latest ──── "already up to date"
    │   │   └── tpi info → version outdated ─────────── warning; no action
    │   └── upgrade
    │       ├── bmc-manifest.kv missing ────────────── die ✗
    │       ├── download OK + SHA256 OK ─────────────── flash firmware + wait for reboot
    │       ├── download fails ──────────────────────── die ✗
    │       └── SHA256 mismatch ─────────────────────── die ✗
    │
    ├── A1  find_bmc
    │   ├── dry ────────────────────────────────────── print nmap plan
    │   ├── bmc_ip already in state ────────────────── restore BMC_HOST, skip scan
    │   └── bmc_ip not in state
    │       ├── nmap finds BMC
    │       │   ├── MAC in ARP table ─────────────── store ip + mac
    │       │   ├── MAC not in ARP ───────────────── store ip only
    │       │   ├── /etc/hosts update OK ─────────── pin turingpi.local
    │       │   └── /etc/hosts update fails ──────── warning, continue
    │       └── nmap fails ──────────────────────── prompt for manual IP
    │
    ├── A2  poweroff_all
    │   ├── dry ────────────────────────────────────── print plan
    │   └── real ───────────────────────────────────── tpi power off  (warn on error)
    │
    ├── A3  flash_optional
    │   ├── skip ───────────────────────────────────── no-op
    │   ├── local
    │   │   ├── dry ────────────────────────────────── print tpi flash --local × N
    │   │   └── real ───────────────────────────────── tpi flash --local per node
    │   ├── image
    │   │   ├── IMAGE missing for any node ──────────── die ✗  (before touching hardware)
    │   │   ├── image file not found on disk ─────────── die ✗  (before touching hardware)
    │   │   ├── dry ────────────────────────────────── print tpi flash --image-path × N
    │   │   └── real ───────────────────────────────── tpi flash --image-path per node
    │   ├── download
    │   │   ├── manifest file missing ────────────────── die ✗
    │   │   ├── unknown image type for node ──────────── die ✗
    │   │   ├── dry
    │   │   │   ├── cache file present ─────────────── "cache hit – would verify + flash"
    │   │   │   └── cache file absent ──────────────── "would download URL → cache"
    │   │   └── real  (per distinct image type)
    │   │       ├── cache hit + SHA256 OK ──────────── reuse cache, skip download
    │   │       ├── cache hit + SHA256 mismatch ──────── delete file, re-download
    │   │       ├── cache miss + download OK + SHA256 OK ── store in cache, flash
    │   │       ├── cache miss + download fails ──────── die ✗  (partial file deleted)
    │   │       └── cache miss + SHA256 mismatch ─────── die ✗  + MitM warning
    │   ├── bmc
    │   │   ├── BMC SD card not mounted ─────────────── die ✗
    │   │   ├── manifest file missing ────────────────── die ✗
    │   │   ├── unknown image type for node ──────────── die ✗
    │   │   ├── stale images on SD card → ask_yn prompt (y deletes, N skips)
    │   │   ├── image already on SD card (SHA256 OK) ── skip download, flash directly
    │   │   └── real  (SSH to BMC; per distinct image type)
    │   │       ├── curl download + SHA256 OK ──────── decompress .xz on BMC; flash --local
    │   │       ├── curl download fails ──────────────── die ✗
    │   │       └── SHA256 mismatch ─────────────────── die ✗
    │   └── invalid FLASH_MODE ───────────────────────── die ✗
    │
    ├── A4  power_on_and_discover
    │   └── per node
    │       ├── node already in state ──────────────── skip
    │       ├── dry ────────────────────────────────── print plan
    │       ├── node appears within 300 s
    │       │   ├── MAC in ARP ──────────────────── store ip + mac
    │       │   └── MAC not in ARP ──────────────── store ip only
    │       └── node never appears (timeout) ────────── die ✗  (with recovery hint)
    │
    ├── A5  name_password_reboot
    │   ├── dry ────────────────────────────────────── print plan
    │   ├── node IP missing in state ────────────────── die ✗
    │   ├── node already configured (hostname matches) ── skip
    │   └── real ───────────────────────────────────── SSH: chpasswd + hostname + reboot + wait
    │
    ├── A6  write_hosts_on_laptop
    │   └── per node
    │       ├── IP missing in state ────────────────── warning + skip
    │       ├── dry ────────────────────────────────── print plan
    │       ├── /etc/hosts update OK ─────────────── done
    │       └── /etc/hosts update fails ─────────────── warning, continue
    │
    └── A7  ephemeral_registry
        ├── dry ────────────────────────────────────── print plan
        ├── registry node IP missing ────────────────── die ✗
        └── real: SSH install docker + run registry
            ├── registry HTTP reachable ────────────── "HTTP OK"
            └── registry not reachable ─────────────── warning


teardown-cluster.exp
│
├── --help ───────────────────────────────────────────── exit 0
│
├── T1  load_state  (locate nodes)
│   ├── dry ────────────────────────────────────────── print plan
│   ├── state file present / absent ─────────────────── (info only; both branches continue)
│   ├── no nodes located at all ─────────────────────── die ✗
│   └── per node
│       ├── stored IP responds + hostname matches ───── confirmed
│       └── stored IP stale / no stored IP → scan
│           ├── found by hostname on subnet ──────────── update state
│           └── not found anywhere ───────────────────── warning + added to skip list
│
├── T2  verify_connectivity  (report only — no branching logic)
│
├── T3  stop_registry
│   ├── registry node IP unknown ────────────────────── skip
│   ├── --remove-docker on ─────────────────────────── extra apt-get purge cmds
│   ├── dry ────────────────────────────────────────── print plan
│   └── real: SSH (success / warning)
│
├── T4  reset_passwords
│   └── per node: IP unknown → skip / dry / real (success / warning)
│
├── T5  reset_hostnames
│   ├── --keep-hostname ─────────────────────────────── skip stage entirely
│   └── per node: IP unknown → skip / dry / real (success / warning)
│
├── T6  clean_laptop_hosts
│   ├── dry ────────────────────────────────────────── print plan
│   └── real: bootstrap-host-helper.sh hosts-remove (success / warning)
│
├── T7  poweroff_nodes
│   ├── per node
│   │   ├── IP unknown ─────────────────────────────── skip graceful shutdown
│   │   ├── dry ────────────────────────────────────── print plan
│   │   ├── real: SSH poweroff → SSH gone within 60 s ── "down"
│   │   └── real: still reachable after 60 s ─────────── warning; BMC cuts power anyway
│   └── BMC hard power-off: dry / real (success / warning)
│
└── T8  clear_state
    ├── state file absent ───────────────────────────── no-op
    ├── dry ────────────────────────────────────────── print rename plan
    └── real ───────────────────────────────────────── rename to .bak.TIMESTAMP


NOT COVERED BY ANY SCRIPT
  ├── Phase B  k3s install + persistent registry
  ├── Phase C  resilience + laptop mirror
  └── Phase D  multi-agent workloads
```

---

## Suite 1 — CI dry-run  (20 paths, no hardware required)

These all pass in GitHub Actions on every push/PR. None touch real hardware, make
network requests to external servers, or require `sudo`. They verify that every
stage emits the expected dry-run output and that all error paths die with a
useful message.

Run with:

```bash
./tests/run-ci.sh --suite 1
```

| # | Command | Branch(es) exercised |
|---|---------|----------------------|
| D01 | `bootstrap --dry-run --phase A` | A0 skip, A1 no-state, A2, A3 skip, A4–A7 |
| D02 | `bootstrap --dry-run --phase A`  *(state file contains `bmc_ip`)* | A1 already-known |
| D03 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash local` | A3 local |
| D04 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash image --image w.img --image-1 s.img` | A3 image + per-node override |
| D05 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash image` *(no --image)* | A3 image → die |
| D06 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash download --manifest images-manifest.kv.example` *(no cache file)* | A3 download cache-miss |
| D07 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash download --manifest images-manifest.kv.example` *(dummy cache file present)* | A3 download cache-hit |
| D08 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash download --manifest /nonexistent.kv` | A3 download missing manifest → die |
| D09 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash download --manifest ...` *(config sets `IMAGE_1_TYPE=unknown`)* | A3 download unknown type → die |
| D10 | `bootstrap --dry-run --from A3_flash_optional --to A3_flash_optional --flash bogus` | A3 invalid FLASH_MODE → die |
| D11 | `bootstrap --dry-run --rediscover` | rediscover dry path |
| D12 | `bootstrap --config tests/fixtures/test-config.kv --dry-run --phase A` | config file loaded; values applied |
| D13 | `bootstrap --config /nonexistent.kv` | missing config → die |
| D14 | `bootstrap --dry-run --from BOGUS_STAGE` | unknown stage → die |
| D15 | `teardown --dry-run` *(state file present)* | T1–T8 all stages |
| D16 | `teardown --dry-run` *(no state file)* | T1 scan-only path + T8 no-op |
| D17 | `teardown --dry-run --keep-hostname --remove-docker` | T3 extended cmds + T5 skipped |
| D18 | `bootstrap --dry-run --from A0_bmc_firmware --to A0_bmc_firmware` | A0 skip path |
| D19 | `bootstrap --dry-run --from A0_bmc_firmware --to A0_bmc_firmware --bmc-firmware check` | A0 check dry-run |
| D20 | `bootstrap --dry-run --from A0_bmc_firmware --to A0_bmc_firmware --bmc-firmware upgrade` | A0 upgrade dry-run |

---

## Suite 2 — Mock / fault injection  (7 paths, no hardware required)

These run the scripts in **real (non-dry-run) mode** but against fabricated local
inputs. A stub `tpi` binary (`tests/fixtures/bin/tpi`) is injected at the front
of `$PATH` so the script never tries to connect to a real BMC. Download tests use
`file://` URLs so `curl` fetches local files — no external network needed.

Run with:

```bash
./tests/run-ci.sh --suite 2
```

| # | Setup | Command | Expected outcome |
|---|-------|---------|-----------------|
| M01 | 1 MB zero image + manifest with **correct** SHA256; `file://` URL | `bootstrap --flash download --manifest ...` | SHA256 OK; stub tpi exits 1 (expected); "mismatch" absent |
| M02 | Same image already in cache dir with correct SHA256 | Same as M01 | "Cache hit" logged; no re-download |
| M03 | Corrupted file in cache (SHA256 wrong) | Same | "re-downloading" logged; file deleted; fresh download attempted |
| M04 | Manifest pointing at `file:///nonexistent/path/image.img` | `bootstrap --flash download --manifest ...` | curl fails; die with "Download failed" |
| M05 | Manifest with **wrong SHA256** for a valid downloadable file | Same | Download succeeds; SHA256 check fails; die with "mismatch after download" |
| M06 | `tests/fixtures/test-config.kv` with `SUBNET=10.99.0.0/24` | `bootstrap --dry-run --phase A --config ...` | Dry-run shows `10.99.0.0/24` (config loaded) |
| M07 | State file with `bmc_ip=192.168.99.1` | `bootstrap --dry-run --phase A --config ...` | A1 logs "already known at 192.168.99.1" (state-restore path) |

---

## Suite 3 — Hardware verification  (requires TuringPi + 4× RK1 nodes)

Run manually before any significant merge to main. A full verification run
consists of **two full bootstrap→teardown cycles** plus targeted edge-case runs.
Two cycles confirm that teardown produces a genuinely clean slate and that a
second bootstrap from scratch succeeds without residual state.

### 3.1  Standard cycle  (run twice)

```
bootstrap --phase A           # A1–A7, flash=skip
  → verify: ssh rk1-node{1..4} hostname
  → verify: curl http://rk1-node1:5000/v2/_catalog

teardown                      # T1–T8
  → verify: /etc/hosts no longer contains rk1-node* or turingpi.local
  → verify: tpi power status shows all nodes off
  → verify: bootstrap-state.kv is gone (renamed to .bak.*)
```

Repeat. The second cycle tests that the state left by teardown is identical to
the initial clean state, and that A1 re-discovers the BMC correctly without a
cached state file.

### 3.2  Flash cycle

```
bootstrap --phase A --flash download --manifest images-manifest.kv
  → verify: nodes boot to fresh Ubuntu image
  → verify: hostname is 'ubuntu' (pre-A5 state) on each node
  → continue with A4–A7 via --from A4

teardown
```

Tests the real `tpi flash` path end-to-end including the download+SHA256 chain.
Only needs to run once per image version bump.

### 3.3  Rediscover after IP drift

```
# After a standard bootstrap cycle, simulate DHCP reassignment:
#   - Disconnect the switch / WiFi briefly to force DHCP lease renewal, OR
#   - Manually remove the static DHCP reservations in the router, power-cycle nodes

bootstrap --rediscover
  → verify: bootstrap-state.kv updated with new IPs
  → verify: /etc/hosts updated with new IPs
  → verify: ssh rk1-node{1..4} still works

teardown
```

### 3.4  Teardown with stale IPs  (T1 scan path)

After a DHCP reassignment (same setup as 3.3) run teardown **without** running
`--rediscover` first, so T1 must locate nodes by subnet scan rather than stored
IP:

```
teardown --password <current-pass>
  → verify: T1 logs "did not respond — scanning" for at least one node
  → verify: teardown completes cleanly
```

---

## Coverage summary

| Path type | Count | Automated? |
|-----------|-------|-----------|
| CI dry-run (Suite 1) | 24 (incl. D21–D24 BMC flash-mode: auto-detect, explicit `BMC_SDCARD_DEV`, unknown-type die, missing-manifest die) | Yes — GitHub Actions on every push/PR |
| Mock / fault-injection (Suite 2) | 7 | Yes — GitHub Actions on every push/PR |
| Hardware verification (Suite 3) | 4 scenarios | Manual — run before significant merges |
| **Total automated** | **31** | |

### Paths not reachable without special tooling

| Path | Why unreachable |
|------|----------------|
| A1 nmap fails → manual IP prompt | Requires interactive TTY; not automatable |
| A4 node timeout (never appears) | Would need hardware fault simulation |
| T1 "no nodes found at all" → die | All nodes must be unreachable simultaneously |
| A0 upgrade real path | Requires live BMC + firmware file; manual only |

---

## Coverage gaps — Phase B, D, and RKNN

### Phase B shell scripts — no unit tests

**Scripts:** `scripts/install-k3s.sh`, `scripts/setup-registry.sh`,
`scripts/mount-ssd.sh`, and related helpers.

**Why not automated:** these scripts mutate live cluster state (install k3s,
configure containerd, format NVMe). Dry-run modes are not implemented. The
existing Suite 4 (`tests/check-cluster.sh`) validates the *result* of a Phase B
run (19 checks) but does not test the scripts themselves.

**Manual validation:**
```bash
# After any change to Phase B scripts, run Suite 4 against a live cluster:
./tests/check-cluster.sh
# Expect: 19/19 checks passing
```

**To improve:** add `--dry-run` flags to Phase B scripts (similar to Phase A's
Expect scripts) so output-matching tests can run without a real cluster.
(shellcheck static analysis is already enforced in CI.)

**Trigger for Suite 4:** any change to Phase B scripts; after a cluster rebuild.

---

### Phase D workloads — ownership boundary

Agent workloads are deliberately not deployed on this cluster: they belong to
whatever consumer sits upstream of the job queue (ADR-0028), and their tests
belong there too. What this repo does own and check: Ollama (deployed via
`install-ollama.sh`) and Prometheus + Grafana (D-04), currently validated
manually via the Grafana UI on the Tailnet plus `install-monitoring.sh
--verify` (a status printer, not an assertion — do not gate on its exit code).

---

### RKNN NPU inference — manual validation only

**What was validated:** Whisper medium on node1 — originally 2026-06-16 with
the naive decoder (`tagx/whisper-stt:rknn` image — encoder 10.4 s, decoder
238 s, no KV-cache), and re-validated 2026-08-14 end-to-end through
`charts/whisper/` with the SA-KV decoder (`rknn.decoder: sa-kv`, ~2.0 s/step,
fingerprint-verified cache delivery, correct real-audio transcript).

**Why not automated:** requires a running RK3588 node with RKNN models at
`/mnt/ssd/whisper-models/rknn/<model>/` and a `--privileged` container. No CI
runner can reach the cluster.

**Manual validation:**
```bash
# SSH to rk1-node1, then:
docker run --privileged \
  -v /mnt/ssd/whisper-models/rknn/medium:/models \
  -v /tmp/test.wav:/audio/test.wav \
  rk1-node1:5000/tagx/whisper-stt:rknn \
  python infer_rknn_sa_kv.py --audio /audio/test.wav --language sv --shim
# Expect: transcript printed; ~2 s/decode-step
```

**Trigger:** `librknnrt.so` version bump (version-coupling row in
`HARDWARE-FIRMWARE-ISSUES.md`); kernel or driver update; new model size;
after `tagx` container image rebuild. Judge cache delivery with tagx
`debug/fingerprint_cache_delivery.py`, never a bare cosine check.

---

### shellcheck — in CI since 2026-08-14

Enforced in `.github/workflows/ci.yml` (lint job) and locally via the
pre-commit hook. `scripts/bmc/*` additionally pass `shellcheck -s sh`
(BusyBox/POSIX target).
