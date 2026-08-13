# ADR-0005: GitOps (Argo CD or Flux) for Phase B and Beyond

**Status:** Accepted  
**Date:** 2026-05-09

## Context

After Phase A, the cluster has stable hostnames, SSH access, and an ephemeral registry. From this point, all workload management should be declarative and version-controlled. Manual `kubectl apply` commands create snowflake state and drift.

The operator's workflow is: build image on laptop → push to cluster registry → commit manifest change to Git → cluster reconciles automatically.

## Decision

Use a GitOps controller (Argo CD or Flux — specific choice deferred to Phase B implementation) to continuously reconcile cluster state from a Git repository.

Workloads are described as Helm charts or Kustomize manifests committed to a "platform repo" (this repo or a separate one). Promotions between environments are pull requests, not `kubectl` commands.

The Phase B persistent registry itself is deployed this way once k3s is running.

## Consequences

**Positive:**
- Full audit trail: every cluster change has a git commit
- Rollback = `git revert`; cluster converges automatically
- No manual `kubectl` in the steady state
- Compatible with standard CI/CD: build → push → commit → auto-deploy

**Negative:**
- Initial GitOps controller install is a manual bootstrap step (or Helm)
- Pull-based model means there's a reconciliation delay (typically 30–120s)
- Adds Argo CD / Flux as an operational dependency

## Alternatives Considered

- **Manual `kubectl apply`**: Fast for one-off changes; creates drift and no audit trail
- **Ansible**: Push-based; works but doesn't provide continuous reconciliation
- **Terraform**: Better for infrastructure provisioning than K8s workload management
