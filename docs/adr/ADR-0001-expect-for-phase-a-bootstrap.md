# ADR-0001: Use Expect for Phase A (One-Time Imperative Bootstrap)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

Bootstrapping a bare-metal cluster requires steps that are fundamentally interactive and stateful: SSH into nodes with default credentials, change passwords, set hostnames, reboot, and discover new IPs. These operations involve fragile TTY interactions and timing-sensitive SSH handshakes that do not map cleanly to declarative tools.

Ansible, Terraform, and Kubernetes all assume the machine is already reachable in a predictable way. They cannot handle: "wait for the default ubuntu image to boot, then log in with the factory password and change it."

## Decision

Use [Expect](https://core.tcl-lang.org/expect/index) (TCL-based) for Phase A — the one-time, imperative bootstrap sequence that runs entirely from the operator's laptop.

Expect excels at driving interactive programs (SSH, serial consoles) and is standard on most Linux/macOS systems. The script is staged and resumable (`--from` / `--to` flags) so individual steps can be re-run after failures.

## Consequences

**Positive:**
- Can SSH into nodes with default credentials and handle interactive prompts
- Can wait for reboots and re-probe for new IPs
- No agent pre-installed on nodes (unlike Ansible which needs Python)
- Stages are isolated; failure in A5 doesn't force rerunning A1–A4

**Negative:**
- TCL/Expect syntax is niche — fewer contributors familiar with it
- Not easily unit-testable (drives real SSH sessions)
- State is persisted to a flat KV file (`bootstrap-state.kv`), not a proper database

## Alternatives Considered

- **Ansible**: Requires Python on nodes; cannot handle pre-credential-setup SSH dance
- **Bash + `ssh`**: Possible but more fragile for timing/retry logic; Expect's `expect`/`send` is built for this
- **Python + Paramiko**: Feasible but adds a heavyweight dependency for a one-time script
