# ADR-0013: Offline CI Test Strategy (file:// URLs + Stub `tpi` Binary)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The bootstrap script's most important non-trivial paths — image download, SHA256 verification, cache hit/miss handling, MitM detection — run in real (non-dry-run) mode and call two external systems: the network (via `curl`) and the BMC (via `tpi`). Running these paths in CI without real hardware or external network requires both to be replaced with controllable substitutes.

Options considered:

- **Unit-test the TCL procs in isolation**: possible but requires a TCL test framework; doesn't exercise the full argument→stage→proc flow
- **Mock at the OS level**: intercept `exec` calls inside Expect; complex and fragile
- **Dependency injection in the script**: pass fake `curl`/`tpi` paths as config; intrusive
- **Filesystem-level substitution**: use `file://` URLs for downloads; inject a stub binary into `$PATH` for `tpi`

## Decision

Use two complementary substitutions, applied only in Suite 2 (mock/fault-injection) tests:

1. **`file://` URLs in test manifests**: `curl` supports `file://` URLs natively. Test manifests point at locally-generated files under `$TMP`. No external network, no mocking — the real `curl` code path runs, just against local files.

2. **Stub `tpi` binary at `tests/fixtures/bin/tpi`**: a short shell script placed at the front of `$PATH` that returns plausible output for `tpi info` (mock version string) and exits 1 for `tpi flash` and `tpi firmware`. The script never hangs or prompts for credentials.

Together these let the download→verify→cache→flash pipeline run to completion in CI: download and SHA256 checks succeed or fail as designed, and the stub `tpi` provides a clean "reached the flash call" signal (exit 1 is `expect_rc: any` in the test harness).

Test fixtures live in `tests/fixtures/`. The dummy image is generated at test time via `dd` and its SHA256 computed dynamically, so manifests are always consistent without a committed binary file.

## Consequences

**Positive:**
- The real `curl` and `sha256sum` code paths execute — no mocking at the library level
- All seven mock test paths (M01–M07) run fully offline in GitHub Actions
- No changes to the production script — PATH injection is external
- The stub is simple enough to read in 10 lines; no hidden behaviour

**Negative:**
- `file://` URLs do not exercise DNS resolution, TLS, HTTP redirect handling, or real download speeds
- The stub `tpi` does not validate flag syntax — it exits 1 regardless of arguments
- Real BMC upgrade path (A0 upgrade mode) remains untestable in CI; covered by hardware Suite 3 only

## Alternatives Considered

- **httpd on localhost**: serves real HTTP, but requires starting a background process and managing port conflicts in CI
- **WireMock / similar HTTP mock**: heavyweight, adds a Java/Node dependency
- **Mocking `exec` in TCL**: would require modifying the production script
