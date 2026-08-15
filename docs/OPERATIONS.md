# tpi-bro — Operations

The single source of truth for current hardware, access methods, and credentials
format. For phase-by-phase progress and what's next, see [ROADMAP.md](ROADMAP.md).

_Last updated: 2026-08-16 (job queue + self-healing watchdogs added to the stack table; observability section corrected to Running)_

## Cluster Hardware

| Component | Detail |
|-----------|--------|
| Board | TuringPi 2 |
| Compute modules | 4× RK1 (RK3588 SoC, ARM64) |
| RAM per node | 32 GB LPDDR5 |
| Total cluster RAM | 128 GB |
| GPU | Mali G610 MP4 (display / OpenCL only — not useful for LLM inference) |
| NPU | 6 TOPS per module; RKNN inference validated (Whisper medium on node1, 2026-06-16) |
| Estimated power | ~10 W per module at idle |
| Node IPs | Static: node1=192.168.1.11, node2=.12, node3=.13, node4=.14, BMC=.10 |
| BMC hostname | `turingpi.local` (mDNS) |

## Node Role Assignment (planned)

| Node | Hostname | IP | Role |
|------|----------|----|------|
| 1 | rk1-node1 | 192.168.1.11 | k3s server + persistent registry; 2TB NVMe |
| 2 | rk1-node2 | 192.168.1.12 | k3s agent; 2TB NVMe |
| 3 | rk1-node3 | 192.168.1.13 | k3s agent; 2TB NVMe |
| 4 | rk1-node4 | 192.168.1.14 | k3s agent; eMMC only (no NVMe) |

## Software Stack

| Layer | Tool | Status |
|-------|------|--------|
| OS | Ubuntu 24.04.1 LTS ARM64 (joshua-riek/ubuntu-rockchip v2.4.0) | Deployed on all 4 nodes (2026-05-10) |
| Container runtime (Phase A) | Docker (node1 only, for Phase A registry) | Stopped (Phase B registry replaced it) |
| Container runtime (Phase B) | containerd 2.2.3 (via k3s) | Running on all 4 nodes |
| Orchestrator | k3s v1.36.3+k3s1 | Running (node1 server, nodes 2–4 agents); rebuilt 2026-08-14 |
| GitOps | Flux v2.9.4 | **Running**; syncing `gitops/` from GitHub via a read-only deploy key (B-04, done 2026-08-14) |
| Registry (Phase A) | registry:2 container, HTTP, port 5000 | Stopped (replaced by Phase B) |
| Registry (Phase B) | Helm chart (`charts/registry/`), TLS + basic auth | **Running** on node1 (HostPort 5000, PVC 50Gi local-ssd); rebuilt 2026-08-14 |
| Storage | `local-ssd` StorageClass (rancher.io/local-path-ssd, WaitForFirstConsumer) | **Running** in kube-system; scoped to nodes 1–3 (NVMe only); rebuilt 2026-08-14 |
| LLM runtime | Ollama (`charts/ollama/`); one Deployment per NVMe node; 200Gi PVC `local-ssd` | **Running** on nodes 1–3, `llama3.2:1b` loaded on each; redeployed 2026-08-14 after the 2026-08-13 reflash wiped the original 2026-05-11 deployment |
| Agent workloads | (consumer-owned; e.g. an evaluation agent on FastAPI, port 18090) | **Not deployed** — agent workloads are intentionally kept off this cluster and belong to whatever sits upstream of the job queue (ADR-0028). See [DEPLOYING-AN-AGENT.md](DEPLOYING-AN-AGENT.md) for the generic pattern if this changes |
| Job queue | KEDA + Redis (`charts/jobqueue/`), typed lists, `echo` demo ScaledJob | **Running** since 2026-08-15 — the ADR-0028 boundary; end-to-end roundtrip asserted by check C19 |
| Self-healing | On-SoC hardware watchdogs (all 4 nodes) + BMC-resident node watchdog (ssh + deep probes) | **Running** since 2026-08-15/16; see [SELF-HEALING.md](SELF-HEALING.md) |
| Network mesh | Tailscale 1.102.2; all 4 nodes + laptop on Tailnet; subnet routes `10.42.0.0/16` + `10.43.0.0/16` advertised via node1 | **Running** — all 3 layers rebuilt 2026-08-14 after the reflash wiped the previous mesh state |
| Ingress | Traefik (k3s built-in) | Running (k3s default); superseded by Tailscale operator for service exposure |
| Observability | kube-prometheus-stack (Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics); `charts/monitoring/values.yaml` | **Running** in `monitoring` namespace; Grafana exposed on Tailnet; redeployed 2026-08-14 after the 2026-08-13 reflash wiped the original 2026-05-11 deployment |
| NPU inference | `rknn-toolkit-lite2` + `librknnrt.so` 2.3.2; Whisper medium encoder+decoder; `tagx/whisper-stt:rknn` image | **Validated** on node1 (2026-06-16); `--privileged`; models at `/mnt/ssd/whisper-models/rknn/`; SA-KV KV-cache decoder wired 2026-08-14 (`rknn.decoder: sa-kv`, ~2.5× vs naive; see RKNN-SA-KV-DECODER-BUG.md) |

