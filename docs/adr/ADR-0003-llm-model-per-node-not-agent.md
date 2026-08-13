# ADR-0003: One LLM Model Per Node (Not One Agent Per Node)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The cluster has 4× RK1 modules with 32 GB RAM each. A realistic application (e.g., the `sibling-app` agent framework) may have 7 or more agents. Naively requiring one agent per node would cap the system at 4 simultaneously-running agents — unnecessarily restrictive.

The actual constraint is at the model level, not the agent level: **a single LLM's weight tensor must reside in contiguous address space on one physical machine**. It cannot be split across nodes. But multiple agent processes can share a node as long as their combined memory demand fits.

## Decision

**The scheduling unit is the LLM model, not the agent process.**

- Each distinct LLM model is pinned to one node via Kubernetes `nodeSelector` or `nodeName`.
- Multiple agent services that share the same Ollama instance (or the same loaded model) can all run on that node.
- Agent services that are lightweight wrappers (FastAPI + HTTP calls to a local Ollama) have a small memory footprint and can be co-located freely.
- Services with no LLM dependency (API gateway, vector DB, queues, observability) are scheduled normally by the K8s scheduler.

For `sibling-app` specifically: if 7 agents all call one Ollama server running a single model, all 7 can target the same node. If they use distinct models, each model is pinned to its own node and the agents follow their respective model.

## Consequences

**Positive:**
- No artificial 4-agent cap — many lightweight agent processes can share a node
- Model-level pinning is easy to express in K8s (`nodeSelector: kubernetes.io/hostname: rk1-node2`)
- Allows flexible growth: pack agents onto nodes until RAM becomes the bottleneck, then add a node (or use quantized models)

**Negative:**
- Multiple agents on one node compete for CPU and RAM — resource limits must be set carefully (see ADR-0008)
- If a node goes down, all agents on it go down together — a single-node failure is more impactful than in a distributed design

## Notes

Maximum usable RAM per node for model + agent overhead: ~28–30 GB (32 GB minus OS and system daemons).

If a model requires more than that, quantization (e.g., 4-bit) is the first lever. Cross-node model sharding is not supported by Ollama/llama.cpp on ARM64 at this scale.
