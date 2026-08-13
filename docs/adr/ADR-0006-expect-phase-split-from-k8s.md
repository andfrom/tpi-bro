# ADR-0006: Hard Boundary Between Expect Bootstrap and K8s Orchestration

**Status:** Accepted  
**Date:** 2026-05-09

## Context

Early design explored using Ansible post-bootstrap or running `kubectl` commands from the Expect script. Both approaches blur the line between "get the machine to a usable state" and "configure the machine declaratively."

## Decision

Draw a hard boundary: **Expect handles everything before k3s is running. K8s/GitOps handles everything after.**

Expect exits after Phase A (nodes have hostnames, SSH passwords are set, `/etc/hosts` is updated, ephemeral registry is running). It does not install k3s, does not apply manifests, and does not touch containerd config.

k3s install and all subsequent configuration is done via a separate Phase B script or manual steps, and from that point Argo CD / Flux manages the cluster state.

## Consequences

**Positive:**
- Clear mental model: "rerun Expect = fresh baseline; sync GitOps = workloads deployed"
- Prevents accumulation of imperative state inside the cluster
- Makes teardown/reinstall straightforward — rerun Phase A only

**Negative:**
- Phase B (k3s install) is currently not automated — operator must run it manually or via a separate script
- The gap between "Phase A done" and "GitOps running" is a manual grey zone

## Notes

The teardown workflow should mirror this boundary: Phase A teardown resets nodes to factory state; Phase B teardown deletes k3s. These should be separate operations.
