# ADR-0010: Static DHCP Reservations for Node IP Stability

**Status:** Accepted  
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

**Primary recommendation: static DHCP reservations in the router.** This is the only approach that prevents drift entirely without relying on scripts.

The bootstrap script supports this by:
- Extracting each node's MAC address from the laptop's ARP table after SSH discovery in A4
- Extracting the BMC MAC address in A1
- Printing a DHCP reservation table at the end of A4 with all MACs and suggested IPs
- Storing MACs in `bootstrap-state.kv` for future reference

The operator configures these bindings in their router once. After that, IPs are stable across every power cycle.

**Fallback: `--rediscover` mode.** For networks where the operator does not control the DHCP server (managed office WiFi, guest networks), the bootstrap script's `--rediscover` flag scans the subnet and identifies nodes by their SSH hostname. It updates both the state file and `/etc/hosts` with the current IPs. No power cycling, no password changes required.

## Consequences

**Positive (reservations):**
- IPs are stable forever — no script intervention needed after initial setup
- `kubectl`, SSH, and image push all work reliably after power cycles
- Teardown + re-bootstrap always produces consistent IPs

**Positive (`--rediscover` fallback):**
- Works on any network including those without operator access to the DHCP server
- Identifies nodes by identity (SSH hostname), not by stored IP — correct even if all IPs changed simultaneously

**Negative:**
- DHCP reservation setup is a manual operator step (router UI — not scriptable in a portable way)
- `--rediscover` requires nodes to be powered on and SSH-accessible; does not help if nodes are powered off

## Notes

The MAC table printed by A4 looks like:
```
DHCP reservation summary — configure in your router for stable IPs:
  rk1-node1  MAC=xx:xx:xx:xx:xx:xx  →  <current DHCP IP>
  rk1-node2  MAC=xx:xx:xx:xx:xx:xx  →  <current DHCP IP>
  ...
  turingpi (BMC)  MAC=xx:xx:xx:xx:xx:xx  →  <current DHCP IP>
```

Include the BMC in the DHCP reservation so `turingpi.local` in `/etc/hosts` stays accurate after router reboots. Actual MACs and IPs are operator-specific and stored in `bootstrap-state.kv` (gitignored).
