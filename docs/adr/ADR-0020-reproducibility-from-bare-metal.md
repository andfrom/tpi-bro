# ADR-0020: Full Reproducibility from Bare Metal

**Status:** Accepted  
**Date:** 2026-05-10

## Context

A cluster that can only be restored by someone who remembers the manual steps taken to configure it is fragile. Nodes fail, OS images get corrupted, and configuration drifts away from intent over months of operation. If restoring the cluster requires tribal knowledge rather than code, the cluster is a liability.

## Decision

**If all four nodes are reflashed to a clean OS image, the full cluster state — including all workloads, configuration, and platform components — must be restorable by running the bootstrap script followed by a GitOps sync. No manual steps, no remembered commands, no "I think it was something like this."**

This is a correctness requirement, not a goal. Any cluster state that exists only in a running container, in a human memory, or in a one-off terminal session is a bug.

### What "reproducible" means concretely

| Layer | How state is captured |
|---|---|
| OS image | `images-manifest-bmc.kv` (URL + SHA256) |
| Node configuration (hostname, password, SSH, Docker) | `bootstrap-turingpi-cluster.exp` Phase A |
| Kubernetes cluster | k3s install scripts + `bootstrap.env` |
| Registry TLS + auth | `gen-registry-certs.sh` + secrets created from committed scripts (CA key stored in `~/.turingpi/`, never in git) |
| All workloads | Helm charts / Kustomize manifests in the platform git repo |
| Workload configuration | ConfigMaps and Secrets in git (secrets via SealedSecrets/SOPS) |

### What this does not cover (by design)

- **Stateful data inside running workloads**: vector DB contents, model weight caches, agent session history. These are data, not configuration — they are rebuilt or restored from separate backup mechanisms. The *capability* to re-ingest or re-pull this data must be scripted, but the data itself is not committed to git.
- **The CA private key** (`myCA.key`): stored in `~/.turingpi/` on the operator's laptop. If lost, regenerate the CA and redistribute — the procedure is scripted.

## Rationale

**The cluster is infrastructure, not state.** Treat nodes as cattle: if one fails, reflash and rejoin. If all fail, reflash all four and resync GitOps. The only irreplaceable things are the git repositories and the CA private key — both of which are already backed up off-device by nature (git remotes) or explicit procedure.

**Reproducibility enforces discipline in automation.** The requirement that everything is scriptable prevents the accumulation of manual workarounds. Each workaround that gets applied "just this once" is either added to the bootstrap script (making it permanent) or acknowledged as technical debt.

**Operational confidence.** Knowing the cluster can be rebuilt from scratch in under two hours means planned maintenance (OS upgrades, hardware swaps) is not feared. A cluster that cannot be rebuilt is a cluster that never gets maintained.

## Consequences

**Positive:**
- Full rebuild is possible at any time; hardware failures are a minor inconvenience, not a crisis
- The bootstrap script and GitOps repo are the authoritative documentation of the cluster state
- Drift is detectable: `git diff` between desired and actual state (via GitOps reconciliation)

**Negative:**
- Every configuration change must be committed to a repo or script before being applied — no "quick fixes" that stay unfiled
- Stateful data (vector DB, model caches) requires a separate, explicit backup and restore strategy — this project does not yet provide one

## Relationship to other ADRs

- ADR-0015 (Expect/GitOps boundary): defines where each tool's responsibility for reproducibility begins and ends
- ADR-0005 (GitOps): the mechanism by which workload state is captured and reproduced
