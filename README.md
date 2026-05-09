# `tpi-bro` &nbsp; – &nbsp; a Turing Pi 2 Cluster Bootstrap project

> This is a practical, minimal bootstrap to get a [Turing Pi 2](https://turingpi.com/) cluster with 4 [RK1](https://docs.turingpi.com/docs/turing-rk1-specs-and-io-ports) compute modules to a working state fast. This guide has 3 main sections,
>
> * [Initial HW configuration/assembly](#initial-hw-configuration--assembly) &nbsp; – &nbsp; (some of?) what you need to know beyond official documentation.
> * [Initial bootstrap](#initial-board-and-cluster-bootstrap-expect-flashing-and-network-setup) is done through leveraging the interactive capabilities of Expect (a TCL-based language), to flash compute modules, to identify IP addresses on local network and to set usernames, passwords and hostnames for cluster nodes. (This is called "Phase A".)
> * [A GitOps workflow](#handoff-from-bootstrap-expect-to-cluster-orchestration-k8sgitops) handles the rest, K8s orchestration, etc.<br>(These are Phases B through D, all the way up to a "Hello, World!" example for a multi-agent setup.)
>
> **Disclaimer**: This project has yet to play with Nvidia Jetson (Orin) Nano and CM4 adapters for RPi, so it's not possible to tell if these scripts and instructions will help anyone to get started for such configurations.

## Introduction

### Project History

This project started from a need to have a reproducible way of bootstrapping a TuringPi cluster, given that many laptops today do not have Ethernet ports but rely on WiFi for connectivity.

### Project Goals

Among the things that were on the "wanted features" list were

* **Automate** cluster and compute module **discovery**,
* **Flash** the RK1 **compute modules** with the standard ubuntu images,
* Name the nodes (i.e., compute modules) so that they have **distinct hostnames**,
* establish a **docker registry** for storing application images, and
* **orchestrate** all **applications** through Kubernetes (i.e., k3s actually) to be able to scale up / down applications depending on the user's current focus / need.

Check out the [TODO](TODO.md) list for potential future additions to the project. Maybe you want to help out in realizing these?

### Project Name

**`bro`** for "bro(ther)" to help you out or "bro" (Swedish for "bridge") to bridge the gap you're facing when starting out.

---

## Initial HW configuration / assembly

Most of the HW build (heatsinks), etc, are described well on the TuringPi home page. However, there are two things that you need to know. This information will be kept here until the official homepage has been updated and the tolerances for the metal busings of the heatsink have been fixed.

### Heatsink mounting

Be very careful when screwing the heatsinks onto the RK1 compute modules. The busings that I received were different, and in particular one heatsink had a too short busing on one side, bending the PCB if screwing it all the way in, potentially leading to problems later down the road. Be sure to return any heatsink or request a new one if you get one with too short busings like this one.

![Bending of PSB due to too short busing](assets/images/pcb-bending-too-short-busing.png)

### F Panel

If you are using the TuringPi ATX case, the [Power] and [Power LED] connectors should be connected like this:

![Split image with F Panel pin layout and photo on connected Power and Power LED connectors](assets/images/f-panel-pin-layout.png)

Later, if you need to reflash the RK1 compute modules (say that you've been away for some time and didn't write down your passwords... yeah, it can happen...), you can connect the power connector to the reset pins, and press the button for 10s to do a factory reset. Then you can move the connector back to the [Power] connector again and start anew.

---

## Initial board and cluster bootstrap: Expect (flashing and network setup)

This repo contains a resumable, staged [**Expect**](https://core.tcl-lang.org/expect/index) bootstrap for a [Turing Pi](https://turingpi.com/) ([BMC](https://docs.turingpi.com/docs/turing-pi2-bmc-intro-specs)) + 4× [RK1](https://docs.turingpi.com/docs/turing-rk1-specs-and-io-ports) nodes to reach a wanted board bring up "baseline". The "baselines" are categorized into "Phases" with varying degrees of Docker/Kubernetes capabilities up to a working "Hello, World" multi-agent setup example. E.g., "Phase A" contains
- Nodes named `rk1-node{1..4}` with a unified password
- Laptop `/etc/hosts` updated
- An **ephemeral** (HTTP) Docker registry running on `rk1-node1` with `--restart=always`

The Expect script is designed to be:
- **Resumable**: run a slice with `--from` / `--to`
- **Dry-run capable**: see what would happen with `--dry-run`
- **Mode-aware**: choose flashing mode `--flash usb|web|skip`<br>(note: not all USB ports can manage [USB OTG](https://en.wikipedia.org/wiki/USB_On-The-Go) or you might have reasons to use the Web UI...)
- **Stateful**: discoveries are saved to `bootstrap-state.kv`
- **Rediscoverable**: `--rediscover` re-scans the subnet after DHCP reassignment, with no power cycling

---

### Prerequisites

#### On your laptop (where you run the script)

Install the following tools. All are standard and available via your system package manager.

| Tool | Purpose | Install (Ubuntu/Debian) |
|------|---------|------------------------|
| `expect` | Drive the bootstrap script | `sudo apt install expect` |
| `bash` | Helper scripts | Pre-installed |
| `ssh` | Node access | `sudo apt install openssh-client` |
| `nmap` | BMC and node discovery | `sudo apt install nmap` |
| `curl` | Health checks | `sudo apt install curl` |
| `tpi` CLI | BMC power / flash control | See below |
| `docker` | Image build and push (Phase B+) | [docs.docker.com](https://docs.docker.com/engine/install/) |
| `helm` | Deploy Helm charts (Phase B+) | [helm.sh/docs](https://helm.sh/docs/intro/install/) |
| `kubectl` | Cluster management (Phase B+) | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |

**Installing the `tpi` CLI:**

The `tpi` tool communicates with the TuringPi BMC (Baseboard Management Controller) to power nodes on/off and flash firmware. Install it on your laptop — it does not run on the nodes themselves.

```bash
# Download from the TuringPi release page and place in your PATH
# See https://docs.turingpi.com/docs/turing-pi2-bmc-intro-specs for current version
```

After installing, authenticate once:
```bash
tpi login              # prompts for BMC credentials; cached after first use
```

The BMC is reachable at `turingpi.local` by default (mDNS). This works over both Ethernet and WiFi on most networks. If mDNS fails, find the BMC IP by scanning your router's DHCP table or running `nmap -sn 192.168.1.0/24` and looking for the TuringPi device.

#### On the RK1 nodes

- Ubuntu-based OS flashed and booting (Phase A3 handles this, or do it manually via the BMC web UI)
- DHCP enabled (standard Ubuntu image default)
- Default credentials: `ubuntu` / `ubuntu`

#### `sudo` access on your laptop

Stages A1 and A6 update `/etc/hosts` on your laptop (A1 pins the BMC, A6 pins the nodes). The helper script (`bootstrap-host-helper.sh`) uses `sudo` for both. You will be prompted if your sudo session has expired.

---

### Files

| File | Purpose |
|------|---------|
| `bootstrap-turingpi-cluster.exp` | Main bootstrap Expect script (staged, resumable, `--rediscover` mode) |
| `teardown-cluster.exp` | Reverses Phase A — resets nodes to a re-bootstrappable state |
| `bootstrap-host-helper.sh` | Manages `/etc/hosts` entries (`hosts-append` / `hosts-remove`) |
| `bootstrap-state.kv` | Generated state file — discovered IPs, MACs, BMC address (gitignored) |
| `gen-registry-certs.sh` | Generates TLS certificates for the Phase B registry |
| `registry-chart/` | Helm chart for the persistent Phase B registry |

Make the scripts executable:

```bash
chmod +x bootstrap-turingpi-cluster.exp teardown-cluster.exp bootstrap-host-helper.sh gen-registry-certs.sh
```

---

### Usage

#### Show help

```bash
./bootstrap-turingpi-cluster.exp --help
```

#### Run everything in Phase A (real run)

```bash
./bootstrap-turingpi-cluster.exp --phase A
```

#### Dry-run all of Phase A (prints actions, but no changes)

```bash
./bootstrap-turingpi-cluster.exp --dry-run --phase A
```

#### Run a slice by stage name (in example, up to node discovery)

```bash
./bootstrap-turingpi-cluster.exp --from A1_find_bmc --to A4_power_on_and_discover
```

#### Resume from naming/password/reboot step (after fixing an issue)

```bash
./bootstrap-turingpi-cluster.exp --from A5_name_password_reboot
```

#### Choose flashing mode (choose one of the following)

```bash
./bootstrap-turingpi-cluster.exp --phase A --flash skip   # default
./bootstrap-turingpi-cluster.exp --phase A --flash usb    # placeholder
./bootstrap-turingpi-cluster.exp --phase A --flash web    # placeholder
```

#### Fix IP drift without re-running Phase A

If DHCP has reassigned node IPs since the last run (e.g. after WiFi dropped), use `--rediscover`. It scans the subnet, identifies each node by its SSH hostname, and rewrites `/etc/hosts` and `bootstrap-state.kv` with the new IPs. No power cycling, no password changes.

```bash
./bootstrap-turingpi-cluster.exp --rediscover
./bootstrap-turingpi-cluster.exp --dry-run --rediscover   # preview only
```

---

### Expect Script Stages ("Phase A")

| Stage | Name | What it does |
|-------|------|--------------|
| A1 | `find_bmc` | Discover BMC via `nmap` or manual entry; pin `turingpi.local` in `/etc/hosts`; extract BMC MAC |
| A2 | `poweroff_all` | Power OFF all RK1 nodes via `tpi power off` |
| A3 | `flash_optional` | Optional flash (USB/web stubs — hardware-specific) |
| A4 | `power_on_and_discover` | Power nodes on one-by-one; discover IPs via delta scan; extract MACs; print DHCP reservation summary |
| A5 | `name_password_reboot` | Change password, set hostnames (`rk1-node{1..4}`), reboot |
| A6 | `write_hosts_on_laptop` | Append node IP↔hostname entries to laptop `/etc/hosts` |
| A7 | `ephemeral_registry_phaseA` | Install Docker on node1; start `registry:2` (HTTP, `--restart=always`) |

Each stage is written with check→act logic where practical, so reruns are safe.

---

### DHCP and IP stability

DHCP does not guarantee stable IPs. After a power cycle or network interruption, nodes may get different addresses, breaking SSH and `kubectl` access.

**The right fix: static DHCP reservations.** When A4 completes it prints a table like:

```
DHCP reservation summary — configure in your router for stable IPs:
  rk1-node1  MAC=dc:a6:32:xx:xx:xx  →  192.168.1.115
  rk1-node2  MAC=dc:a6:32:xx:xx:xx  →  192.168.1.240
  rk1-node3  MAC=dc:a6:32:xx:xx:xx  →  192.168.1.166
  rk1-node4  MAC=dc:a6:32:xx:xx:xx  →  192.168.1.93
  turingpi (BMC)  MAC=xx:xx:xx:xx:xx:xx  →  192.168.1.163
```

Enter these MAC→IP bindings in your router's DHCP reservation settings. Once done, IPs are stable across reboots and `--rediscover` is rarely needed.

**If you can't set DHCP reservations** (e.g. a managed office network), run `--rediscover` any time IPs drift. It identifies nodes by hostname over SSH — not by stored IP — so it works regardless of what DHCP assigned.

---

### Configuration

Open `bootstrap-turingpi-cluster.exp` and adjust the config block near the top:

| Variable | Default | Purpose |
|----------|---------|---------|
| `SUBNET` | `192.168.1.0/24` | Your LAN subnet |
| `NODE_COUNT` | `4` | Number of RK1 nodes |
| `NODE_PREFIX` | `rk1-node` | Hostname prefix |
| `DEFAULT_USER` | `ubuntu` | Initial SSH username |
| `DEFAULT_PASS` | `ubuntu` | Initial SSH password |
| `NEW_PASS` | _(empty)_ | If empty, prompted once and applied to all nodes |
| `REGISTRY_NODE_IDX` | `1` | Which node hosts the registry |
| `REGISTRY_PORT` | `5000` | Registry port |
| `FLASH_MODE` | `skip` | `usb` / `web` / `skip` |
| `BMC_HOST` | _(auto)_ | Set by A1; passed to `tpi` as `--host` when `turingpi.local` mDNS isn't yet available |

---

### Troubleshooting

**BMC not found / `turingpi.local` not resolving:**

mDNS (`turingpi.local`) is unreliable on some WiFi networks. Once Phase A has run once, this is no longer an issue — A1 pins the BMC IP in `/etc/hosts` so `tpi` always resolves it. Before Phase A has run, find the BMC manually:

```bash
nmap -sn 192.168.1.0/24     # look for host named "turingpi"
tpi --host <ip> power status # use the discovered IP explicitly
```

A1 will then run `tpi` with that IP and pin it. Subsequent stages and reruns use `/etc/hosts` — no mDNS dependency.

**Node IPs changed after power cycle:**

Set static DHCP reservations using the MAC table printed by A4 (see [DHCP and IP stability](#dhcp-and-ip-stability) above). If IPs have already drifted, run:

```bash
./bootstrap-turingpi-cluster.exp --rediscover
```

This scans the subnet, identifies nodes by SSH hostname, and updates both `/etc/hosts` and the state file. No power cycling.

**tpi authentication fails / "no such device" error:**

`tpi` needs an interactive terminal to prompt for BMC credentials on first use. Run it once from your normal terminal:

```bash
tpi power status    # or: tpi --host <bmc-ip> power status
```

Credentials are cached in `~/.cache/tpi_token` and all subsequent calls (including from the bootstrap script) work without a TTY.

**Registry not reachable after push:**

The Phase A registry is HTTP-only. Add `rk1-node1:5000` to Docker's `insecure-registries` on your laptop:
```json
{ "insecure-registries": ["rk1-node1:5000"] }
```
Then `sudo systemctl restart docker`.

**Reruns:** Safe to rerun with `--from <stage>` after fixing whatever failed.

---

---

## Teardown

`teardown-cluster.exp` reverses Phase A cleanly — useful for scratch-reinstall testing or decommissioning. It resets every node to a re-bootstrappable state (default credentials, no registry, hostnames reset) and powers them all off.

### Why a separate teardown script?

The bootstrap is intentionally forward-only (idempotent stages, check→act). Teardown runs in the opposite direction with different concerns — it must locate nodes even when IPs have drifted, and it must succeed even if parts of Phase A were never completed.

### Teardown stages

| Stage | Name | What it does |
|-------|------|--------------|
| T1 | `load_state` | Load state; verify each node IP is live; scan subnet by hostname if IPs drifted |
| T2 | `verify_connectivity` | Report resolved IP for each node |
| T3 | `stop_registry` | Stop and remove the `registry:2` container on node1 |
| T4 | `reset_passwords` | Reset all node passwords to `ubuntu:ubuntu` |
| T5 | `reset_hostnames` | Reset hostnames to `ubuntu`; remove `127.0.1.1 rk1-nodeN` from node `/etc/hosts` |
| T6 | `clean_laptop_hosts` | Remove `rk1-node{1..4}` and `turingpi.local` from laptop `/etc/hosts` |
| T7 | `poweroff_nodes` | Graceful `sudo poweroff` per node; waits for SSH to drop; BMC `tpi power off` |
| T8 | `clear_state` | Archive `bootstrap-state.kv` with a timestamp |

### Teardown usage

```bash
./teardown-cluster.exp                    # full teardown (prompts for current node password)
./teardown-cluster.exp --dry-run          # preview all actions
./teardown-cluster.exp --remove-docker    # also uninstall Docker from registry node
./teardown-cluster.exp --keep-hostname    # skip hostname reset (bootstrap overwrites anyway)
./teardown-cluster.exp --from T3_stop_registry  # resume from a specific stage
```

T1 is resilient to IP drift — it tries stored IPs first, then falls back to scanning the subnet and identifying nodes by their SSH hostname. You do not need a valid state file to run teardown.

### Full reinstall cycle

```bash
./teardown-cluster.exp                    # reset to factory-equivalent state
./bootstrap-turingpi-cluster.exp --phase A  # fresh Phase A from scratch
```

---

## Handoff: From Bootstrap (Expect) to Cluster Orchestration (K8s/GitOps)

This project intentionally splits responsibilities between bootstrap automation (imperative, with Expect) and cluster orchestration (declarative, with Kubernetes + GitOps).

### Where Expect ends (Phase A)

The Expect script (`bootstrap-turingpi-cluster.exp`) is only responsible for one-time or out-of-band setup that cannot be declaratively managed inside Kubernetes:

- Discover the BMC and RK1 nodes on the LAN
- Power cycle nodes to ensure a clean baseline
- (Optionally) flash OS images via USB/web (stubbed)
- SSH into nodes with default credentials and update passwords
- Assign stable hostnames (`rk1-nodeX`) and reboot
- Update `/etc/hosts` on the laptop with node mappings
- Bring up a basic, ephemeral Docker registry on `rk1-node1`

Once the registry is reachable and each node has a hostname and working SSH, the cluster is considered bootstrapped. At this point, Expect stops — its job is done.

### Where Kubernetes / GitOps begins (Phase B and onwards)

Everything after bootstrap is handled declaratively via Kubernetes manifests and GitOps tooling:

**Phase B:** Persistent registry with TLS + auth, mounted SSD storage, CA trust distribution, k3s install across all nodes, containerd mirror configuration.

**Phase C:** Local registry mirror + sync from laptop, IP resilience (static DHCP or CoreDNS), cloud expansion notes.

**Phase D and beyond:** Multi-agent workloads, Ollama deployment per node, ingress, autoscaling, observability.

Recommended workflow:
1. Build & push images from CI/CD into the cluster-local registry
2. Describe desired workloads (Deployments, Services, Ingress) using Helm or Kustomize
3. Commit to Git (platform repo)
4. Argo CD / Flux continuously reconciles cluster state to match the repo
5. Promotions between environments = pull requests, not manual commands

### Why this split?

Expect excels at scripting fragile, one-time, interactive steps (BMC control, initial password, USB flashing).

Kubernetes/GitOps excels at continuously reconciling declarative state inside the cluster.

Trying to use Expect inside the cluster would create snowflake states and drift. Conversely, trying to use Helm/Argo to flash USB images or reset BMC power would be impossible.

By drawing the line here, the system is reproducible from bare metal up through workloads:
- **Rerun Expect** = fresh cluster baseline
- **Sync GitOps** = workloads deployed

---

## Architecture Notes

### Hardware

| Component | Spec |
|-----------|------|
| Board | TuringPi 2 |
| Compute modules | 4× RK1 (Rockchip RK3588, ARM64) |
| RAM per module | 32 GB LPDDR5 |
| Total cluster RAM | 128 GB |
| GPU | Mali G610 MP4 (OpenCL; not suitable for LLM inference) |
| NPU | 6 TOPS per module (24 TOPS total) |
| Idle power | ~10 W per module |

### LLM Placement Constraint

**LLMs require contiguous memory.** A model's weights must reside entirely within one physical machine's address space — you cannot shard a single model across RK1 modules. This means:

- Each LLM-backed agent service maps to exactly one RK1 module
- Maximum model size: ~28–30 GB (32 GB minus OS overhead)
- The number of simultaneously-running LLM agents ≤ number of nodes

Supporting services (API gateway, vector DB, queue, metrics) are stateless or distributed and can be scheduled freely across nodes.

**Suggested initial workload distribution:**

| Node | Hostname | Role |
|------|----------|------|
| 1 | `rk1-node1` | k3s control plane + Agent A agent |
| 2 | `rk1-node2` | Future LLM agent |
| 3 | `rk1-node3` | Future LLM agent |
| 4 | `rk1-node4` | RAG / vector DB / supporting infra |

### Tool Roles

| Tool | Role in this project |
|------|---------------------|
| Expect | Phase A only: drive interactive SSH, handle boot timing, discover IPs |
| k3s | Lightweight Kubernetes (single binary, SQLite, ARM64 native) |
| Helm | Deploy Phase B registry and future workloads |
| Argo CD / Flux | GitOps controller — reconcile cluster to Git state continuously |
| Ollama | LLM inference runtime on each agent node |
| Traefik | Ingress (bundled with k3s) |
| Prometheus + Grafana | Observability (Phase D+) |

---

## Project Status

See [PROJECT_STATUS.md](PROJECT_STATUS.md) for phase-by-phase status and [DEPLOYMENT_STATUS.md](DEPLOYMENT_STATUS.md) for hardware/software inventory.

Open work items are tracked in [mem/backlog/BACKLOG.md](mem/backlog/BACKLOG.md).

Architectural decisions are recorded in [mem/adr/](mem/adr/).

---

TODO: Add text on LICENSE, DISCLAIMER on LIMITED LIABILITY / "AS IS" (FOSS ethos in "good faith").
