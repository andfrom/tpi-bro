# ADR-0011: Config File (`bootstrap-config.kv`) with CLI Flag Override

**Status:** Accepted  
**Date:** 2026-05-09

## Context

As the bootstrap script grew to support flash modes, per-node image paths, BMC firmware options, and other tuneable parameters, it became impractical to expect operators to edit the Expect script directly. The script's config block is TCL, not user-friendly, and editing it risks accidental syntax breakage. At the same time, a single global config is not enough — one operator may run against multiple clusters, or want to track per-cluster settings separately from the script itself.

## Decision

Support a `bootstrap-config.kv` file (key=value, one per line, `#` comments) that is auto-loaded from the working directory if present. Additional files can be passed via `--config FILE` (repeatable). CLI flags always win over file values.

Implementation uses two-pass argument parsing:

1. **Pass 1** — scan `argv` for `--config` flags and load them in order; also auto-load `./bootstrap-config.kv` if it exists and was not already specified
2. **Pass 2** — scan `argv` again and apply CLI flag overrides on top of whatever the config files set

All tuneable variables — including `IMAGE_1` through `IMAGE_4` (per-node image paths) and `IMAGE_1_TYPE` through `IMAGE_4_TYPE` — are settable from the config file, so a full cluster setup can be expressed in a single file without any CLI flags beyond `--phase A`.

`bootstrap-config.kv` is gitignored. `bootstrap-config.kv.example` documents every key and ships in the repo.

## Consequences

**Positive:**
- Operators never need to edit the script itself
- Per-cluster config is tracked alongside the cluster (or separately, outside the repo)
- Config can be composed: a base file plus a per-environment override file
- All existing tests pass; config loading is covered by D12, D13, M06, M07

**Negative:**
- Two-pass parsing adds some complexity; order-of-precedence must be understood (file first, CLI wins)
- Key names in the KV file must exactly match the internal TCL variable names

## Alternatives Considered

- **Edit the script**: what existed before; not user-friendly and error-prone
- **Environment variables only**: no file persistence; inconvenient for cluster-specific settings
- **YAML/TOML config**: would require a parser not available in stock TCL/Expect; overkill for a flat key-value set
