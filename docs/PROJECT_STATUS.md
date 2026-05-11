# tpi-bro — Project Status

_Last updated: 2026-05-11 (B-09 NVMe mount + local-ssd StorageClass — done)_

## Summary

tpi-bro bootstraps a TuringPi 2 board (4× RK1 ARM64 compute modules) from bare metal to a Kubernetes-ready cluster state. The project is split into a one-time imperative Phase A (Expect script) and a declarative Phase B+ (k3s + GitOps).

---

## Phase A — Bootstrap (Expect Script)

**Overall: COMPLETE** (all stages implemented, tested, and committed)

| Stage | Name | Status | Notes |
|-------|------|--------|-------|
| A0 | bmc_firmware | Done | BMC version check/upgrade; dry-run-safe; controlled by `--bmc-firmware skip\|check\|upgrade` |
| A1 | find_bmc | Done | nmap scan + manual fallback; pins `turingpi.local` in `/etc/hosts`; extracts BMC MAC |
| A2 | poweroff_all | Done | Real `tpi power off` via exec; no artificial sleeps |
| A3 | flash_optional | Done | Five modes: `skip` / `local` / `image` / `download` / `bmc`; SHA256 verification + local cache for download mode; `bmc` mode downloads directly to BMC SD card (avoids large laptop upload) |
| A4 | power_on_and_discover | Done | Real `tpi power on -n N`; delta-based IP discovery; MAC extraction; DHCP reservation summary |
| A5 | name_password_reboot | Done | Sets hostname + password via SSH; event-driven reboot wait |
| A6 | write_hosts_on_laptop | Done | Appends node IP↔hostname to `/etc/hosts` via bootstrap-host-helper.sh |
| A7 | ephemeral_registry_phaseA | Done | Docker registry:2, HTTP, port 5000, restart=always |

**`--rediscover` mode:** Done — scans subnet, identifies nodes by SSH hostname, updates state + `/etc/hosts`. No power cycling.

**Config file support:** Done — `--config FILE` (or auto-load `bootstrap-config.kv`); CLI flags override file values; all tuneable vars exposed. See `bootstrap-config.kv.example`.

**Teardown script (`teardown-cluster.exp`):** Done — T1–T8 stages; DHCP-resilient node location in T1; graceful poweroff + tpi hard-off in T7; symmetric `/etc/hosts` cleanup in T6.

**Automated tests:** Done — `tests/run-ci.sh` (27 tests, Suites 1+2, no hardware); `tests/run-hardware.sh` (Suite 3, cluster cycles). CI runs on every push/PR via GitHub Actions (`.github/workflows/ci.yml`).

---

## Phase B — k3s + Persistent Registry

**Overall: B0–B9 COMPLETE; D-01 (Ollama) + D-02 (Agent A) DONE**

Phase B is entirely shell scripts + Helm/GitOps — **no Expect stages**. The Expect script's job ends at A7.