## Access Methods

| Method | Command / URL | Notes |
|--------|---------------|-------|
| BMC power control | `tpi power on/off -n NODE` | Installed on laptop; works over WiFi |
| SSH to nodes | `ssh ubuntu@rk1-node{1..4}` | After Phase A; `/etc/hosts` updated |
| Registry push (Phase A) | `docker push rk1-node1:5000/IMAGE` | HTTP only; Docker daemon needs insecure-registries config |
| Registry push (Phase B, LAN) | `docker push rk1-node1:5000/IMAGE` | HTTPS; CA cert must be trusted on laptop |
| Registry push (Phase B, off-LAN) | `TAILSCALE_REGISTRY_IP=<node1-tailscale-ip> make build-push` | Run `setup-offnet-access.sh` first; `make` auto-detects |
| kubectl | `kubectl get nodes` | After k3s install; kubeconfig on node1 at `/etc/rancher/k3s/k3s.yaml` |

## Tailscale Mesh (N-01)

| Device | Hostname |
|--------|----------|
| Laptop | (your machine name in Tailscale admin) |
| rk1-node1 | rk1-node1 |
| rk1-node2 | rk1-node2 |
| rk1-node3 | rk1-node3 |
| rk1-node4 | rk1-node4 |

Check live IPs with `tailscale status` or at <https://login.tailscale.com/admin/machines>.

Subnet routes `10.42.0.0/16` (pods) and `10.43.0.0/16` (services) advertised by node1 and approved in Tailscale admin. Laptop runs `tailscale up --accept-routes`. All ClusterIP services are directly routable from the laptop — no port-forwarding required.

Layer 3 (Tailscale Kubernetes operator) deployed in namespace `tailscale` (rebuilt 2026-08-14). Grafana is exposed through it (see Observability below). Add a service with `./scripts/setup-tailscale-operator.sh --expose svc/NAME -n NAMESPACE`; the operator names devices as `<namespace>-<service>`.

## Observability (D-04)

**Running** (redeployed 2026-08-14 after the reflash; see the Software Stack table).

| Component | URL | Notes |
|-----------|-----|-------|
| Grafana | `http://monitoring-kube-prometheus-stack-grafana.<tailnet>.ts.net:80` | admin / from credentials.kv |
| Prometheus | `http://<clusterIP>:9090` | ClusterIP, subnet-routed; run `kubectl get svc -n monitoring kube-prometheus-stack-prometheus` |
| Alertmanager | ClusterIP only | not yet exposed |

Pre-loaded dashboards: Node Exporter Full (1860), Kubernetes Cluster Overview (7249), k3s Cluster (15282).

All stateful components (Prometheus, Grafana, Alertmanager) use `storageClassName: local-ssd` PVCs on NVMe nodes (`storage.tpi-bro/nvme=true` nodeSelector). Grafana exposed on Tailnet via operator annotation.

Deploy: `./scripts/install-monitoring.sh`  
Verify: `./scripts/install-monitoring.sh --verify`

## Registry TLS Cert Status

