# ADR-0015: Expect Stops at A7 — Phase B+ Is GitOps Only

**Status:** Accepted  
**Date:** 2026-05-10

## Context

The bootstrap tooling uses Expect (Tcl) to automate interactive tasks that have no API: BMC power cycling, first-boot SSH login, password changes, node discovery, and initial Docker registry setup. Expect is the right tool for these because they require terminal interaction and cannot be driven by declarative config.

The question is: where does Expect stop and where does the cluster's permanent management model begin?

## Decision

**Expect handles Phase A only. Phase B and everything after is Helm/Kustomize + GitOps (Argo CD or Flux). No Expect is used inside the running cluster.**

The exact boundary:

| Belongs to Expect (Phase A) | Belongs to GitOps (Phase B+) |
|---|---|
| BMC power cycling | k3s workload management |
| First SSH login / password change | Registry Helm chart |
| Hostname assignment | Agent deployments |
| Node IP discovery | ConfigMaps / Secrets |
| Bring up bare Docker registry (A7) | Ingress / networking rules |
| BMC firmware check / upgrade | StorageClasses / PVCs |

The cluster is considered **bootstrapped** once:
- All nodes have a hostname and working SSH
- `registry:2` is reachable on port 5000 (Phase A registry, HTTP)

At that point Expect's job is done. Everything after bootstrap is committed to git and reconciled by the GitOps controller.

## Rationale

**Why not extend Expect into Phase B?**

Using Expect to `kubectl apply`, patch Secrets, or configure k3s would create snowflake cluster states — actions taken at the terminal that are not reproducible from code. Drift between what was applied and what is in git would emerge immediately.

**Why Helm/Kustomize + GitOps instead?**

- Promotions between environments (dev → staging → prod) become pull requests, not manual commands
- The cluster state is always derivable from a git commit
- Argo CD/Flux reconcile continuously — manual drift gets corrected automatically
- "Rerun Expect = fresh cluster baseline. Sync GitOps = workloads deployed." The system is reproducible from bare metal up through workloads

**Why bash scripts for Phase B setup (not Expect)?**

Phase B setup scripts (`install-k3s-server.sh`, `install-ca.sh`, etc.) are idempotent bash. Expect is only needed to feed SSH passwords interactively. Once SSH keys and passwordless sudo are configured (a B0 prerequisite), plain `ssh`/`scp`/`kubectl` replace all Expect wrappers entirely.

The intended end state: `make all` (bash + kubectl + helm) to set up Phase B from a clean Phase A cluster.

## Consequences

**Positive:**
- Phase A script has a hard scope limit — it never needs to know about workloads
- Cluster state is always representable as git commits; rollback = `git revert`
- Argo CD/Flux handle Day 2 operations (upgrades, rollbacks, drift correction) without operator involvement

**Negative:**
- Phase B requires learning Helm and either Argo CD or Flux in addition to the Expect/bash tooling
- Until SSH keys are set up, Phase B setup scripts still need a thin Expect wrapper (`run-remote.exp`) to feed passwords

## Notes

This boundary was explicitly articulated in the design material: *"Run Expect once to bootstrap hardware → everything else is GitOps."*

The `run-remote.exp` script (minimal SSH+sudo password wrapper) is explicitly a **temporary** tool to be discarded once SSH keys are distributed to all nodes.