| Step | What | Script | Status |
|------|------|--------|--------|
| B0-static-ips | Static IPs on BMC + all nodes; netplan on Ubuntu, ifupdown on BMC | `setup-static-ips.sh` | **Done** 2026-05-09 |
| B0-ssh | SSH key auth + passwordless sudo on all nodes | `setup-ssh-keys.sh` | **Done** 2026-05-09 |
| B1-k3s | k3s v1.35.4+k3s1 server on node1 + agents on nodes 2–4 | `install-k3s.sh` | **Done** 2026-05-09 |
| B1-kubeconfig | Laptop kubeconfig at `~/.kube/config` | `install-k3s.sh --kubeconfig` | **Done** 2026-05-09 |
| B2-certs | TLS cert + self-signed CA (SAN: hostname + static IP) | `gen-registry-certs.sh` (via `setup-registry.sh`) | **Done** 2026-05-11 |
| B2-registry | Helm chart deployed; HostPort 5000 on node1; PVC local-path 50Gi | `setup-registry.sh` | **Done** 2026-05-11 |
| B2-ca | CA distributed to all 4 nodes; `registries.yaml` mirror configured; services restarted | `install-ca.sh` (via `setup-registry.sh`) | **Done** 2026-05-11 |
| B2-laptop | Laptop Docker CA trust automated (idempotent; restarts Docker only when cert changes) | `setup-registry.sh` | **Done** 2026-05-11 |
| B2-verify | `docker push` + `docker pull` from laptop verified end-to-end | `setup-registry.sh --verify` | **Done** 2026-05-11 |
| B2-auth | Registry basic auth (`auth.enabled=true` + htpasswd Secret from `~/.turingpi/credentials.kv`) | `setup-registry.sh --enable-auth` | **Done** 2026-05-11 |
| B2-pod-pull | k3s pod on rk1-node3 pulled `rk1-node1:5000/test:latest` in 505ms via containerd mirror | `kubectl run test-pull …` | **Done** 2026-05-11 |
| B3-ssd | Mount NVMe SSD on nodes 1–3; `local-ssd` StorageClass; registry PVC migrated to SSD | `mount-ssd.sh` + `setup-registry.sh --migrate-pvc` | **Done** 2026-05-11 |
| B4-gitops | Argo CD or Flux install + platform repo structure | — | Not started |
| B5-metallb | MetalLB for stable registry VIP | — | Not started |
| D-01-ollama | Ollama on each NVMe node; one release per node; 200Gi PVC local-ssd | `install-ollama.sh` | **Done** 2026-05-11 |
| D-02-agent-a | `sibling-app` Agent A Deployment in namespace `sibling-app`; ClusterIP on 18090; arm64 cross-build via QEMU | `deploy-agent-a.sh` | **Done** 2026-05-11 |

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
  password (the password set during Phase A). There is also a "Press Enter to
  confirm" gate before IP changes are applied.
- `setup-ssh-keys.sh` prompts for the Ubuntu node password again to distribute the
  SSH public key. After this step, key-based auth is in place and no further
  password prompts occur.

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

---

## Phase C — Resilience + Laptop Mirror

**Overall: NOT STARTED** (blocked on Phase B)

---

## Phase D — Multi-Agent Workloads

**Overall: D-01 + D-02 DONE**

---

## Hardware State (as of 2026-05-11)

Phase B complete (B0–B9). All 4 nodes running k3s v1.35.4+k3s1 with containerd 2.2.3. Persistent HTTPS registry on SSD. `local-ssd` StorageClass available cluster-wide.

| Node | Hostname | Static IP | Status |
|------|----------|-----------|--------|
| 1 | rk1-node1 | 192.168.1.11 | k3s server; HTTPS registry (auth enabled); 2TB NVMe mounted `/mnt/ssd`; labeled `storage.tpi-bro/nvme=true` |
| 2 | rk1-node2 | 192.168.1.12 | k3s agent; 2TB NVMe mounted `/mnt/ssd`; labeled `storage.tpi-bro/nvme=true` |
| 3 | rk1-node3 | 192.168.1.13 | k3s agent; 2TB NVMe mounted `/mnt/ssd`; labeled `storage.tpi-bro/nvme=true` |
| 4 | rk1-node4 | 192.168.1.14 | k3s agent; eMMC only (no NVMe); excluded from `local-ssd` provisioner |

Static IPs configured via netplan (nodes) + ifupdown (BMC). Persist across reboots. DHCP drift no longer a concern.

**BMC:** `turingpi.local` / `192.168.1.10` — accessible over WiFi.

IPs, MACs, and other operational details are in `bootstrap-state.kv` (gitignored) and `~/.turingpi/`.

---

## Immediate Next Steps

1. **N-01 Layer 3: Tailscale operator** — expose services by name on the Tailnet (`agent-a.<tailnet>.ts.net`); requires OAuth client in `~/.turingpi/credentials.kv`.
2. **D-00: PriorityClass + ResourceRequests** — add `interactive`/`background` PriorityClasses and resource requests/limits to all agent and Ollama Deployments.
3. **D-04: Observability** — Prometheus + Grafana; needed to tune resource requests meaningfully.
4. **MetalLB (B-05 / C-01)** — stable registry VIP; removes the HostPort-forced node1 pin.

See `docs/DEPLOYMENT_STATUS.md` for the full current cluster state and `mem/backlog/BACKLOG.md` for the ordered backlog.
