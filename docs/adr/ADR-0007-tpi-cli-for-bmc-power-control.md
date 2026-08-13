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

## Implementation note (updated 2026-05-10)

The original implementation used `exec tpi --host $BMC_HOST ...` from the laptop. This was found to hang in practice: `tpi --host` without prior web-UI authentication waits on stdin for credentials, blocking the Expect script indefinitely.

**All `tpi` invocations were moved to run on the BMC itself via SSH** (`bmc_cmd` proc). The script SSHes to `root@$BMC_HOST` and runs `tpi power …` / `tpi flash …` there. The `tpi` binary on the BMC communicates with `bmcd` over localhost and requires no external authentication.

This means:
- `tpi` does **not** need to be installed on the operator's laptop (though it can still be used manually for ad-hoc commands)
- All script-driven BMC calls go through `bmc_cmd` / `bmc_stream` (streaming variant with PTY for progress bars)
- The `--host` flag on the laptop-side `tpi` binary is effectively unusable without prior web-UI login

Default BMC host: `turingpi.local`. Set `BMC_HOST` in `bootstrap-config.kv` if mDNS is unreliable. A1 pins the BMC IP in `/etc/hosts` so subsequent runs do not depend on mDNS.
