# Getting Started

A step-by-step walkthrough from "board just arrived" to a running k3s cluster with
a persistent registry, Tailscale mesh, and NVMe storage. This is the canonical
installation guide — the README gives the overview, this page gives the steps.

Each step below notes what's now automated vs. what's still genuinely manual, based
on a real from-scratch run (2026-08-13) that exercised every stage for real —
including several that had only ever been dry-run before.

---

## What you'll end up with

After Phase A: 4 named nodes (`rk1-node{1..4}`), SSH access by hostname, a
temporary HTTP registry on `rk1-node1:5000`.

After Phase B: static IPs, SSH keys, k3s across all 4 nodes, a persistent
TLS+auth registry, NVMe mounted at `/mnt/ssd` on nodes 1–3, Ollama.

After Tailscale + application deployment: the cluster reachable off-LAN, and
your own application images running on it.

---

## Step 0 — Hardware assembly

Most of the physical build (heatsinks, case) is covered on the TuringPi home page.
Two things worth knowing that aren't obvious from official docs:

**Heatsink mounting**: be careful screwing heatsinks onto the RK1 modules — bushing
length varies between units, and a too-short bushing can bend the PCB if screwed
all the way in. Return/replace any heatsink with mismatched bushings.

![Bending of PCB due to too short busing](../assets/images/pcb-bending-too-short-busing.png)

**F Panel**: if using the TuringPi ATX case, wire [Power] and [Power LED] like this:

![F Panel pin layout and photo](../assets/images/f-panel-pin-layout.png)

If you ever need to factory-reset a node (e.g. lost passwords), move the power
connector to the reset pins and hold for 10s, then move it back.

---

## Step 1 — Install prerequisites

See [PREREQUISITES.md](PREREQUISITES.md) for the full list and distro-specific
install commands. Short version (Ubuntu/Debian):

```bash
sudo apt update && sudo apt install -y \
  expect openssh-client sshpass nmap curl openssl apache2-utils
```

Then install `tpi`, `kubectl`, `helm`, and `docker` per PREREQUISITES.md.

---

## Step 2 — Clone and configure

```bash
git clone https://github.com/your-org/tpi-bro && cd tpi-bro
chmod +x scripts/*.sh scripts/*.exp
cp bootstrap-config.kv.example bootstrap-config.kv
$EDITOR bootstrap-config.kv
```

At minimum, set:
- `SUBNET` — your LAN subnet
- `TPI_BASE_IP_ADDR` — base IP for the cluster block (BMC gets this address; nodes get base+1…base+4)
- `GATEWAY`

**Also set `DNS_SERVERS`** (e.g. `192.168.1.1 8.8.8.8`), even though it looks
optional in the template. If you ever use `FLASH_MODE=bmc` (the mode used for a
real, from-internet flash — see Step 3), the BMC itself needs working DNS to reach
GitHub, and there's nothing else that configures it: the BMC's network interface
is static, not DHCP, so nothing populates its `/etc/resolv.conf` automatically. If
it's missing, the bootstrap script now detects this and writes one from
`DNS_SERVERS` automatically — but only if you've set it. Without it, a missing BMC
resolver fails with a clear error telling you to set this variable, rather than the
opaque `curl: Could not resolve host` failure it used to produce.

If you're only reflashing nodes and not the BMC itself (`FLASH_MODE=local`, using
an image already on the BMC's SD card), you can skip this — it's specifically the
`bmc` and `download` flash modes that need it.

---

## Step 3 — Run Phase A (flash, name, network)

```bash
# Dry-run first — prints every action, touches nothing
./scripts/bootstrap-turingpi-cluster.exp --dry-run --phase A

# Real run
./scripts/bootstrap-turingpi-cluster.exp --phase A
```

**Expect this to take about an hour** on a real fresh-download flash (`--flash bmc`
or `download`) — most of it is the per-node flash itself (~10 min × 4 nodes), plus
image download/verify/decompress up front.

**BMC auto-detection will probably not find your BMC automatically.** Stage A1
tries `nmap -sn` and looks for a host that resolves to the literal hostname
"turingpi" — this depends on your network doing reverse-DNS resolution for it,
which most home/office networks don't. When you see:
```
Could not auto-detect BMC. Enter IP:
```
this is normal and expected, not a failure — find the IP yourself with
`nmap -sn <your-subnet>` (look for the Turing Pi's MAC OUI or just the one
unfamiliar host) and type it in. Alternatively, set `BMC_HOST` directly in
`bootstrap-config.kv` once you know it, to skip this prompt on future runs.

