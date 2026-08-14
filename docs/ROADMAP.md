# tpi-bro — Roadmap

_Last updated: 2026-08-14_

## Summary

tpi-bro bootstraps a TuringPi 2 board (4× RK1 ARM64 compute modules) from bare metal to a Kubernetes-ready cluster state. The project is split into a one-time imperative Phase A (Expect script) and a declarative Phase B+ (k3s + GitOps).

This file tracks what's ahead. For what's already built, see git history and commit messages — same convention as `backlog/BACKLOG.md`. For current live cluster state (versions, what's actually running right now), see `docs/OPERATIONS.md`.

---

## Phase A — Bootstrap (Expect Script)

Complete. Usage: `docs/GETTING-STARTED.md`, `./scripts/bootstrap-turingpi-cluster.exp --help`.

## Phase B — k3s + Persistent Registry

Complete through B4-gitops. Open: **B5-metallb** (stable registry VIP, removes the HostPort-forced node1 pin — see `backlog/BACKLOG.md`).

### Running Phase B (orchestrated)

The preferred way to run Phase B is the orchestrator, which runs all stages in
order with `--from`/`--to` resume support and `--dry-run`:

```bash
# Dry-run — print every action, touch nothing
./scripts/bootstrap-phase-b.sh --dry-run

# Full run: B0 (static IPs + SSH keys) → B1 (k3s) → B2 (registry + auth + verify)
./scripts/bootstrap-phase-b.sh

# Resume after a failure
./scripts/bootstrap-phase-b.sh --from B2_registry

# Run full suite and finish with the 10-check health test
./scripts/bootstrap-phase-b.sh --check
```

**Interactive prompts (B0 only):**
- `setup-static-ips.sh` prompts for the BMC root password and the Ubuntu node
  password (the password set during Phase A) unless both are already set in
  `bootstrap-config.kv` (`BMC_PASS`, `NEW_PASS`). There is also a "Press Enter to
  confirm" gate before IP changes are applied, skippable with `--yes`.
- `setup-ssh-keys.sh` prompts for the Ubuntu node password again to distribute the
  SSH public key, same config fallback. After this step, key-based auth is in
  place and no further password prompts occur.

All stages from B1 onward are fully non-interactive.

### Running individual Phase B scripts

Individual scripts remain usable when you need to re-run a single step:

```bash
./scripts/setup-registry.sh                # full B2 deploy (idempotent)
./scripts/setup-registry.sh --enable-auth  # create htpasswd secret + upgrade with auth.enabled=true
./scripts/setup-registry.sh --verify       # test authenticated push/pull from laptop
./scripts/install-ca.sh <node-ip>          # re-distribute CA to one node
```

Every Phase B script supports `--dry-run`.

Credentials are in `~/.turingpi/credentials.kv` (mode 600, gitignored). `--enable-auth` reads `REGISTRY_USER` / `REGISTRY_PASSWORD` from that file.

Prerequisite: `helm` must be installed on the laptop (see `docs/PREREQUISITES.md`). All other steps are automated including laptop Docker CA trust and containerd mirror config on all nodes.

### Cluster health check (Suite 4)

```bash
./tests/check-cluster.sh          # 14 checks: nodes Ready, registry, TLS, auth, push, per-node pull, storage
./tests/check-cluster.sh --quick  # skip pod-pull checks (C07–C10); still runs storage checks C11–C14
```

Exit 0 only if all enabled checks pass.

## Phase C — Resilience + Laptop Mirror

Not started (blocked on Phase B). See `backlog/BACKLOG.md` (C-01 through C-03).

## Phase D — Multi-Agent Workloads

Ollama, Agent A, and monitoring are not currently deployed — sibling-app's agents are intentionally kept off this cluster, and monitoring hasn't been redeployed alongside them. See `docs/OPERATIONS.md` for the reasoning and current state.

## NPU / Whisper

Whisper `medium` inference on the RK3588 NPU already works (see `docs/NPU-MODELS.md`, `adr/ADR-0023-rknn-npu-device-access-pattern.md`). Open work is tracked in `backlog/BACKLOG.md` under **Whisper STT** (W-03) and **NPU Characterization** (NC-01–NC-03) — not duplicated here.

---

## Immediate Next Steps

1. **W-03: KV-cache decoder** — split Whisper decoder into cross-attention KV encoder (once) + per-token autoregressive decoder; expected ~100× speedup for NPU decoding.
2. **NPU device node (E-02)** — confirm which `/dev/dri/renderD*` node the RKNN runtime uses; replace `--privileged` with explicit device mount.
3. **large-v3 RKNN conversion** — next model in priority table after medium validated.
4. **D-00: PriorityClass + ResourceRequests** — add `interactive`/`background` PriorityClasses and resource requests/limits to all agent and Ollama Deployments.
5. **B5-metallb** — stable registry VIP; removes the HostPort-forced node1 pin.

See `docs/OPERATIONS.md` for hardware inventory, access methods, and current cluster state, and `backlog/BACKLOG.md` for the ordered backlog.
