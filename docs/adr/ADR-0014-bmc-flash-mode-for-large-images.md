# ADR-0014: `--flash bmc` Mode — Download and Flash Images via the BMC

**Status:** Accepted  
**Date:** 2026-05-10

## Context

The `--flash download` mode downloads images to the operator's laptop, verifies SHA256, and then uploads to each node via `tpi flash --image-path FILE`. For a 4-node cluster with ~4 GB images per node, this requires uploading ~16 GB from the laptop to the BMC over WiFi — slow and error-prone.

The TuringPi BMC has:
- A MicroSD card slot accessible at `/mnt/sdcard/`
- `curl` installed (for downloading files on the BMC itself)
- `xzcat` for decompression
- `tpi flash --local --image-path FILE` for flashing from BMC-local storage

## Decision

Add a `--flash bmc` mode that avoids the laptop upload entirely:

1. SSH to BMC; verify SD card is mounted at `/mnt/sdcard/`
2. Prompt to delete any stale images on the SD card that are not needed for this run
3. For each distinct image type in the manifest:
   - If the decompressed `.img` already exists on the SD card and SHA256 matches, reuse it
   - Otherwise: `curl` the `.xz` directly on the BMC to the SD card
   - Verify SHA256 of the `.xz` on the BMC
   - `xzcat` to decompress in-place; delete the `.xz` after success
4. Flash each node with `tpi flash -n NODE --local --image-path /mnt/sdcard/…`

The manifest format (`images-manifest-bmc.kv`) mirrors `images-manifest.kv` with the same `type.url`, `type.sha256`, `type.description` keys.

## Consequences

**Positive:**
- No large upload from laptop — image is downloaded once to BMC SD card at full internet speed
- 4 nodes can be flashed sequentially from the single SD card copy (~10 min each)
- SHA256 verified on BMC before decompress — catches corrupt downloads early
- Stale-image cleanup prevents SD card from filling up across multiple OS version changes
- Progress bar visible (via SSH PTY `-tt` flag on the `curl` and `tpi flash` calls)

**Negative:**
- Requires a MicroSD card to be physically inserted in the BMC
- SD card capacity must exceed the uncompressed image size (~4–5 GB for Ubuntu RK1)
- If the BMC reboots mid-download, the SD card must be remounted manually before re-running
- `xzcat` decompression on the BMC RK3588 takes ~10 min for a 4 GB image (single-threaded)

## Observed timings (2026-05-10, Ubuntu 24.04.1 LTS, 4.19 GiB image)

| Step | Duration |
|------|----------|
| `curl` download (`.xz`, ~1.5 GB) | 2m 9s |
| SHA256 verify on BMC | 1m 30s |
| `xzcat` decompress | 9m 29s |
| `tpi flash --local` × 4 nodes | ~10m each (40m total) |
| **Total A3** | **52m 49s** |

## Notes

- The `--flash bmc` mode is selected via `FLASH_MODE=bmc` in `bootstrap-config.kv` or `--flash bmc` on the CLI
- The manifest file for this mode defaults to `images-manifest-bmc.kv`; override with `--manifest FILE`
- Image types in the manifest use `default` as the standard type name; per-node overrides use `IMAGE_N_TYPE` in config
