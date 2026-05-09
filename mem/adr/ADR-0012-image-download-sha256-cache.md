# ADR-0012: Image Download with SHA256 Verification and Local Cache

**Status:** Accepted  
**Date:** 2026-05-09

## Context

Flashing RK1 nodes from downloaded OS images requires fetching multi-gigabyte files. Repeatedly downloading the same image across bootstrap cycles wastes time and bandwidth. At the same time, using a cached file without verification is a security risk — a corrupted or tampered file would be silently flashed.

## Decision

Implement a `download` flash mode (`--flash download`) with the following behaviour:

1. **Manifest-driven**: image URLs and expected SHA256 hashes are stored in `images-manifest.kv` (one entry per image type). Per-node image types are configurable (`IMAGE_N_TYPE`), so different nodes can be flashed from different manifest entries.

2. **Local cache**: downloaded images are stored in `./image-cache/` (configurable via `IMAGE_CACHE_DIR`). The cache key is the filename component of the URL.

3. **Verify before and after download**:
   - If the cached file exists: verify its SHA256. If it matches, skip the download. If it does not match, delete the file and re-download (handles stale/corrupted cache).
   - After every download: verify SHA256. If it does not match, delete the partial file and die with a MitM warning rather than proceeding to flash.

4. **Dry-run safe**: in `--dry-run` mode, report "cache hit" or "would download URL → cache" without touching any files or calling `tpi flash`.

## Consequences

**Positive:**
- Repeated bootstrap cycles do not re-download unchanged images
- Post-download mismatch is treated as a security event, not a silent failure
- Stale cache (e.g. image updated at same URL) is detected and self-heals on next run
- The same path is exercised whether the image is fresh or cached — no separate code paths

**Negative:**
- SHA256 in the manifest must be kept up to date when images are updated at the same URL
- Cache directory can grow large; no automatic eviction (operator manages it)

## Alternatives Considered

- **No caching**: re-download every run; safe but slow for large images
- **Verify only after download**: would not detect a corrupted cached file from a previous interrupted download
- **Trust cached files without verification**: faster but allows silent flash of corrupted data
- **Use a checksumming download tool (e.g. `aria2c`)**: adds a dependency not available everywhere; `curl` + `sha256sum` are standard