- **Certs generated and deployed** (2026-05-11; updated 2026-05-16 for Tailscale SAN)
- SAN includes: `rk1-node1` (DNS), `192.168.1.11` (LAN IP), `<node1-tailscale-ip>` (Tailscale IP)
- Self-signed CA (`myCA.crt`) trusted by all 4 nodes and laptop Docker daemon (both LAN and Tailscale IPs)
- `registry-tls` Secret in namespace `registry` contains `registry.crt` + `registry.key`
- CA and cert artefacts in `registry-certs/` (gitignored)
- Cert valid 825 days from generation; CA valid 3650 days
- `NODE1_TAILSCALE_IP=<node1-tailscale-ip>` in `bootstrap-config.kv`

### Off-network access setup (new laptop / workstation)

Run once on each laptop that needs to push images or run `kubectl` off-LAN:

```bash
# 1. Trust the registry CA cert in Docker for the Tailscale registry address
./scripts/setup-offnet-access.sh

# 2. In the repo that builds your images, export the registry address
#    and build/push:
export TAILSCALE_REGISTRY_IP=<node1-tailscale-ip>
make build-push   # or your image repo's equivalent
```

If the Tailscale IP changes (re-provisioning): update `NODE1_TAILSCALE_IP` in `bootstrap-config.kv`,
regenerate certs with `gen-registry-certs.sh`, re-run `setup-offnet-access.sh`, and update the exported registry address wherever your image builds read it.

## Laptop Requirements

| Tool | Purpose | Status |
|------|---------|--------|
| `tpi` CLI | BMC power/flash control | Installed |
| `expect` | Phase A bootstrap script | Required |
| `nmap` | BMC/node discovery | Required |
| `ssh` | Node access | Required |
| `curl` | Health checks | Required |
| `docker` | Image build + push | Required for image workflow |
| `kubectl` | Cluster management | Installed (`bin/kubectl`, vendored) |
| `helm` | Phase B registry deploy | Installed (v3.20.2, `/usr/local/bin/helm`) |

## Auth Credentials

Registry basic auth credentials are stored in `~/.turingpi/credentials.kv` (mode 600, gitignored).

```
# ~/.turingpi/credentials.kv  (key=value, chmod 600)
REGISTRY_USER=push
REGISTRY_PASSWORD=<leave unset to auto-generate on first --enable-auth run, or set your own>

# N-01: Tailscale (Layer 1)
TAILSCALE_AUTH_KEY=<reusable pre-authorized key from https://login.tailscale.com/admin/settings/keys>

# N-01: Tailscale (Layer 3 — operator)
TAILSCALE_OAUTH_CLIENT_ID=<OAuth client ID from https://login.tailscale.com/admin/settings/oauth>
TAILSCALE_OAUTH_CLIENT_SECRET=<OAuth client secret>

# D-04: Monitoring
GRAFANA_ADMIN_PASSWORD=<choose a password>
```

Run `./scripts/setup-registry.sh --verify` to confirm push/pull with authentication.  
Run `./scripts/setup-registry.sh --enable-auth` to (re-)apply auth from this file.

containerd mirror config on each node includes the credentials in `/etc/rancher/k3s/registries.yaml`.  
Mirror endpoint uses the server IP (`192.168.1.11:5000`) so worker nodes don't need hostname DNS for `rk1-node1`.  
Re-run `./scripts/setup-registry.sh --ca-only` after changing the password to push updated credentials to all nodes.

## NVMe Storage

| Node | Device | Mount | Storage Class |
|------|--------|-------|---------------|
| rk1-node1 | TEAM TM8FPD002T 2TB | `/mnt/ssd` (ext4, noatime, UUID fstab) | `local-ssd` provisioner |
| rk1-node2 | TEAM TM8FPD002T 2TB | `/mnt/ssd` (ext4, noatime, UUID fstab) | `local-ssd` provisioner |
| rk1-node3 | TEAM TM8FPD002T 2TB | `/mnt/ssd` (ext4, noatime, UUID fstab) | `local-ssd` provisioner |
| rk1-node4 | — (no NVMe) | — | excluded from `local-ssd` |

All three NVMe nodes are labeled `storage.tpi-bro/nvme=true`. Workloads express storage requirements as a capability (`storageClassName: local-ssd`) rather than a hostname pin — k3s schedules dynamically to any SSD-capable node via `WaitForFirstConsumer` binding. See `adr/ADR-0019-storage-architecture.md`.

