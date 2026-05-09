# ADR-0002: Use k3s Instead of Full Kubernetes

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The cluster consists of 4× RK1 compute modules (ARM64, RK3588 SoC). Each node has 32 GB RAM and ~10 W idle power draw. Total cluster memory is 128 GB. These are capable machines, but the use case is a personal/small-team AI workbench — not a production enterprise cluster.

Full Kubernetes (kubeadm) carries significant overhead: etcd + control plane components consume RAM and disk, and setup complexity is high. The cluster has no HA requirement (single-node control plane is acceptable).

## Decision

Use [k3s](https://k3s.io/) — a CNCF-certified, lightweight Kubernetes distribution from Rancher.

k3s ships a single binary that includes the API server, controller manager, scheduler, kubelet, and kube-proxy. It uses SQLite by default (no etcd needed for ≤3 nodes or single-server setups), uses containerd instead of Docker, and works well on ARM64.

Node 1 (`rk1-node1`) runs as the k3s **server** (control plane + worker). Nodes 2–4 run as **agents** (workers only).

## Consequences

**Positive:**
- Single binary install (`curl -sfL https://get.k3s.io | sh -`)
- SQLite default — no separate etcd needed for single-server setup
- ARM64 support is first-class
- Containerd built in — no separate Docker install on workers
- Compatible with standard `kubectl`, Helm, Argo CD, Flux

**Negative:**
- HA control plane requires embedded etcd or external DB — not needed now but limits future
- Some advanced features (e.g., cloud-provider integrations) not included
- SQLite has write serialization — not a concern at this scale

## Alternatives Considered

- **kubeadm + full K8s**: Too heavy; complex setup for a single-server personal cluster
- **MicroK8s**: Snap-based, less portable; k3s is simpler binary distribution
- **K0s**: Very similar to k3s; k3s chosen for wider adoption/docs
