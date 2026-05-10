# tpi-bro — Project Status

_Last updated: 2026-05-10_

## Summary

tpi-bro bootstraps a TuringPi 2 board (4× RK1 ARM64 compute modules) from bare metal to a Kubernetes-ready cluster state. The project is split into a one-time imperative Phase A (Expect script) and a declarative Phase B+ (k3s + GitOps).

---

## Phase A — Bootstrap (Expect Script)

**Overall: COMPLETE** (all stages implemented, tested, and committed)

| Stage | Name | Status | Notes |
|-------|------|--------|-------|
| A0 | bmc_firmware | Done | BMC version check/upgrade; dry-run-safe; controlled by `--bmc-firmware skip\|check\|upgrade` |
| A1 | find_bmc | Done | nmap scan + manual fallback; pins `turingpi.local` in `/etc/hosts`; extracts BMC MAC |
| A2 | poweroff_all | Done | Real `tpi power off` via exec; no artificial sleeps |
| A3 | flash_optional | Done | Five modes: `skip` / `local` / `image` / `download` / `bmc`; SHA256 verification + local cache for download mode; `bmc` mode downloads directly to BMC SD card (avoids large laptop upload) |
| A4 | power_on_and_discover | Done | Real `tpi power on -n N`; delta-based IP discovery; MAC extraction; DHCP reservation summary |
| A5 | name_password_reboot | Done | Sets hostname + password via SSH; event-driven reboot wait |
| A6 | write_hosts_on_laptop | Done | Appends node IP↔hostname to `/etc/hosts` via bootstrap-host-helper.sh |
| A7 | ephemeral_registry_phaseA | Done | Docker registry:2, HTTP, port 5000, restart=always |

**`--rediscover` mode:** Done — scans subnet, identifies nodes by SSH hostname, updates state + `/etc/hosts`. No power cycling.

**Config file support:** Done — `--config FILE` (or auto-load `bootstrap-config.kv`); CLI flags override file values; all tuneable vars exposed. See `bootstrap-config.kv.example`.

**Teardown script (`teardown-cluster.exp`):** Done — T1–T8 stages; DHCP-resilient node location in T1; graceful poweroff + tpi hard-off in T7; symmetric `/etc/hosts` cleanup in T6.

**Automated tests:** Done — `tests/run-ci.sh` (27 tests, Suites 1+2, no hardware); `tests/run-hardware.sh` (Suite 3, cluster cycles). CI runs on every push/PR via GitHub Actions (`.github/workflows/ci.yml`).

---

## Phase B — k3s + Persistent Registry

**Overall: NOT STARTED**

- k3s install on node1 (server): not started
- k3s install on nodes 2–4 (workers): not started
- containerd registry mirror config: not started
- Persistent registry via Helm (`registry-chart/` exists, not deployed): not started
- CA cert generation + distribution: `gen-registry-certs.sh` exists, not run
- End-to-end push/pull test: not done

---

## Phase C — Resilience + Laptop Mirror

**Overall: NOT STARTED** (blocked on Phase B)

---

## Phase D — Multi-Agent Workloads

**Overall: NOT STARTED** (blocked on Phase B)

---

## Hardware State (as of 2026-05-10)

Phase A fully validated on 2026-05-10 with Ubuntu 24.04.1 LTS (joshua-riek/ubuntu-rockchip v2.4.0) via `--flash bmc`. All 4 nodes bootstrapped end-to-end in ~1 hour (52 min flash + 8 min A4–A7).

| Node | Hostname | Status |
|------|----------|--------|
| 1 | rk1-node1 | Phase A complete; Docker 29.4.3 + registry:2 running |
| 2 | rk1-node2 | Phase A complete |
| 3 | rk1-node3 | Phase A complete |
| 4 | rk1-node4 | Phase A complete |

IPs, MACs, and other operational details are in `bootstrap-state.kv` (gitignored) and `~/.turingpi/`.

**BMC:** `turingpi.local` — accessible over WiFi.

**⚠ DHCP reservations not yet configured.** All 4 node IPs drift on every reboot. Use `./bootstrap-turingpi-cluster.exp --rediscover` after any power cycle until static reservations are set in the router (MACs available from `bootstrap-state.kv` or from A4 output).

---

## Immediate Next Steps

1. **DHCP reservations** — configure MAC→IP bindings in router for all 4 nodes (see Hardware State table above); prerequisite for stable Phase B operation
2. **Hardware cycle** — run `./tests/run-hardware.sh --cycles 2` on the live cluster to confirm Phase A end-to-end
3. **B-01**: Install k3s on node1 (server role)
4. **B-02**: Join nodes 2–4 as k3s workers
5. **B-03**: Configure containerd registry mirror on all nodes
6. **B-04**: Deploy persistent registry via `registry-chart/`
