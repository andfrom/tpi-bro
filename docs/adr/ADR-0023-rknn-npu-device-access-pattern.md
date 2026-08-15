# ADR-0023 — RKNN NPU Device Access Pattern

**Date:** 2026-06-16  
**Status:** Accepted

---

## Context

The RK3588 NPU (RKNPU v2, 6 TOPS) is the primary accelerator on RK1 nodes.
Running RKNN-accelerated workloads in containers requires the container to access
the NPU device. We need a documented, reproducible access pattern.

**Observed state (kernel 6.1.0-1025-rockchip, 2026-06-16):**

- `CONFIG_ROCKCHIP_RKNPU=y` — NPU driver compiled into the kernel (not a module)
- `CONFIG_ROCKCHIP_RKNPU_DRM_GEM=y` — NPU is registered via the DRM subsystem
- `/dev/rknpu` does **not** exist — DRM GEM mode does not create this node
- `/dev/dri/renderD128` and `/dev/dri/renderD129` exist
- `/dev/mpp_service` exists (Rockchip MPP, separate from NPU)
- `/proc/device-tree/npu@fdab0000/status` = "okay" — NPU DT node is enabled
- `dmesg` shows no RKNPU probe messages (driver probes silently in DRM GEM mode)
- RKNN Driver version: 0.9.7 (reported by rknn-toolkit-lite2 at runtime)
- librknnrt.so version: 2.3.2

**librknnrt.so is not installed on nodes by default.** It is not bundled in
the `rknn-toolkit-lite2` pip wheel. It must be provided separately.

---

## Decision

### 1. Container access: `--privileged` (device node now confirmed, but not sufficient alone)

**Update 2026-08-14 — device node confirmed.** The NPU runtime opens
**`/dev/dri/card1`** (its own primary DRM card node), not either
`renderD12x` render node — the "`renderD128` vs `renderD129`" framing in
the original decision below was the wrong dichotomy. Knowing the device
does *not* unblock de-privileging: the closed-source runtime additionally
requires Docker-masked `/sys` paths and fails SoC auto-detection without
full `--privileged` (investigation details in
`../HARDWARE-FIRMWARE-ISSUES.md`, first two rows).

**Decision: keep `--privileged` for RKNN workloads.** It reliably works
end-to-end — validated 2026-08-14 by running the actual `charts/whisper/`
Helm chart's Job (`rknn.enabled: true`) on rk1-node1 with a real model
(`medium`) and real audio, producing a correct transcript. Revisit
least-privilege only if this cluster ever becomes multi-tenant; until then
the security cost is acceptable for the same reason batch jobs already
accept it (single-tenant, no long-running daemons).

```yaml
securityContext:
  privileged: true   # /dev/dri/card1 confirmed; least-privilege blocked on
                      # unresolved vendor runtime SoC auto-detection, see above
```

### 2. librknnrt.so: bake into container image at build time

The RKNN C runtime (`librknnrt.so`) must be present at `/usr/lib/librknnrt.so`
inside the container. Options:

| Approach | Pros | Cons |
|---|---|---|
| Bake into image (curl at build) | Self-contained, no host dependency | Version pinned at build time |
| Mount from host (`-v`) | Host version always used | Requires host install step |
| Install via apt/package | Cleanest if ever packaged | Not currently available |

**Decision: bake into the image.** The `tagx/whisper-stt:rknn` image downloads
`librknnrt.so` from the Rockchip GitHub at build time. This keeps the image
self-contained and avoids requiring a host install step for each node.

Source URL (pin to version tag when stable releases appear on GitHub):
```
https://github.com/airockchip/rknn-toolkit2/raw/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so
```

**Risk:** URL points to `master` branch, not a versioned release. When
rknn-toolkit2 publishes tagged releases with assets, switch to a pinned URL.

### 3. NPU capability detection: device tree model string, not `/dev/rknpu`

ADR-0022 (E-02) originally said to detect RK3588 NPU by `/dev/rknpu`. This is
wrong for the DRM GEM kernel build on this cluster. Updated detection:

```bash
# RK3588 NPU presence: check device tree model
cat /proc/device-tree/model | grep -qi "RK1" && echo "rk3588"

# Jetson: check for CUDA device nodes
ls /dev/nvidia* 2>/dev/null && echo "jetson-orin-nano"
```

### 4. No `/dev/rknpu` references in charts or scripts

Do not reference `/dev/rknpu` in any Helm chart device mounts, `--device` flags,
or bringup scripts. It does not exist on this cluster. The real device is
`/dev/dri/card1`, and `--privileged` remains required as above.

---

## Consequences

- All RKNN containers currently run `--privileged`; acceptable for dev/batch
- E-02 (capability label detection) must use DT model string, not `/dev/rknpu`
- `charts/whisper/` uses `privileged: true` — confirmed the actual device
  (`/dev/dri/card1`) 2026-08-14, but least-privilege is blocked on an
  unresolved vendor-runtime SoC auto-detection issue (see above), not on the
  device node itself. `rknn.devices` in `charts/whisper/values.yaml` stays
  empty until that's resolved.
- `librknnrt.so` version must be kept in sync with `rknn-toolkit-lite2` version
  in tagx Dockerfiles; both are 2.3.2 as of 2026-06-16