Registry PVC `registry-data` is on `local-ssd` (node1, co-located with HostPort 5000). The HostPort node1 pin is permanent in practice: the registry's local-SSD PVC ties it to node1 regardless of what IP fronts it (MetalLB was evaluated and dropped 2026-08-15 — see ROADMAP/backlog C-01).

## Finding and reconnecting to the BMC

The BMC is the cluster's always-on anchor — power control, serial consoles,
flashing, and the self-healing outer loop all go through it. When
`turingpi.local` doesn't resolve (common: mDNS rarely crosses WiFi/VLAN
boundaries), find it in this order:

1. **Static IP first.** If `setup-static-ips.sh` has ever run, the BMC is at
   the base address of the scheme (default `192.168.1.10`; nodes are
   base+1…4). `ping 192.168.1.10`, then `ssh root@192.168.1.10` (or
   `tpi --host 192.168.1.10 …`).
2. **Router DHCP table.** A factory-fresh or reflashed BMC DHCPs; look for
   hostname `turingpi` in the router's client list.
3. **nmap sweep.** `nmap -sn 192.168.1.0/24` and look for the BMC's MAC
   vendor, or `nmap -p 22,80 --open` — the BMC answers on both (ssh +
   web UI). Note the bootstrap's own A1 auto-detection depends on
   reverse-DNS resolving "turingpi", which most networks don't provide —
   manual IP entry is the normal path.
4. **Direct Ethernet.** Cable a laptop straight into one of the board's
   Ethernet ports (the BMC bridges `ge0`/`ge1` with the node ports on
   `br0`); run a DHCP server or set a static `192.168.1.x` on the laptop
   and hit `192.168.1.10`.

Once connected, the reconnection toolbox:

| Need | Command |
|---|---|
| Node power state | `tpi --host <BMC> power status` |
| Power-cycle a hung node | `tpi --host <BMC> power off -n N && sleep 8 && tpi --host <BMC> power on -n N` |
| Serial console of a node (boot diagnosis, no network needed) | `tpi --host <BMC> uart -n N get` |
| BMC shell | `ssh root@<BMC>` (BusyBox; overlay rootfs on `/`, persistent storage on `/mnt/sdcard`) |
| Self-healing watchdog status/log | `scripts/install-bmc-watchdog.sh --verify` |

Two persistence caveats, learned the hard way:

- **BMC firmware updates may reset the `/etc` overlay** — the static-IP
  config (`setStaticNet.sh`) and the self-healing watchdog live there.
  After any BMC firmware update, re-run `setup-static-ips.sh --bmc-only`
  and `install-bmc-watchdog.sh`.
- A node can boot "healthy" but be unreachable (warm-reboot PCIe flake —
  see `HARDWARE-FIRMWARE-ISSUES.md`). Don't debug the node over the
  network you can't reach it on: read its boot log via `tpi uart -n N get`
  from the BMC, then cold-cycle. The BMC watchdog automates exactly this
  (`SELF-HEALING.md`).

## Known Issues

Cluster bootstrap/network issues below. For NPU/RKNN hardware and firmware
issues (device access, driver coupling, silicon limits), see
`HARDWARE-FIRMWARE-ISSUES.md` instead.

- `turingpi.local` mDNS resolution can fail when only WiFi is available on some networks; fall back to using the static IP `192.168.1.10` directly
- Ubuntu 24.04.1 LTS enforces a mandatory password change on first boot; the bootstrap script handles this automatically via `unlock_expired_password`
- BMC's `nmap`-based auto-detection (A1) depends on reverse-DNS resolving the literal hostname "turingpi," which most networks don't provide — expect the manual IP-entry fallback to be the normal path, not a corner case
- ~~Accumulated cluster cruft as of 2026-08-13~~ — moot as of 2026-08-14: a fresh-run Phase A test reflashed all 4 nodes, which wiped the cluster (and this cruft) entirely. Phase B, GitOps, and the Tailscale mesh were rebuilt from scratch the same day; see the "Last updated" note at the top of this file