If you enable `BMC_FIRMWARE_MODE` (see [BMC firmware](#bmc-firmware-a0) below) on
a completely fresh run with no prior state, A0 now runs BMC discovery inline if
needed — this used to die with "BMC_HOST not set" since A0 ran before A1 had a
chance to discover anything.

**Verify:**
```bash
ssh ubuntu@rk1-node1 hostname
curl http://rk1-node1:5000/v2/_catalog   # Phase A registry only — HTTP, ephemeral
```

---

## Step 4 — Run Phase B (k3s + persistent registry + storage)

> **One-command alternative:** `./scripts/bootstrap-operational.sh` runs this
> step AND everything after it (resource policy, capability labels, the full
> Tailscale mesh, GitOps, Ollama, monitoring), ending with the cluster health
> check green. It's staged and resumable (`--from`/`--to`/`--dry-run`), does a
> preflight that lists every missing tool/credential up front, and pauses once
> for the one manual action (approving Tailscale subnet routes in the admin
> console). Steps 4–5 below describe the same ground piecewise, for running or
> re-running things individually.

```bash
./scripts/bootstrap-phase-b.sh --dry-run   # preview
./scripts/bootstrap-phase-b.sh             # real run — B0 → B2
```

**You'll be prompted twice**, both by design (no key-based auth exists yet at this
point): once for the BMC root password (static IP config), once for the Ubuntu
node password set during Phase A (SSH key distribution). Everything after B0 is
unattended.

NVMe handling is safe to re-run: `mount-ssd.sh` checks for an existing `ext4`
filesystem before formatting anything, so a partial re-run (or re-running Phase B
against nodes whose NVMe already has data from a prior run) won't wipe it.

```bash
./scripts/bootstrap-phase-b.sh --from B2_registry   # resume from a specific stage
./scripts/bootstrap-phase-b.sh --check              # + 10-check cluster health test
```

Credentials land in `~/.turingpi/credentials.kv` (mode 600, gitignored).

---

## Step 5 — Tailscale (manual)

This step is genuinely manual and can't be scripted — it needs your own Tailscale
account:

1. Create a Tailscale account and install it on your laptop.
2. Generate an auth key from the [admin console](https://login.tailscale.com/admin/settings/keys) — reusable, appropriately scoped for however many nodes you're joining.
3. Put it in `~/.turingpi/credentials.kv` as `TAILSCALE_AUTH_KEY=...`.
4. Also add `TAILSCALE_OAUTH_CLIENT_ID` / `TAILSCALE_OAUTH_CLIENT_SECRET` (from a separate OAuth client in the admin console) — used by the Kubernetes operator, not the per-node join.
5. Run:
   ```bash
   ./scripts/install-tailscale.sh          # per-node join, uses TAILSCALE_AUTH_KEY
   ./scripts/setup-subnet-router.sh        # advertise pod/service CIDRs
   ./scripts/setup-tailscale-operator.sh   # K8s operator, uses OAuth client
   ```
6. Approve the subnet routes in the Tailscale admin console (Machines → node1 → Edit route settings).

Auth keys are typically single-use or short-lived — if you're redoing this after a
prior setup, generate a fresh one rather than reusing an old `TAILSCALE_AUTH_KEY`.

---

## Step 6 — Populate the registry with your own images

**This is not automated by anything in this repo, by design** — see
[DEPLOYING-AN-AGENT.md](DEPLOYING-AN-AGENT.md). tpi-bro provides the cluster
and registry; each application owns its own Dockerfile, build tooling, and
Kubernetes manifests. If you're bringing up this cluster to run applications
from sibling repos (e.g. `sibling-app`, `tagx`), you need to separately clone those,
build their images, and push them using whatever build flow that repo defines:

```bash
# example — adjust for whatever app repo you're deploying
cd ../sibling-app
make build-push   # or whatever that repo's build flow is
```

Only after the image exists at `rk1-node1:5000/<your-image>:<tag>` will a
`kubectl apply` of its Deployment actually come up instead of sitting in
`ImagePullBackOff`.

---

## Verify you're done

```bash
kubectl get nodes                              # all 4 Ready
curl -sk https://rk1-node1:5000/v2/_catalog     # registry reachable, TLS
tailscale status                                # nodes visible on your tailnet
./tests/check-cluster.sh                        # 10-check health test
```

---

## BMC firmware (A0)

Skipped by default. To check or upgrade:

```bash
cp bmc-manifest.kv.example bmc-manifest.kv
# fill in latest.version/url/sha256 from https://github.com/turing-machines/BMC-Firmware/releases
# or https://firmware.turingpi.com/turing-pi2/

./scripts/bootstrap-turingpi-cluster.exp --from A0_bmc_firmware --to A0_bmc_firmware --bmc-firmware check
./scripts/bootstrap-turingpi-cluster.exp --from A0_bmc_firmware --to A0_bmc_firmware --bmc-firmware upgrade
```

A0 compares your BMC's running version against `latest.version` in the manifest
**before** downloading anything — if they match, both `check` and `upgrade` just
report "up to date" and stop; the actual download/flash/reboot sequence only runs
if they genuinely differ. So `upgrade` is safe to run speculatively even with a
placeholder manifest, as long as `latest.version` is accurate.

Note: your BMC's factory/vendor firmware may already be ahead of every publicly
downloadable release on GitHub — this isn't unusual, and it means there may be
nothing to upgrade to, no matter what mode you run.

---

## Flashing modes (Step 3, in detail)

| Mode | What happens |
|------|-------------|
| `skip` _(default)_ | Assumes nodes already have a working OS; proceeds to A4 |
| `local` | `tpi flash -n N --local` per node — BMC reads from its own SD card storage |
| `image` | `tpi flash -n N --image-path FILE` — upload from your laptop directly |
| `download` | Laptop downloads from `images-manifest.kv`, verifies SHA256, then uploads |
| `bmc` | BMC downloads directly from the internet to its own SD card, verifies SHA256, flashes from there — avoids uploading large files from your laptop, but needs the BMC to have working DNS (see Step 2) |

```bash
./scripts/bootstrap-turingpi-cluster.exp --phase A --flash local
./scripts/bootstrap-turingpi-cluster.exp --phase A --flash image --image worker.img --image-1 server.img
./scripts/bootstrap-turingpi-cluster.exp --phase A --flash download --manifest images-manifest.kv
./scripts/bootstrap-turingpi-cluster.exp --phase A --flash bmc --manifest images-manifest-bmc.kv
```

---

## If something goes wrong

**BMC auto-detect fails** — expected, see Step 3. Manually find and enter the IP,
or set `BMC_HOST` in config.

**Node IPs changed after a power cycle:**
```bash
./scripts/bootstrap-turingpi-cluster.exp --rediscover
```
Identifies nodes by SSH hostname (not stored IP), so it works regardless of what
DHCP assigned. For a permanent fix, set static DHCP reservations in your router
using the MAC table A4 prints at the end of Phase A.

**`tpi` fails with "no such device or address":** this can mean two different
things. If you're at a real interactive terminal, `tpi` needs one to prompt for
credentials on first use — run `tpi power status` once manually, and it caches a
token at `~/.cache/tpi_token` for subsequent calls. If you're running the
bootstrap script non-interactively (e.g. from CI or an automation harness with no
attached terminal) and it hits an unhandled prompt, it now dies with a clear
message instead of crashing — set `BMC_HOST` and `NEW_PASS` in config ahead of
time to avoid needing any interactive prompt at all.

**Registry not reachable after push (Phase A only):** it's HTTP-only. Add
`rk1-node1:5000` to Docker's `insecure-registries` on your laptop and restart
Docker.

**Reruns:** every stage is safe to rerun with `--from <stage>` after fixing
whatever failed.

---

## Starting over

```bash
./scripts/teardown-cluster.exp                      # reset to factory-equivalent state
./scripts/bootstrap-turingpi-cluster.exp --phase A   # fresh Phase A
```

Teardown resets node passwords/hostnames, removes the Phase A registry, and powers
everything off. It's resilient to IP drift — it locates nodes by hostname even if
`bootstrap-state.kv` is stale or missing, so you don't need a valid state file to
run it.

```bash
./scripts/teardown-cluster.exp --dry-run              # preview
./scripts/teardown-cluster.exp --remove-docker         # also uninstall Docker from registry node
./scripts/teardown-cluster.exp --from T3_stop_registry # resume from a specific stage
```

---

## Reference

- [PREREQUISITES.md](PREREQUISITES.md) — full tool list and install commands
- [ROADMAP.md](ROADMAP.md) — phase-by-phase status and what's next
- [OPERATIONS.md](OPERATIONS.md) — current hardware, access methods, credentials format
- [TEST_STATUS.md](TEST_STATUS.md) — what's actually tested vs. dry-run-only
- [backlog/BACKLOG.md](backlog/BACKLOG.md) — open work items
- [adr/](adr/) — architecture decisions, including why things are built the way they are
