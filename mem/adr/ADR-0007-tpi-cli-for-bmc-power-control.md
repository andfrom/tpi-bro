# ADR-0007: Use `tpi` CLI for BMC Power Control (Not BMC Web UI)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The TuringPi 2 BMC (Baseboard Management Controller) exposes both a web UI and a REST-based CLI (`tpi`) for power management of RK1 modules. The Expect bootstrap script needs to power cycle nodes programmatically.

## Decision

Use the `tpi` CLI tool (installed on the operator's laptop) for all power control in the bootstrap script. The `tpi` binary communicates with the BMC at `turingpi.local` (mDNS) or a specified IP.

Key commands:
- `tpi power on -n NODE` — power on single node (1-indexed)
- `tpi power off -n NODE` — power off single node
- `tpi power off` — power off all nodes
- `tpi power reset -n NODE` — hard reset (use sparingly)
- `tpi flash` — flash firmware to a node

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

The A2 (poweroff_all) and A4 (power_on_and_discover) stages currently contain placeholder `tpi` calls. These should be replaced with real `exec tpi power ...` Expect calls, wrapping the output in `expect` to confirm success before proceeding.

Default BMC host: `turingpi.local`. Override with `--bmc-host` flag if mDNS fails.
