# tpi-bro — Project Status

_Last updated: 2026-05-11 (B-07 auth, B-08 pod pull — done)_

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

**Overall: B0–B2 + B-07 + B-08 COMPLETE**

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
| B3-ssd | Mount NVMe SSD on all nodes; move registry PVC from eMMC to SSD (blocker for Ollama) | `scripts/mount-ssd.sh` (TBD) | **Next** |
| B4-gitops | Argo CD or Flux install + platform repo structure | — | Not started |
| B5-metallb | MetalLB for stable registry VIP | — | Not started |

### Running Phase B2

```bash
./scripts/setup-registry.sh                # full deploy (idempotent; also handles CA distribution + laptop Docker trust)
./scripts/setup-registry.sh --enable-auth  # B-07: create htpasswd secret + helm upgrade with auth.enabled=true
./scripts/setup-registry.sh --verify       # test authenticated push/pull from laptop
```

Credentials are in `~/.turingpi/credentials.kv` (mode 600, gitignored). `--enable-auth` reads `REGISTRY_USER` / `REGISTRY_PASSWORD` from that file.

Prerequisite: `helm` must be installed on the laptop (see `docs/PREREQUISITES.md`). All other steps are automated including laptop Docker CA trust and containerd mirror config on all nodes.

---

## Phase C — Resilience + Laptop Mirror

**Overall: NOT STARTED** (blocked on Phase B)

---

## Phase D — Multi-Agent Workloads

**Overall: NOT STARTED** (blocked on Phase B)

---

## Hardware State (as of 2026-05-11)

Phase B2 complete. All 4 nodes running k3s v1.35.4+k3s1 with containerd 2.2.3. Persistent HTTPS registry deployed and verified.

| Node | Hostname | Static IP | Status |
|------|----------|-----------|--------|
| 1 | rk1-node1 | 192.168.1.11 | k3s server; persistent HTTPS registry running (auth enabled); Phase A Docker container removed |
| 2 | rk1-node2 | 192.168.1.12 | k3s agent |
| 3 | rk1-node3 | 192.168.1.13 | k3s agent |
| 4 | rk1-node4 | 192.168.1.14 | k3s agent |

Static IPs configured via netplan (nodes) + ifupdown (BMC). Persist across reboots. DHCP drift no longer a concern.

**BMC:** `turingpi.local` / `192.168.1.10` — accessible over WiFi.

IPs, MACs, and other operational details are in `bootstrap-state.kv` (gitignored) and `~/.turingpi/`.

---

## Immediate Next Steps

1. **B-09: Mount NVMe SSDs** on all nodes and move the registry PVC from eMMC (`local-path`) to SSD. **Blocker for Ollama deployment.** See `mem/backlog/BACKLOG.md` B-09 for commands.
2. **Ollama deployment** — one instance per node, weights on local SSD, nodeSelector pinning.
3. **GitOps controller** — Argo CD or Flux; platform repo structure. User confirmed this should happen before returning to `sibling-app`.
4. **`sibling-app` Agent A deployment** — initial agent Deployment on node1 after GitOps is in place.

See `docs/DEPLOYMENT_STATUS.md` for the full current cluster state and `mem/backlog/BACKLOG.md` for the ordered backlog.
