# Troubleshooting Guide — tpi-bro / TuringPi 2 + RK1

A field guide to the problems you will actually encounter, accumulated from two
full bootstrap sessions. Ordered roughly by the phase where each issue appears.

---

## Contents

1. [Flash issues](#1-flash-issues)
2. [Node stuck / not entering maskrom](#2-node-stuck--not-entering-maskrom)
3. [bmcd daemon stuck](#3-bmcd-daemon-stuck)
4. [BMC connectivity and auth](#4-bmc-connectivity-and-auth)
5. [SD card not mounted after BMC reboot](#5-sd-card-not-mounted-after-bmc-reboot)
6. [tpi power / status hangs from laptop](#6-tpi-power--status-hangs-from-laptop)
7. [Network discovery](#7-network-discovery)
8. [SSH to nodes](#8-ssh-to-nodes)
9. [Docker](#9-docker)
10. [TLS / certificates](#10-tls--certificates)
11. [k3s / Kubernetes](#11-k3s--kubernetes)
12. [Registry — Phase A (HTTP)](#12-registry--phase-a-http)
13. [Registry — Phase B (TLS + auth)](#13-registry--phase-b-tls--auth)
14. [Expect script / bootstrap automation](#14-expect-script--bootstrap-automation)
15. [General lessons learned](#15-general-lessons-learned)

---

## 1. Flash issues

### "memory limit reached" during `tpi flash --local`

**Symptom:** `tpi flash` prints `memory limit reached` × N, no progress.

**Cause:** The BMC has ~138 MB free RAM and cannot decompress a `.xz` image in
memory. A `.xz` Ubuntu image expands to ~4.3 GB.

**Fix:** Pre-decompress the image on the BMC before flashing:
```bash
xz -d /mnt/sdcard/tpi-images/your-image.img.xz
```
The bootstrap script handles this automatically in `--flash bmc` mode.

---

### `tpi flash` returns `500 Internal Server Error`

**Cause:** The image path does not exist — typically because the SD card is not
mounted after a BMC reboot.

**Fix:** Remount the SD card (see [§5](#5-sd-card-not-mounted-after-bmc-reboot)),
then retry.

---

### Flash hangs at "Flashing from image file..." with no progress

**Cause:** The node is not in maskrom mode. `tpi flash` waits indefinitely for the
USB device to enumerate.

**Fix:** See [§2](#2-node-stuck--not-entering-maskrom).

---

### Flash completes but node does not boot

**Cause:** Usually the image was a compressed `.xz` file written raw to eMMC
instead of a decompressed `.img`.

**Check:**
```bash
file /mnt/sdcard/tpi-images/your-image.img
# good: DOS/MBR boot sector, or Linux rev 1.0 filesystem
# bad:  XZ compressed data
```

---

### NEVER interrupt a running `tpi flash`

Killing `tpi flash` mid-way leaves the eMMC partially written. The node will not
boot and may not automatically enter maskrom on the next power-on. See §2 for
recovery.

---

## 2. Node stuck / not entering maskrom

RK1/RK3588 nodes with blank or corrupted eMMC should enter maskrom automatically
on power-up. The BMC routes USB to the node and `tpi flash` detects the device.
If maskrom enumeration fails, `tpi flash` hangs indefinitely.

### Step 1 — Check if the node is already in maskrom

```bash
lsusb | grep 2207
# Bus 001 Device 024: ID 2207:350b  ← ready to flash
```

| USB entry | Meaning |
|---|---|
| `2207:350b` | RK3588 in maskrom — ready to flash |
| `2207:330c` | Loader mode |
| (nothing) | Node powered off or booted to OS |

If `2207:350b` is shown, go directly to Step 3.

### Step 2 — Force a clean power cycle

```bash
tpi power off      # power off ALL nodes
sleep 15           # let capacitors discharge fully
tpi flash -n <N> --local --image-path /path/to/image.img
```

`tpi flash` manages power and USB routing internally. Do **not** `tpi power on`
before running flash — let the flash command handle it.

### Step 3 — Flash immediately

```bash
tpi flash -n <N> --local --image-path /mnt/sdcard/tpi-images/your-image.img
```

### Step 4 — Manual USB routing (if Step 2 fails)

```bash
tpi usb device -n <N>
sleep 2
tpi power on -n <N>
sleep 5
lsusb | grep 2207
# if 2207:350b appears, run tpi flash immediately (do NOT power off first)
```

If `lsusb` shows nothing after this sequence, check whether bmcd is stuck
(see [§3](#3-bmcd-daemon-stuck)).

---

## 3. bmcd daemon stuck

`tpi` CLI is a REST client. `bmcd` (the HTTP daemon on the BMC) handles all `tpi`
commands. An interrupted flash can leave bmcd in an uninterruptible kernel sleep
waiting on a frozen USB transaction.

### Symptoms

| Symptom | Likely state |
|---|---|
| `tpi power status` works, `tpi info` hangs | Partially stuck |
| All `tpi` commands hang | Fully stuck |
| `ps aux` shows `[bmcd]` in brackets | D-state — cannot be killed |

### Diagnosis

```bash
ps aux             # [bmcd] = D-state (bad); /usr/bin/bmcd = normal
ss -tlnp           # bmcd listens on :80 and :443
```

### Recovery

**bmcd running normally** (not in brackets):
```bash
kill -HUP $(pgrep bmcd)
sleep 3
tpi info
```

**bmcd in D-state** (`[bmcd]`): `kill -9` will not work. The USB operation
blocking the kernel must be interrupted at the hardware level.

1. **Web UI reboot** — open `http://<BMC_IP>` in a browser and use the reboot
   button (may still work if the HTTP server thread is alive)

2. **Physical power cycle** — unplug TuringPi from mains, wait 10 seconds, plug
   back in. BMC takes ~60 seconds to boot. SSH session will disconnect.

After either recovery, remount the SD card before attempting to flash again
(see [§5](#5-sd-card-not-mounted-after-bmc-reboot)).

---

## 4. BMC connectivity and auth

### SSH password prompt on every command

`bmc_cmd` opens a new SSH connection for each bootstrap command. To avoid
repeated password prompts:
```bash
ssh-copy-id root@<BMC_IP>
```
Or set `BMC_PASS` in `bootstrap-config.kv` (keep the file `chmod 600` and
out of git, ideally in `~/.turingpi/`).

### `tpi --host <IP>` from laptop hangs

**Cause:** The `tpi` CLI uses the HTTP API when given `--host`. The API prompts
for web UI credentials that the CLI cannot satisfy non-interactively — it waits
for stdin that never comes.

**Fix:** All `tpi` calls in the bootstrap script run on the BMC via SSH
(`bmc_cmd`) rather than using `--host` from the laptop.

**Workaround in a running script:** Press Ctrl+C. The CLI submits empty
credentials, gets "credentials incorrect", exits, and the bootstrap logs a
WARNING and continues.

### Connectivity pre-check fails

```bash
ping -c 1 <BMC_IP>
ssh root@<BMC_IP> echo ok
```

If SSH fails: verify `BMC_PASS` or SSH key. If ping fails: run A1 (BMC
discovery) or set `BMC_HOST` explicitly in `bootstrap-config.kv`.

---

## 5. SD card not mounted after BMC reboot

After any BMC reboot (`tpi reboot` or physical power cycle), the SD card at
`/mnt/sdcard` is **not** automatically remounted.

```bash
# Check
ls /mnt/sdcard/tpi-images/

# Find the partition (largest ext4 mmcblk partition)
blkid | grep mmcblk

# Mount
mount /dev/<partition> /mnt/sdcard
```

The bootstrap script's A3 stage checks and mounts automatically. When running
`tpi flash` manually after a BMC reboot, always mount first.

**Auto-detect one-liner** (run on BMC):
```bash
for p in /dev/mmcblk*p*; do
  [ -b "$p" ] || continue
  grep -q "^$p " /proc/mounts && continue
  fs=$(blkid -s TYPE -o value "$p" 2>/dev/null)
  case "$fs" in ext2|ext3|ext4) ;; *) continue ;; esac
  sz=$(cat /sys/class/block/${p##*/}/size 2>/dev/null || echo 0)
  echo "$sz $p"
done | sort -rn | head -1 | awk '{print $2}'
```

---

## 6. tpi power / status hangs from laptop

Same root cause as §4 auth — `tpi --host` needs web UI credentials.

**Permanent fix:** All `tpi_power`, `tpi_status`, and `bmc_firmware_version`
calls in the bootstrap script now run on the BMC via `bmc_cmd` (SSH).

---

## 7. Network discovery

### BMC virtual NICs are not node network interfaces

`ifconfig` on the BMC shows interfaces named `node1`, `node2`, etc. These are
**BMC-internal virtual NICs**, not the network interfaces inside the RK1 OS. Do
not use them to infer node IP or network state. Discover node IPs via `nmap`.

### Node-to-slot mapping unknown

**Symptom:** 4 IPs appear after power-on but there is no way to know which IP is
which slot.

**Cause:** All RK1 Ubuntu images boot with hostname `ubuntu` and DHCP assigns
addresses non-deterministically.

**Fix:** Power nodes on one at a time using `tpi power on -n <N>` and run
`nmap -sn 192.168.1.0/24` between each. The new IP that appears = the slot just
powered on. This is exactly what stage A4 does.

### Discovery fails if nodes are already on

**Cause:** A4's discovery works by correlating which IP appears when a specific
node powers on. If all nodes are already on, there is no differential to observe.

**Fix:** Always run from A2 (power off all) if the slot→IP mapping is unknown.

### nmap shows stale hostname after rename

**Symptom:** After `hostnamectl set-hostname rk1-node1`, nmap still shows `ubuntu`.

**Fix:** Force a DHCP renewal on the node:
```bash
sudo dhclient -r end0 && sudo dhclient end0
# or simply: sudo reboot
```
For reliable resolution, maintain `/etc/hosts` on the laptop — the bootstrap
stage A6 does this automatically.

### DHCP-assigned IPs can change across reboots

Node IPs are only stable as long as DHCP leases hold. After router restart or
long power-off, IPs may change. The bootstrap state file (`bootstrap-state.kv`)
stores discovered IPs and must be updated if they drift. Long-term fix: DHCP
reservations keyed to MAC addresses, or MetalLB VIPs for services.

---

## 8. SSH to nodes

### Default credentials on fresh RK1 images

Ubuntu images for RK1 ship with `ubuntu` / `ubuntu`. Stage A5 changes the
password immediately after first boot.

### SSH host key changes after reflash

**Symptom:** `ssh ubuntu@rk1-node1` fails with "WARNING: REMOTE HOST
IDENTIFICATION HAS CHANGED".

**Fix:**
```bash
ssh-keygen -R rk1-node1
ssh-keygen -R <node-ip>
```
The bootstrap script uses `-o StrictHostKeyChecking=no -o
UserKnownHostsFile=/dev/null` for all automated node SSH connections.

### Set up SSH keys as early as possible

The Expect wrapper is only needed while nodes require password auth. Once SSH
keys are distributed and `NOPASSWD` sudo is configured, all scripts can use
plain `ssh`/`scp`, which are simpler and more debuggable. Add key distribution
to stage A5.

---

## 9. Docker

### Snap Docker conflicts with k3s/containerd

**Symptom:** k3s cannot see images pulled by Docker; socket and storage paths
differ from standard.

**Cause:** Snap Docker runs in a confined environment with paths under
`/var/snap/docker/...`. k3s/containerd does not use the snap Docker daemon.

**Fix:** Remove snap Docker first, then install the apt package:
```bash
sudo snap remove docker
sudo apt install docker.io
```
Never mix snap and apt Docker on the same machine.

### Wrong package name on Ubuntu

```bash
# Wrong — no such package:
sudo apt install docker

# Correct:
sudo apt install docker.io
```

### Docker daemon not running / permission denied

```bash
sudo systemctl enable --now docker
# For your user:
sudo usermod -aG docker $USER && newgrp docker
```

### HTTP→HTTPS error pulling from local registry

**Symptom:** `Error response from daemon: Get "https://rk1-node1:5000/v2/":
http: server gave HTTP response to HTTPS client`

**Fix:** Add to `/etc/docker/daemon.json`:
```json
{
  "insecure-registries": [
    "<node1-ip>:5000",
    "rk1-node1:5000"
  ]
}
```
Then `sudo systemctl restart docker`. List **both** IP and hostname forms — a
missing form still triggers the HTTPS error for that form.

### JSON errors crash Docker daemon

JSON does not allow comments, trailing commas, or non-ASCII quotes.
Always validate before restarting:
```bash
jq . /etc/docker/daemon.json
```

### daemon.json changes have no effect

**Cause:** A systemd drop-in, snap leftover, or UTF-8 BOM is causing a different
config to be loaded.

**Check:**
```bash
systemctl cat docker.service    # look for --config-file or --insecure-registry flags
ps -ef | grep dockerd           # check actual flags in use
```

### Registry container stops on Docker daemon restart

**Fix:** Always start the registry with `--restart=always`:
```bash
docker run -d --name registry --restart=always -p 5000:5000 registry:2
```

### Running commands on the wrong machine

Always verify the shell prompt before running node-side commands:
`ubuntu@rk1-node1:~$` vs `user@laptop:~$`. When in doubt: `hostname`.

---

## 10. TLS / certificates

### x509: certificate signed by unknown authority

**Cause:** Three separate trust stores must all be updated:

| Client | Trust store location |
|---|---|
| Laptop Docker Engine | `/etc/docker/certs.d/<host:port>/ca.crt` |
| RK1 OS system store | `/usr/local/share/ca-certificates/myCA.crt` + `update-ca-certificates` |
| k3s / containerd | OS store + `/etc/rancher/k3s/registries.yaml` (`tls.ca_file`) |

These are **independent** — installing the CA for Docker on the laptop does not
cover k3s on the nodes, and vice versa.

### SAN mismatch — wrong hostname or IP in cert

**Symptom:** TLS fails with SAN mismatch even though the CA is trusted.

**Cause:** The cert was generated without including the exact hostname or IP the
client uses to connect. Common mistake: using the laptop IP instead of the
registry node IP in `REG_HOST_IP`.

**Fix:** `REG_HOST_DNS` and `REG_HOST_IP` in `gen-registry-certs.sh` must
identify the machine *running* the registry (e.g., `rk1-node1` /
`<node1-ip>`), not the laptop. Include both hostname and IP forms in the SAN
list.

### When changing registry IP, regenerate the cert

After switching to a MetalLB VIP, add the new IP to `REG_SAN_IP` and rerun
`gen-registry-certs.sh`. The CA cert stays the same; only `registry.crt` changes.

### Clock drift causes intermittent TLS failures

Ensure NTP is running on all nodes:
```bash
timedatectl status
sudo systemctl status systemd-timesyncd
```

---

## 11. k3s / Kubernetes

### `kubectl` connects to 127.0.0.1:8080 (connection refused)

**Cause:** k3s writes its kubeconfig for local use only. The laptop has no
kubeconfig and falls back to the unauthenticated default.

**Fix:**
```bash
scp ubuntu@rk1-node1:/etc/rancher/k3s/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config
# Edit the server: line from 127.0.0.1:6443 to https://rk1-node1:6443
kubectl cluster-info    # verify
```

### k3s API server SAN mismatch when accessed remotely

**Cause:** k3s installed without `--tls-san` only includes `127.0.0.1` in the
API cert.

**Fix:** Install with SAN flags:
```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--node-name rk1-node1 \
    --write-kubeconfig-mode 644 \
    --tls-san rk1-node1 \
    --tls-san <node1-ip>" \
  sh -
```
If already installed without these, reinstall (k3s install is idempotent; state
is in `/var/lib/rancher/k3s/`).

### k3s agent token

The token is at `/var/lib/rancher/k3s/server/node-token` on the server node:
```bash
ssh ubuntu@rk1-node1 'sudo cat /var/lib/rancher/k3s/server/node-token'
```
Used in the agent install:
```bash
K3S_URL="https://rk1-node1:6443" K3S_TOKEN="<token>" \
  INSTALL_K3S_EXEC="--node-name rk1-node2" \
  curl -sfL https://get.k3s.io | sh -
```

### registries.yaml changes require restart

```bash
sudo systemctl restart k3s          # server node
sudo systemctl restart k3s-agent    # agent nodes
```

### kubectl create secret fails if secret already exists

k3s install is idempotent; secret creation is not. Use:
```bash
kubectl delete secret <name> -n <ns> || true
kubectl create secret <name> ...
```

---

## 12. Registry — Phase A (HTTP)

### All clients must opt in to insecure registry

Every machine that pushes or pulls during Phase A needs:

**Docker clients** — `/etc/docker/daemon.json`:
```json
{
  "insecure-registries": ["<node1-ip>:5000", "rk1-node1:5000"]
}
```

**k3s/containerd** — `/etc/rancher/k3s/registries.yaml`:
```yaml
mirrors:
  rk1-node1:5000:
    endpoint:
      - "http://rk1-node1:5000"
```
Note the explicit `http://` scheme. Omitting it or using `https://` causes
containerd to attempt TLS.

---

## 13. Registry — Phase B (TLS + auth)

### Registry is open to LAN by default

`registry:2` accepts all connections without authentication unless explicitly
configured.

**Fix:** Generate `htpasswd` with bcrypt and create a Kubernetes secret:
```bash
htpasswd -Bbn push 'YourSecret' > htpasswd
kubectl -n registry create secret generic registry-htpasswd \
  --from-file=htpasswd=./htpasswd
```

### 401 Unauthorized after enabling auth

```bash
docker login https://<REG_ADDR>:5000
```

### Recommended migration order: TLS first, then auth

Enable TLS and verify end-to-end trust before adding auth. Chasing a TLS failure
and an auth failure simultaneously is confusing. Sequence:

1. Deploy registry with `tls.enabled: true`, `auth.enabled: false`
2. Confirm `curl https://<REG_ADDR>:5000/v2/` returns 200 (no creds needed)
3. Flip `auth.enabled: true`
4. Confirm `curl` returns 401; `docker login` succeeds; `docker push` works

### Registry delete API is disabled by default

`registry:2` does not allow image deletion unless explicitly enabled.

**Fix:** Add to `registry.extraEnv` in `values.yaml`:
```yaml
registry:
  extraEnv:
    - name: REGISTRY_STORAGE_DELETE_ENABLED
      value: "true"
```
Then restart the registry pod.

### Creating TLS/auth secrets outside Helm (recommended)

Create Kubernetes secrets with `kubectl` directly so credentials never appear in
chart values or git. Reference them by name in `values.yaml`:
```bash
kubectl -n registry create secret tls registry-tls \
  --cert=registry-certs/registry.crt --key=registry-certs/registry.key
kubectl -n registry create secret generic registry-htpasswd \
  --from-file=htpasswd=./htpasswd
```
Keep secret names consistent with the chart's `values.yaml` (`tls.secretName`,
`auth.secretName`).

---

## 14. Expect script / bootstrap automation

### Prompt patterns: never use `$` end-of-line anchor

Interactive prompts (`Password:`, `User:`) have no trailing newline before the
cursor. The `$` anchor requires one and will never match.

```tcl
# Wrong — never matches:
expect -re {Password:\s*$}

# Correct:
expect -re {[Pp]assword:}
```

### Doubled output in `bmc_stream`

If output appears twice, `log_user 1` (the default) is active while also
explicitly printing with `puts`. Set `log_user 0` before the expect block and
`log_user 1` after.

### `tpi flash` exits 0 on failure

`tpi flash` returns exit code 0 even when flashing fails. Always check output:
```tcl
if {$rc != 0 || [string match "*Error occured*" $output]} {
  die "flash failed"
}
```

### `bmc_cmd` timeout for large file operations

The default 30-second timeout is too short for `sha256sum` on a 4+ GB image
(2-3 minutes on BMC hardware). Pass an explicit timeout:
```tcl
lassign [bmc_cmd "sha256sum $path" 300] rc out
```

### Tcl brace conflicts with JSON in state files

Tcl's `{}` are code-block delimiters. JSON's `{}` object syntax triggers parse
errors (`invalid command name "}"`, `extra characters after close-brace`) when
manipulated with Tcl regex. Use `key=value` format with `Tcl dict` for all
state files — it is trivial to parse and has no syntax conflicts.

### Dry-run must guard all interactive prompts and `die` calls

Any `ask_secret`, `die`, or network call not guarded by `if {!$dry}` will break
dry-run mode. Pattern: in dry-run, `say "DRY: ..."` and return early from each
section that would touch hardware or prompt for input.

### `--phase` overrides `--from`

When both `--phase A` and `--from StageName` are passed, `--phase` wins and
sets the start stage to the first stage of the phase. Use `--from` and `--to`
without `--phase` to resume from a specific stage:
```bash
./bootstrap-turingpi-cluster.exp \
  --from A4_power_on_and_discover \
  --to A7_ephemeral_registry_phaseA \
  --flash bmc --manifest images-manifest-bmc.kv
```

---

## 15. General lessons learned

**Use Expect only for out-of-band bootstrap operations.** Expect is right for
one-time interactive tasks: BMC power, initial SSH, password changes, node
discovery. Everything inside the cluster should use Helm/Kustomize + GitOps
(Argo CD/Flux). Mixing Expect with `kubectl apply` creates snowflake states.

**Docker Engine vs containerd are separate trust systems.** The laptop's
`/etc/docker/certs.d/` path means nothing to k3s/containerd on the nodes.
Each system has its own trust store and must be configured independently.

**JSON in configuration files must be valid JSON.** No comments, no trailing
commas, no curly quotes. Always `jq . <file>` before restarting any daemon.

**Set up SSH key-based auth as early as possible.** The entire Expect wrapper
exists because nodes require password auth during bootstrap. Once keys are
distributed and `NOPASSWD` sudo is configured, plain `ssh`/`scp` calls replace
all of it — simpler and more debuggable.

**DHCP IPs are not stable long-term.** Use DHCP reservations (MAC → IP) on
the router and/or MetalLB VIPs for services that need stable addresses. Update
`bootstrap-state.kv` whenever node IPs change.

**Credentials belong in `~/.turingpi/credentials.kv` (chmod 600), not in the
repo.** For Phase B hardening (Tailscale, reverse proxy), rotate default
`ubuntu`/`ubuntu` credentials and store the new ones in `~/.turingpi/` where
they are gitignored and user-read-only.
