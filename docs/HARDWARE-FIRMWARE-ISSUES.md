# Hardware & Firmware Issues (RK3588 / TuringPi RK1)

Single index of outstanding hardware- and firmware-level issues on this
cluster's compute path — device access quirks, driver/runtime coupling,
silicon-level limits. Each row links to the full write-up rather than
duplicating it; update this table when a new one is found or an existing one
changes status, but keep the detail in the linked doc.

Out of scope here: general cluster bootstrap/network quirks (BMC discovery,
mDNS, first-boot password reset) — those are in `OPERATIONS.md`'s own
"Known Issues" section. This page is compute-hardware/firmware only.

| Issue | Status | Impact | Workaround / Fix | Details |
|---|---|---|---|---|
| RKNN container access requires `--privileged` | Accepted — won't fix short-term | All RKNN (NPU) workloads run privileged; not acceptable for multi-tenant or long-running daemons | None — `--device` allowlisting is blocked on an unresolved closed-source runtime issue (SoC auto-detection breaks once `/sys` masking is lifted). Acceptable for this single-tenant, batch-only cluster. | `adr/ADR-0023-rknn-npu-device-access-pattern.md` |
| NPU device node was mis-identified (`renderD128`/`129` assumed) | Resolved | Blocked writing an explicit device allowlist | Confirmed the NPU actually opens its own primary DRM node, `/dev/dri/card1` — not either render node. Doesn't unblock de-privileging (see row above) but closes the "which device" unknown. | `adr/ADR-0023-rknn-npu-device-access-pattern.md` (2026-08-14 update) |
| RKNN decoder can't handle `language: auto` | Mitigated | A Job left at the CPU-path default silently burns ~10 s of NPU encode time, then crashes at decode start | `charts/whisper/`'s Helm template now fails fast at `helm template`/`install` time if `rknn.enabled` + `language: auto` are combined. The underlying limitation is permanent: the RKNN decoder is a fixed-shape greedy loop that needs the language token before decoding starts — no auto-detect pass, unlike the CPU (faster-whisper) path. | `charts/whisper/templates/job.yaml`; tagx `images/whisper-stt/rknn/infer_rknn.py` |
| INT8 quantization produces empty/garbage output on RK3588 | Open — blocked upstream ([airockchip/rknn_model_zoo#314](https://github.com/airockchip/rknn_model_zoo/issues/314), filed 2025-04-16, zero maintainer response as of 2026-08-14) | INT8 is unusable for Whisper on this hardware; FP16 mandatory (slower, more memory) | Root-caused to the attention softmax/SDPA path (per-layer cosine collapses 0.98→0.79 across blocks; not a calibration-data issue). Hybrid workaround in progress: keep attention in FP16, quantize only the FFN to INT8. | `RKNN-INT8-WHISPER-314.md` (includes a vendor-response tracker) |
| CMA pool exhaustion on large-v3 KV inference (246 MB requested > ~213 MB free) | Fixed | large-v3's KV-cache decoder OOM'd the RK3588's reserved CMA pool | A redundant `.astype(np.float32)` cast on the FP32 model's output was silently triggering an FP16 conversion buffer allocation — v2.3.2's runtime already returns float32 natively. Removing the cast fixed it. | tagx `images/whisper-stt/rknn/PIPELINE.md` §Known issues |
| `librknnrt.so` / `rknpu.ko` version coupling is undocumented and not protocol-stable | Operational constraint — no fix, must maintain by discipline | A version mismatch doesn't error cleanly: it produces wrong output or job timeouts (`RKNPU: failed to wait job`), which can escalate to a hard NPU reset or kernel panic + reboot | Pin `librknnrt.so` to the exact `rknn-toolkit2` version used at model-conversion time everywhere (currently `2.3.2` across the fleet). An earlier concern that `2.3.2` itself panics on driver `0.9.7` was not reproduced on further testing (2026-06-17) — the real constraint is version *consistency*, not this specific pairing. | `NPU-MODELS.md`; tagx `docs/adr/0002-rknn-container-conventions.md` §17 |

## See also

- `RKNN-INT8-WHISPER-314.md` — deep-dive on the INT8 issue above
- `NPU-CHARACTERIZATION.md` / `NPU-DATASHEET.md` — measured device constants, not issues
- `adr/ADR-0023-rknn-npu-device-access-pattern.md` — the container-access decision record
- tagx `images/whisper-stt/rknn/PIPELINE.md` — full conversion-pipeline known-issues table (includes dev-tooling issues like ONNX export OOM on the conversion laptop, which are out of scope here since they don't affect deployed cluster hardware)
- `OPERATIONS.md` — cluster bootstrap/network known issues (non-compute)
