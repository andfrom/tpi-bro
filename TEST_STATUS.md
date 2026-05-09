# tpi-bro — Test Status & Coverage Map

_Last updated: 2026-05-09_

## Current state

**No automated tests exist yet.** A-04 in the backlog tracks the CI dry-run work.
All verification to date has been manual. This document defines what a full
verification run looks like, organises the 21 identified test paths into three
suites, and records what remains untestable without special tooling.

**BMC firmware installation is not covered and not scripted.** `tpi firmware`
commands exist in the tpi CLI but are not called anywhere in this repo.
Phase B / C / D are not implemented and therefore not testable.

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
    │   └── invalid FLASH_MODE ───────────────────────── die ✗
    │
    ├── A4  power_on_and_discover
    │   └── per node
    │       ├── node already in state ──────────────── skip
    │       ├── dry ────────────────────────────────── print plan
    │       ├── node appears within 150 s
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
  ├── BMC firmware flashing  (tpi firmware upgrade)
  ├── Phase B  k3s install + persistent registry
  ├── Phase C  resilience + laptop mirror
  └── Phase D  multi-agent workloads
```

---

## Suite 1 — CI dry-run  (17 paths, no hardware required)

These should all pass in GitHub Actions. None of them touch real hardware, make
network requests to external servers, or require `sudo`. They verify that every
stage emits the expected dry-run output and that all error paths die with a
useful message.

Run the whole suite with:

```bash
./tests/run-dry-run-suite.sh
```

| # | Command | Branch(es) exercised |
|---|---------|----------------------|
| D01 | `bootstrap --dry-run --phase A` | A1 no-state, A2, A3 skip, A4 no-state, A5, A6 no-IPs-warning, A7 |
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
| D12 | `bootstrap --config valid-test.kv --dry-run --phase A` | config file loaded; values applied |
| D13 | `bootstrap --config /nonexistent.kv` | missing config → die |
| D14 | `bootstrap --dry-run --from BOGUS_STAGE` | unknown stage → die |
| D15 | `teardown --dry-run` *(state file present)* | T1–T8 all stages |
| D16 | `teardown --dry-run` *(no state file)* | T1 scan-only path + T8 no-op |
| D17 | `teardown --dry-run --keep-hostname --remove-docker` | T3 extended cmds + T5 skipped |

---

## Suite 2 — Mock / fault injection  (no hardware required)

These run the scripts in **real (non-dry-run) mode** but against fabricated local
inputs, so no TuringPi is needed. They exercise the error paths that dry-run
cannot reach because those paths only trigger after a real operation.

All mocks use files under `tests/fixtures/`.

| # | Setup | Command | Expected outcome |
|---|-------|---------|-----------------|
| M01 | `tests/fixtures/dummy.img` (1 MB zeros) + manifest with **correct** SHA256 | `bootstrap --flash download --manifest ...` *(real mode, no hardware — script dies at tpi flash call, not before)* | Download + verify succeed; script fails later at `tpi flash` (not a test failure) |
| M02 | Same dummy image already in `image-cache/` with correct SHA256 | Same as M01 | Cache hit logged; SHA256 OK; script proceeds to `tpi flash` |
| M03 | Same dummy image in cache but **contents corrupted** (SHA256 wrong) | Same | "SHA256 mismatch — re-downloading" logged; file deleted; fresh download attempted |
| M04 | Manifest pointing at a **404 URL** | `bootstrap --flash download --manifest ...` *(real mode)* | `curl` fails; die with "Download failed" message |
| M05 | Manifest with mismatched SHA256 for a real downloadable file | `bootstrap --flash download --manifest ...` | Download succeeds; SHA256 check fails; die with MitM warning; cache file deleted |
| M06 | `tests/fixtures/bootstrap-config.kv` with `SUBNET=10.99.0.0/24` | `bootstrap --dry-run --phase A` | Dry-run output shows `10.99.0.0/24` (config loaded correctly) |
| M07 | State file with `bmc_ip=192.168.1.1` | `bootstrap --dry-run --phase A` | A1 logs "already known at 192.168.1.1" (state-restore path) |

M01–M05 require network access for the download tests (M04/M05) or are fully
offline (M01–M03, M06–M07). None require the TuringPi board.

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
| CI dry-run (Suite 1) | 17 | TODO (A-04) — should run in GitHub Actions |
| Mock / fault-injection (Suite 2) | 7 | TODO — runnable offline or with network only |
| Hardware verification (Suite 3) | 4 scenarios | Manual — run before significant merges |
| **Total** | **28** | |

### Paths not reachable without special tooling

| Path | Why unreachable |
|------|----------------|
| A1 nmap fails → manual IP prompt | Requires interactive TTY; not automatable |
| A4 node timeout (never appears) | Would need hardware fault simulation |
| T1 "no nodes found at all" → die | All nodes must be unreachable simultaneously |
| BMC firmware installation | Not scripted; out of scope for Phase A |
