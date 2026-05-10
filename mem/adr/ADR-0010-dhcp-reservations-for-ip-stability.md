# ADR-0010: Static IPs for Node IP Stability

**Status:** Accepted (updated 2026-05-10 — DHCP reservation approach superseded)  
**Date:** 2026-05-09

## Context

The bootstrap script discovers node IPs dynamically during A4 (power on one-by-one, detect new IP via subnet delta scan). These IPs are written to `bootstrap-state.kv` and `/etc/hosts`.

DHCP does not guarantee stable IPs. After a power cycle, network interruption, or router reboot, the same node may receive a different IP. This breaks:
- SSH access via hostname (the `/etc/hosts` entry points at the old IP)
- `kubectl` connectivity if the node's IP changes after joining the cluster
- The state file becomes inconsistent with reality

Three approaches were considered for handling IP drift:

1. **Static IPs configured on each node** (`/etc/netplan/`): portable but fragile across OS reflashes; requires SSH to each node to configure
2. **Static DHCP reservations in the router** (MAC→IP binding): router assigns the same IP every time, regardless of power cycle or OS state; zero node-side configuration
3. **Accept drift; scan to rediscover**: use hostname-based identification (SSH fingerprint) to find nodes after IPs change; update `/etc/hosts` and state

## Decision

**Implemented: static IPs configured on each node via netplan.**

The router in use (Icotera i4882-73) does not expose a DHCP reservation UI. Static DHCP reservations are therefore not possible on this network.

IP assignment scheme (configured via `TPI_BASE_IP_ADDR` in `bootstrap-config.kv`):
| Host       | IP                      |
|------------|-------------------------|
| BMC        | TPI_BASE_IP_ADDR        |
| rk1-node1  | TPI_BASE_IP_ADDR + 1    |
| rk1-node2  | TPI_BASE_IP_ADDR + 2    |
| rk1-node3  | TPI_BASE_IP_ADDR + 3    |
| rk1-node4  | TPI_BASE_IP_ADDR + 4    |

Pick a base address below the router's DHCP pool start so there is no conflict. Actual IPs are operator-specific and not committed to the repo.

`setup-static-ips.sh` automates the netplan configuration across all 4 nodes. It writes `/etc/netplan/99-static.yaml` (priority 99 overrides cloud-init's default DHCP config), applies it, verifies connectivity at the new IP, and updates `bootstrap-state.kv` and `/etc/hosts`.

The BMC IP is left as DHCP. The TuringPi 2 BMC runs BusyBox armv7l and does not expose IP configuration through its web UI. The BMC IP is only needed for Phase A power control; Phase B uses only node IPs. If the BMC IP drifts, `turingpi.local` (mDNS) or a quick `nmap` scan will locate it, and `bootstrap-state.kv` can be updated manually.

**Fallback: `--rediscover` mode.** For ad-hoc situations where IPs drift (e.g., re-flash without running `setup-static-ips.sh`), the bootstrap script's `--rediscover` flag scans the subnet and identifies nodes by SSH hostname, then updates the state file and `/etc/hosts`.

## Consequences

**Positive:**
- IPs are stable across power cycles once netplan config is applied
- `kubectl`, SSH, and image push all work reliably
- Memorable scheme (.10 = BMC, .11–.14 = nodes 1–4)
- `setup-static-ips.sh` is fully automated — runs once after Phase A

**Negative:**
- Netplan config is lost on OS re-flash; `setup-static-ips.sh` must be re-run after any re-flash
- DHCP reservation approach (the original design) would have survived re-flash automatically — not available on this router

## Notes

A4 still prints a MAC/IP table (originally intended for router DHCP reservation entry). On this network it serves as a record of each node's MAC address, stored in `bootstrap-state.kv` (gitignored).

After any re-flash cycle, the sequence is:
1. Run Phase A bootstrap (A1–A7) — nodes get fresh DHCP IPs
2. Run `setup-static-ips.sh` — configures static IPs and updates state file
3. Continue with Phase B

`setup-static-ips.sh` and the BMC web UI step are documented in the Phase B0 section of `TODO.md`.
