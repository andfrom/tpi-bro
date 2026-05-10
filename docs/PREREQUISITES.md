# Prerequisites

Everything you need installed on your **laptop** before running any phase of this bootstrap.
Nothing here runs on the cluster nodes — the scripts install what the nodes need remotely.

---

## Phase A

| Tool | Purpose | Install (Ubuntu/Debian) | Notes |
|------|---------|------------------------|-------|
| `bash` | All helper scripts | pre-installed | ≥ 4.0 required |
| `expect` | Drive `bootstrap-turingpi-cluster.exp` | `sudo apt install expect` | |
| `openssh-client` | SSH into nodes | `sudo apt install openssh-client` | includes `ssh-keygen`, `ssh-keyscan` |
| `sshpass` | Password-based SSH before key auth is set up | `sudo apt install sshpass` | B scripts auto-install this if missing |
| `nmap` | BMC and node discovery on LAN | `sudo apt install nmap` | |
| `curl` | Health checks, downloading k3s install script | `sudo apt install curl` | |
| `tpi` CLI | BMC power / flash / UART control | see below | does not run on nodes |

### Installing `tpi`

The `tpi` CLI talks to the TuringPi BMC. Install it on your laptop only.

```bash
# Check the TuringPi docs for the current release URL:
# https://docs.turingpi.com/docs/turing-pi2-bmc-intro-specs
#
# Example (replace VERSION and ARCH):
curl -L https://github.com/turing-machines/tpi/releases/download/vVERSION/tpi-linux-ARCH \
  -o /usr/local/bin/tpi
chmod +x /usr/local/bin/tpi

# Authenticate once (credentials cached):
tpi login
```

If mDNS (`turingpi.local`) doesn't resolve on your network, find the BMC by scanning:
```bash
nmap -sn 192.168.1.0/24   # adjust to your subnet
```

---

## Phase B (adds to Phase A)

| Tool | Purpose | Install (Ubuntu/Debian) | Notes |
|------|---------|------------------------|-------|
| `kubectl` | Manage the k3s cluster | see below | the repo ships a pinned binary in `kubectl/` |
| `helm` | Deploy Helm charts | see below | v3 required |
| `openssl` | Generate registry TLS certificates | `sudo apt install openssl` | usually pre-installed |
| `apache2-utils` | `htpasswd` for registry basic auth | `sudo apt install apache2-utils` | only needed if `auth.enabled=true` |
| `docker` | Push/pull images to the registry | see below | needed for `--verify` and day-to-day use |

### Installing `kubectl`

The repo vendors a pinned `kubectl` binary at `./bin/kubectl`. Use it directly or install system-wide:

```bash
# Use the vendored binary (no install needed):
./bin/kubectl get nodes

# Or install system-wide (replace VERSION):
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

### Installing Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Or via apt (may lag behind upstream):
```bash
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt update && sudo apt install helm
```

### Installing Docker

Follow the official guide for your OS: https://docs.docker.com/engine/install/

Quick path for Ubuntu:
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # then log out and back in
```

---

## Distribution support

| OS | Phase A | Phase B | Notes |
|----|---------|---------|-------|
| Ubuntu 22.04 LTS (Jammy) | ✓ tested | ✓ tested | |
| Ubuntu 24.04 LTS (Noble) | ✓ tested | ✓ tested | primary dev platform |
| Debian 12 (Bookworm) | ✓ should work | ✓ should work | same package names as Ubuntu |
| Debian 11 (Bullseye) | likely works | likely works | bash 5.1 available |
| Fedora / RHEL 9+ | likely works | likely works | substitute `dnf` for `apt`; `sshpass` in EPEL; `apache2-utils` → `httpd-tools` |
| Arch Linux | likely works | likely works | all tools in `extra`/AUR |
| macOS (Homebrew) | partial | partial | `bash` must be ≥ 4 (`brew install bash`); `sshpass` needs a tap; `systemd-run` not available but scripts don't require it on the laptop side |
| Windows WSL2 (Ubuntu) | ✓ likely works | ✓ likely works | run inside an Ubuntu 22.04 or 24.04 WSL instance |

> macOS ships bash 3.2 (GPLv2). The scripts use bash 4+ features (`[[ ]]`, arrays, `local -n`). Either install `brew install bash` and invoke with `/opt/homebrew/bin/bash`, or run inside Docker/WSL.

---

## Quick install (Ubuntu/Debian one-liner)

Installs everything needed for Phase A and Phase B:

```bash
sudo apt update && sudo apt install -y \
  expect openssh-client sshpass nmap curl \
  openssl apache2-utils
```

Then install `tpi`, `kubectl`, `helm`, and `docker` separately using the steps above.
