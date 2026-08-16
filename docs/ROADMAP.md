# tpi-bro — Roadmap

_Last updated: 2026-08-16_

## Summary

tpi-bro bootstraps a TuringPi 2 board (4× RK1 ARM64 compute modules) from bare metal to a Kubernetes-ready cluster state. The project is split into a one-time imperative Phase A (Expect script) and a declarative Phase B+ (k3s + GitOps).

This file tracks what's ahead. For what's already built, see git history and commit messages — same convention as `backlog/BACKLOG.md`. For current live cluster state (versions, what's actually running right now), see `docs/OPERATIONS.md`.

---

## Phase A — Bootstrap (Expect Script)

Complete. Usage: `docs/GETTING-STARTED.md`, `./scripts/bootstrap-turingpi-cluster.exp --help`.

## Phase B — k3s + Persistent Registry

Complete through B4-gitops. (B5-metallb was dropped 2026-08-15: every job it would do is already covered or moot — service exposure is the Tailscale operator's, the registry is pinned to node1 by its *storage* regardless of any VIP, node IPs are already static, and the ADR-0028 queue boundary rides the Tailscale-routed ClusterIP. Revisit only per the note in backlog C-01.)

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

# Run full suite and finish with the 19-check health test
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
./tests/check-cluster.sh          # 19 checks: nodes, registry+TLS+auth+pull, storage, labels, priorities, Tailscale, job queue
./tests/check-cluster.sh --quick  # skip pod-pull checks (C07–C10); still runs storage checks C11–C14
```

Exit 0 only if all enabled checks pass.

## Phase C — Resilience + Laptop Mirror

Not started (blocked on Phase B). See `backlog/BACKLOG.md` (C-01 through C-03).

## Phase D — Multi-Agent Workloads

Ollama (D-01) and monitoring (D-04) are running, redeployed 2026-08-14 after
the Phase A reflash wiped the original 2026-05-11 deployment. Agent
workloads (D-02) are intentionally not deployed — agent workloads belong to
whatever consumer sits upstream of the job queue (ADR-0028) and are kept off
this cluster; see `docs/OPERATIONS.md` for the reasoning and current state.

## NPU / Whisper

Whisper `medium` inference on the RK3588 NPU already works (see `docs/NPU-MODELS.md`, `adr/ADR-0023-rknn-npu-device-access-pattern.md`). Open work is tracked in `backlog/BACKLOG.md` under **Whisper STT** (W-04/W-05) and **NPU Characterization** (NC-01–NC-03) — not duplicated here.

---

## Immediate Next Steps

1. **Open-source release** — audit executed (leak sweep, docs, testing
   gaps, CHANGELOG, history rewrite); remaining: purge-request
   confirmation, version tag, flip.

(W-05 closed 2026-08-16 with a retraction: the "rknn_init runaway" was a
test-harness memory bug; large-v3 SA-KV is fully validated on hardware —
`docs/RKNN-SA-KV-DECODER-BUG.md` §Postscript.)

(Self-healing shipped 2026-08-15/16: on-SoC hardware watchdogs + a
BMC-resident node watchdog with ssh + deep probes, validated by
deliberately crashing/hanging live nodes; see `docs/SELF-HEALING.md`.)

(W-03 KV-cache decoder: done 2026-08-14 — root-caused, fixed via the input
shim, productionized into `charts/whisper/` at ~2.5× the naive decoder.
D-00 resource policy: fully re-applied 2026-08-15 after the reflash —
PriorityClasses + LimitRanges live, with the LimitRange's CPU default limit
removed after it was found to block Ollama pod creation outright.)

(NPU device node confirmed 2026-08-14 — it's `/dev/dri/card1`, not a `renderD*`
node. `--privileged` stays regardless: the vendor runtime's own SoC
auto-detection breaks once container masking is lifted, unrelated to which
device is named. See `adr/ADR-0023-rknn-npu-device-access-pattern.md`.)

See `docs/OPERATIONS.md` for hardware inventory, access methods, and current cluster state, and `backlog/BACKLOG.md` for the ordered backlog.
