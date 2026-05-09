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
* Name the nodes (i.e., compute modules) so that they have **disctinct hostnames**,
* establish a **docker registry** for storing application images, and
* **orchestrate** all **applications** through Kubernetes (i.e., k3s actually) to be able to scale up / down applications depending on the user's current focus / need.

Check out the [TODO](TODO.md) list for potential future additions to the project. Maybe you want to help out in realizing these?

### Project Name

**`bro`** for "bro(ther)" to help you out or "bro" (Swedish for "brigde") to bridge the gap you're facing when starting out.

## Initial HW configuration / assembly

Most of the HW build (heatsinks), etc, are described well on the TuringPi home page. However, there are two things that you need to know. This information will be kept here until the official homepage has been updated and the tolerances for the metal busings of the heatsink have been fixed.

### Heatsink mounting

Be very careful when screwing the heatsinks onto the RK1 compute modules, The busings that I received where different, and in particular one heatsink had a too short busing on one side, bending the PCB if screwing it all the way in, potentially leading to problems later down the road. Be sure to return any heatsink or request a new one if you get one with too short busings like this one

![Bending of PSB due to too short busing](assets/images/pcb-bending-too-short-busing.png)

### F Panel

If you are using the TuringPi ATX case, the [Power] and [Power LED] connectors should be connected like this

![Split image with F Panel pin layout and photo on connected Power and Power LED connectors](assets/images/f-panel-pin-layout.png)

Later, if you need to reflash the RK1 compute modules (say that you've been away for some time and didn't write down your passwords... yeah, it can happen...), you can connect the power connector to the reset pins, and press the button for 10s to do a factory reset. Then you can move the connector back to the [Power] connector again and start anew.

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

---

### Prerequisites

**On your laptop (where you run the script):**
- `expect`, `bash`, `ssh`, `nmap`, `curl`, e.g., through
   - `sudo apt install <missing dependency>`
- `sudo` access (to update `/etc/hosts`)
- Network with RK1 nodes reachable via SSH
- Default node credentials: `ubuntu` / `ubuntu` (or adjust in script)

**On the RK1 nodes:**
- Ubuntu-based OS flashed and booting (will be included in bootstrap sequence later)
- DHCP enabled (or fixed IPs you can provide)

---

### Files

- `bootstrap-turingpi-cluster.exp` &nbsp; – &nbsp; main Expect script (staged, resumable)
- `bootstrap-host-helper.sh` &nbsp; – &nbsp; small helper to idempotently append to `/etc/hosts`
- `bootstrap-state.kv` &nbsp; – &nbsp; generated state file with discovered mappings

Make them executable:

```bash
chmod +x bootstrap-turingpi-cluster.exp bootstrap-host-helper.sh
```

### Usage

#### Show Help

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



### Expect Script Stages ("Phase A")

* A1_find_bmc &nbsp; – &nbsp; Discover the BMC (Turing Pi) via nmap, or enter manually
* A2_poweroff_all &nbsp; – &nbsp; Power OFF all RK1 nodes (tpi placeholder)
* A3_flash_optional &nbsp; – &nbsp; Optional flashing step (USB/web stubs)
* A4_power_on_and_discover &nbsp; – &nbsp; Power nodes one-by-one; discover IPs
* A5_name_password_reboot &nbsp; – &nbsp; Change password, set hostnames, reboot
* A6_write_hosts_on_laptop &nbsp; – &nbsp; Append IP ↔ hostname to laptop /etc/hosts
* A7_ephemeral_registry_phaseA &nbsp; – &nbsp; Install Docker on node1, start registry:2 (HTTP, --restart=always)

Each stage is written with [`check` -> `act`](https://en.wikipedia.org/wiki/PDCA) logic where practical, so reruns should be safe.

### Configuration

Open bootstrap-turingpi-cluster.exp and adjust the Config block near the top:

`SUBNET` &nbsp; – &nbsp; your LAN subnet (default 192.168.1.0/24)<br>
`NODE_COUNT` &nbsp; – &nbsp; number of RK1 nodes (default 4)<br>
`NODE_PREFIX` &nbsp; – &nbsp; hostname prefix (default rk1-node)<br>
`DEFAULT_USER` / `DEFAULT_PASS` &nbsp; – &nbsp; initial SSH credentials<br>
`NEW_PASS` &nbsp; – &nbsp; if empty, you will be prompted once and that password is applied to all nodes<br>
`REGISTRY_NODE_IDX` &nbsp; – &nbsp; which node hosts the registry (default 1)<br>
`REGISTRY_PORT` &nbsp; – &nbsp; registry port (default 5000)<br>
`FLASH_MODE` &nbsp; – &nbsp; usb|web|skip (stubs here)<br>

### What this script does not do (yet)

Flash over USB or from the BMC web (stubs only; hardware + host vary)

Make the registry persistent (SSD), TLS, basic auth (Phase B)

Configure k3s/containerd mirrors/trust (Phase B)

Install k3s / join workers (future stage set)

### Troubleshooting

SSH/hostnames: If discovery is flaky, you can pre-fill IPs → names, then rerun from later stages.

Registry: This is HTTP-only in Phase A. That’s intentional—TLS & auth arrive in Phase B.

Reruns: Safe to rerun with --from <stage> after you fix whatever failed.


## Handoff: From Bootstrap (Expect) to Cluster Orchestration (K8s/GitOps)

This project intentionally splits responsibilities between bootstrap automation (imperative, with Expect) and cluster orchestration (declarative, with Kubernetes + GitOps).

Where Expect ends (Phase A)

The Expect script (bootstrap-turingpi-cluster.exp) is only responsible for one-time or out-of-band setup that cannot be declaratively managed inside Kubernetes:

Discover the BMC and RK1 nodes on the LAN

Power cycle nodes to ensure a clean baseline

(Optionally) flash OS images via USB/web (stubbed)

SSH into nodes with default credentials and update passwords

Assign stable hostnames (rk1-nodeX) and reboot

Update /etc/hosts on the laptop with node mappings

Bring up a basic, ephemeral Docker registry on rk1-node1

Once the registry is reachable and each node has a hostname and working SSH, the cluster is considered bootstrapped.

At this point, Expect stops — its job is done.

Where Kubernetes / GitOps begins (Phase B and onwards)

Everything after bootstrap should be handled declaratively via Kubernetes manifests and GitOps tooling:

Phase B: Persistent registry with TLS + auth, mounted SSD storage, CA trust distribution

Phase C: Local registry mirror + sync from laptop, IP resilience, cloud expansion

Phase D and beyond: Multi-agent workloads, ingress, autoscaling, observability, etc.

Recommended workflow:

Build & push images from CI/CD into the cluster-local registry

Describe desired workloads (Deployments, Services, Ingress) using Helm or Kustomize

Commit to Git (platform repo)

Argo CD / Flux continuously reconciles cluster state to match the repo

Promotions between environments = pull requests, not manual commands

Why this split?

Expect excels at scripting fragile, one-time, interactive steps (BMC control, initial password, USB flashing).

Kubernetes/GitOps excels at continuously reconciling declarative state inside the cluster.

Trying to use Expect inside the cluster (to kubectl apply, patch, etc.) would create snowflake states and drift. Conversely, trying to use Helm/Argo to flash USB images or reset BMC power would be impossible.

By drawing the line here, the system is reproducible from bare metal up through workloads:

Rerun Expect = fresh cluster baseline

Sync GitOps = workloads deployed



TODO: Add text on LICENSE, DISCLAIMER on LIMITED LIABILITY / "AS IS" (FOSS ethos in "good faith").