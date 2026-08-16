# ADR-0032 — Prebuilt model artifacts: bytes on a model hub, trust anchored in git

**Date:** 2026-08-16
**Status:** Accepted (implementation tracked as W-04)

---

## Context

Converting Whisper models to RKNN needs an x86 host, the closed-source
vendor toolkit, and hours per model; most users of this repo will want
prebuilt `.rknn` binaries (0.7–1.8 GB each). Distributing multi-GB
binaries raises two separate questions that are easy to conflate: where
the *bytes* live, and where the *trust* lives. A checksum file sitting
next to a download on the same server proves nothing — whoever can
tamper with the file can tamper with the checksum beside it.

Alternatives considered for the bytes: GitHub Releases (2 GB/file cap —
fits, but release assets on a bootstrap-scripts repo are a weak home and
undiscoverable as models), and self-hosting on a personal site (bandwidth
cost per download, no resume support, and — counterintuitively — *less*
trustworthy: a small personal server is an easier compromise target, and
cautious users rightly refuse multi-GB binaries from personal domains).

## Decision

- **Bytes: Hugging Face Hub.** Purpose-built for multi-GB model binaries
  (free bandwidth, LFS with per-blob sha256, resumable downloads) and
  where users already look for converted model artifacts. RKNN artifacts
  are pinned to runtime + SoC, so names carry both (e.g.
  `*-rknnrt2.3.2-rk3588.rknn`). Whisper is MIT-licensed; redistribution
  of derivatives is clean.
- **Trust: SHA-256 hashes pinned in a committed manifest in this repo,
  verified at fetch time** by whatever pulls the model (chart init
  container / fetch script). The repo the user already cloned is an
  independent channel from the download host — with fetch-time
  verification, the bytes may come from *any* mirror and a tampered file
  simply fails.
- **Web pages link and display the pinned hashes; they never serve the
  bytes.** A third channel for manual cross-checking, zero hosting
  liability.

## Consequences

- Publishing a model means: upload artifacts + manifest to the HF repo,
  commit the SHA-256s here, and the fetch path enforces the rest. No
  mirror is ever trusted on its own.
- Hash pinning makes model updates *visible* in git history — swapping an
  artifact requires a commit, which is the point.
- Scope at first release: medium and large-v3 (both hardware-validated).
- The verification step must fail closed: a missing or mismatched hash
  aborts the deploy rather than warning.

## Related

- `../backlog/BACKLOG.md` W-04 — the implementation item
- ADR-0012 — SHA256 download cache for OS images (the same
  verify-what-you-fetch principle at the bootstrap layer)
- ADR-0021 — self-signed CA for the registry (in-cluster image trust)
