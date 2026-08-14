# GitOps (B-04)

This directory is the platform repo Flux reconciles against, per [ADR-0005](../docs/adr/ADR-0005-gitops-for-phase-b-and-beyond.md).

## Structure

- `flux-system/` — the bootstrap `GitRepository` + `Kustomization` that point Flux at this repo and at `apps/`. Applied once via `flux install` + `kubectl apply -f gitops/flux-system/gotk-sync.yaml`; Flux reconciles it continuously from here on.
- `apps/` — where workload manifests (Kustomize overlays, `HelmRelease` CRs) go. Flux prunes anything removed from here, so nothing should be added that isn't meant to be cluster-managed.

## Adding a workload

Add a `HelmRelease` + `HelmRepository` (or plain Kustomize manifests) under `apps/`, reference it from `apps/kustomization.yaml`, commit, push. Flux picks it up on the next reconcile (default interval: 5m, or force with `flux reconcile kustomization flux-system`).

## What's intentionally not here yet

The registry, k3s itself, Tailscale, and NVMe/StorageClass setup were installed directly via the Phase B shell scripts (`bootstrap-phase-b.sh`), not through Flux — migrating an existing Helm release into Flux's management ownership needs `kubectl annotate`/`label` steps to avoid Flux fighting the existing release, and is being tracked as a deliberate follow-up rather than done as part of the initial B-04 install.

## Credentials

Flux authenticates to this repo via a dedicated, read-only SSH deploy key stored as the `tpi-bro-repo` secret in the `flux-system` namespace — not a personal access token. The key has no write access and is scoped to this repo only.
