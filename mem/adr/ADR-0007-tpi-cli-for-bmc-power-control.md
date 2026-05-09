# ADR-0007: Use `tpi` CLI for BMC Power Control (Not BMC Web UI)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The TuringPi 2 BMC (Baseboard Management Controller) exposes both a web UI and a REST-based CLI (`tpi`) for power management of RK1 modules. The Expect bootstrap script needs to power cycle nodes programmatically.

## Decision

Use the `tpi` CLI tool (installed on the operator's laptop) for all power control in the bootstrap script. The `tpi` binary communicates with the BMC at `turingpi.local` (mDNS) or a specified IP.

Key commands used in this repo:
- `tpi power on -n NODE` — power on single node (1-indexed)
- `tpi power off -n NODE` — power off single node
- `tpi power off` — power off all nodes
- `tpi flash -n NODE --image-path FILE` — flash an image file to a node
- `tpi flash -n NODE --local` — flash from BMC-local storage
- `tpi firmware --file FILE` — upgrade BMC firmware
- `tpi info` — query BMC version and board info

## Consequences

**Positive:**
- Single tool, consistent interface for all BMC operations
- Works over WiFi (mDNS) and Ethernet — confirmed working over WiFi by operator
- Credentials cached after first login
- No need to scrape the BMC web UI

**Negative:**
- `tpi` must be installed on the operator's laptop (not on nodes themselves)
- mDNS (`turingpi.local`) may fail if Ethernet cable is not connected and WiFi mDNS propagation is inconsistent on the LAN
- The `tpi` binary is not open source — behavior may change with firmware updates

## Notes

All power and flash calls are implemented as real `exec {*}$args` Expect calls. A2 calls `tpi power off`, A4 calls `tpi power on -n N` per node, A3 (download/image modes) calls `tpi flash -n N --image-path FILE`, and A0 (upgrade mode) calls `tpi firmware --file FILE` followed by a BMC reboot wait.

Default BMC host: `turingpi.local`. If mDNS fails before A1 has run, set `BMC_HOST` in `bootstrap-config.kv` or pass `--host` explicitly. A1 pins the BMC IP in `/etc/hosts` so subsequent runs and teardown do not depend on mDNS.
