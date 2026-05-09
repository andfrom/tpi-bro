# tpi-bro — Project Status

_Last updated: 2026-05-09_

## Summary

tpi-bro bootstraps a TuringPi 2 board (4× RK1 ARM64 compute modules) from bare metal to a Kubernetes-ready cluster state. The project is split into a one-time imperative Phase A (Expect script) and a declarative Phase B+ (k3s + GitOps).

---

## Phase A — Bootstrap (Expect Script)

**Overall: COMPLETE** (all stages implemented and committed)

| Stage | Name | Status | Notes |
|-------|------|--------|-------|
| A1 | find_bmc | Done | nmap scan + manual fallback |
| A2 | poweroff_all | Done (stub) | `tpi power off` — placeholder, works but not fully integrated |
| A3 | flash_optional | Done (stub) | USB/web flash stubs; skip is default |
| A4 | power_on_and_discover | Done | Powers on nodes one-by-one, discovers IPs |
| A5 | name_password_reboot | Done | Sets hostname + password via SSH |
| A6 | write_hosts_on_laptop | Done | Fixed; uses bootstrap-host-helper.sh |
| A7 | ephemeral_registry_phaseA | Done | Docker registry:2, HTTP, port 5000, restart=always |

**Known issues / open items:**
- A2/A4 use `tpi power` via shell exec but not fully wrapped with `expect` output confirmation
- Teardown script not yet written (backlog item A-02)

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

## Hardware State (as of 2026-05-09)

| Node | Hostname | IP | Status |
|------|----------|----|--------|
| 1 | rk1-node1 | 192.168.1.115 (known) | Phase A complete; Docker registry running |
| 2 | rk1-node2 | unknown (DHCP) | Phase A complete |
| 3 | rk1-node3 | unknown (DHCP) | Phase A complete |
| 4 | rk1-node4 | unknown (DHCP) | Phase A complete |

**BMC:** `turingpi.local` — mDNS reachable over WiFi (confirmed). Ethernet cable currently not connected to laptop; BMC accessible via WiFi.

---

## Immediate Next Steps

1. **A-01**: Replace `tpi_power` stubs with real `tpi` CLI calls
2. **A-02**: Write teardown script (resolve open questions first — see backlog)
3. **B-01**: Install k3s on node1
4. **B-02**: Join nodes 2–4 as workers
5. **B-03**: Configure containerd mirrors
6. **B-04**: Deploy persistent registry via `registry-chart/`
