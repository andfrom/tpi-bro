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

## Network Layer (N-01: Tailscale)

Tailscale makes the cluster a seamless network extension of the laptop — no
port-forwarding, stable DNS names for every service. Three manual steps are
required before running the scripts; everything else is automated.

### Step 1 — Create a Tailscale account and install on the laptop

Tailscale's onboarding requires at least two devices before you can access the
admin console. Install on the laptop first (device 1):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up   # opens a browser tab to log in / create an account
```

The second device is added in Step 2.

### Step 2 — Add node1 manually (satisfies the "second device" onboarding requirement)

Until you have an auth key, the first node must be added interactively:

```bash
ssh ubuntu@192.168.1.11 "curl -fsSL https://tailscale.com/install.sh | sudo sh && sudo tailscale up"
```

This prints a `https://login.tailscale.com/a/...` URL — open it in a browser to
authenticate node1. Tailscale onboarding then completes and you gain access to
the admin console. Nodes 2–4 are added automatically by the script in Step 4.

### Step 3 — Generate a Reusable pre-authorized auth key

Go to **<https://login.tailscale.com/admin/settings/keys>** → **Generate auth key**.

> **IMPORTANT:** Tick **Reusable** (default is Single-use — a single-use key is
> consumed on the first node and will fail for all subsequent nodes). Also tick
> **Pre-authorized** so nodes join without needing manual approval.

Set expiry to whatever maximum is available (90 days on the free tier). The key
is only used once per node to join the Tailnet — after that, devices stay
authenticated independently and can have their key expiry disabled per-device.

Add the key to `~/.turingpi/credentials.kv` (mode 600):

```bash
echo "TAILSCALE_AUTH_KEY=tskey-auth-..." >> ~/.turingpi/credentials.kv
```

### Step 4 — Run the install script (nodes 2–4)

```bash
./scripts/install-tailscale.sh   # installs on all nodes; skips node1 if already installed
```

### Step 5 — Disable device key expiry (optional but recommended)

In the Tailscale admin console, for each of the 4 nodes:
**Machines → click node → Disable key expiry**

This prevents nodes from being kicked off the Tailnet after 180 days without
any maintenance.

### Step 6 — Subnet routing (Layer 2)

Makes all ClusterIP services directly routable from the laptop:

```bash
./scripts/setup-subnet-router.sh
```

Then approve the advertised routes in the admin console:
**Machines → rk1-node1 → Edit route settings → enable both routes**

And on the laptop:
```bash
sudo tailscale up --accept-routes
```

### Step 7 — Tailscale Kubernetes operator (Layer 3)

Exposes individual services on the Tailnet by name. Requires an OAuth client:

1. Go to **<https://login.tailscale.com/admin/settings/trust-credentials>**
2. **Create the tag first** (navigating away mid-credential loses your state):
   - Click **+ Create tag** → name it `k8s-operator` → save
   - Tailscale stores it as `tag:k8s-operator`; this tag is assigned to every device the operator creates
3. Now click **+ Credential** and proceed through the two-step wizard:
   - Step 1 (Settings): give it a name (e.g. `k8s-operator`)
   - Step 2 (Scopes) → Custom scopes → tick:
     - **Devices → Core → Write** — the Tags field will appear; add `tag:k8s-operator`
     - **Keys → Auth Keys → Write** — operator needs this to create auth keys for proxy devices (`tag:k8s-operator` is added automatically)
     - **DNS → Read** — for MagicDNS hostname resolution
   - Click **Generate credential**
3. Add to `~/.turingpi/credentials.kv`:
   ```
   TAILSCALE_OAUTH_CLIENT_ID=<id>
   TAILSCALE_OAUTH_CLIENT_SECRET=<secret>
   ```
4. Deploy:
   ```bash
   ./scripts/setup-tailscale-operator.sh
   ./scripts/setup-tailscale-operator.sh --expose svc/YOUR_SERVICE -n YOUR_NAMESPACE
   ```

---

## D-04: Monitoring (Prometheus + Grafana)

The monitoring stack runs entirely on the cluster. Once deployed, Grafana is
accessible from any device on your Tailnet by name — no port-forwarding, no
`kubectl proxy`. This section walks you through deploy to your first dashboard.

**Prerequisite:** N-01 Layer 3 (Tailscale Kubernetes operator) must be running
before you deploy. The install script automatically annotates Grafana for Tailnet
exposure; without the operator, that annotation has no effect.

### Step 1 — Set a Grafana admin password

Add the password to `~/.turingpi/credentials.kv` (mode 600). Pick anything you
like — the script reads it at deploy time and passes it directly to Helm:

```bash
echo "GRAFANA_ADMIN_PASSWORD=your-password-here" >> ~/.turingpi/credentials.kv
chmod 600 ~/.turingpi/credentials.kv
```

### Step 2 — Deploy the stack

```bash
./scripts/install-monitoring.sh
```

This takes 3–5 minutes. The script:
- Adds the `prometheus-community` Helm repo
- Installs `kube-prometheus-stack` (Prometheus, Grafana, Alertmanager,
  node-exporter on every node, kube-state-metrics)
- Annotates the Grafana service so the Tailscale operator exposes it on your Tailnet

When it finishes you'll see a line like:
```
==> Done.
    Grafana: http://monitoring-kube-prometheus-stack-grafana.<tailnet>.ts.net:80
```

### Step 3 — Find your real Grafana URL

The `<tailnet>` placeholder is your Tailscale network's unique name. Look it up
in one of these ways:

```bash
# Option A — check tailscale status on your laptop (look for the domain suffix)
tailscale status | head -5

# Option B — check the Tailscale admin console
# https://login.tailscale.com/admin/machines
# Your tailnet name appears after the dot in every hostname, e.g. "tailXXXXX.ts.net"

# Option C — ask kubectl what hostname the operator assigned
kubectl get svc kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Your URL will look like:
```
http://monitoring-kube-prometheus-stack-grafana.tailXXXXX.ts.net
```

### Step 4 — Open Grafana and log in

Open the URL in your browser. You'll land on the Grafana login page.

- **Username:** `admin`
- **Password:** whatever you set in Step 1 (`GRAFANA_ADMIN_PASSWORD`)

After logging in, Grafana may prompt you to change the password — you can skip
this if you prefer to keep managing it through `credentials.kv`.

### Step 5 — Navigate to the pre-loaded dashboards

Three dashboards are provisioned automatically from grafana.com and available
immediately after deploy:

| Dashboard | What it shows |
|-----------|---------------|
| **Node Exporter Full** | Per-node CPU, RAM, disk I/O, network — the most detailed node view |
| **Kubernetes Cluster Overview** | Pod counts, resource requests vs limits, cluster-level health |
| **k3s Cluster** | k3s-specific metrics (API server, etcd SQLite, scheduler) |

To find them:

1. Click the **Dashboards** icon in the left sidebar (four squares)
2. Select **Browse**
3. All three dashboards are in the **default** folder — click any to open it

> **Tip:** The Node Exporter Full dashboard has a **node** dropdown at the top.
> Select each of `rk1-node1` through `rk1-node4` in turn to inspect individual
> nodes. Node 4 (no NVMe) will show lower disk throughput than nodes 1–3.

### Step 6 — Set the time range

Dashboards default to the last 1 hour. If the cluster was just deployed, you may
see sparse data — give Prometheus 5–10 minutes to scrape enough samples for
graphs to fill in. Use the time picker (top-right) to zoom in on recent activity.

### Step 7 — Verify all components are healthy

```bash
./scripts/install-monitoring.sh --verify
```

This shows the running Deployments, StatefulSets, DaemonSets, PVCs, and the
Grafana Tailnet service. Expect to see:

- **alertmanager** StatefulSet: 1/1
- **prometheus** StatefulSet: 1/1
- **grafana** Deployment: 1/1
- **kube-state-metrics** Deployment: 1/1
- **node-exporter** DaemonSet: 4 desired / 4 ready (one per node)
- Three PVCs in `Bound` state (Prometheus 20Gi, Grafana 5Gi, Alertmanager 2Gi)

---

## D-00: Resource policy (PriorityClasses + LimitRanges)

This is a one-time cluster setup step that makes the scheduler smarter about
what to protect when the cluster is under memory pressure. It also sets default
resource requests for any pod that forgets to specify them, so nothing gets
scheduled with zero requests and starves other workloads.

**Prerequisite:** k3s must be running and `kubectl` must reach the cluster.
Run this before deploying Ollama or any agent — the `priorityClassName` field
is silently ignored if the PriorityClass object doesn't exist yet.

### Step 1 — Apply the policy

```bash
./scripts/apply-resource-policy.sh
```

This creates two cluster-scoped PriorityClasses and one LimitRange per
workload namespace:

| PriorityClass | Value | Assigned to |
|---------------|-------|-------------|
| `interactive` | 1000 | Agent A and future user-facing agents |
| `background`  | 100  | Ollama inference pods |

Higher value = higher scheduling priority and last-to-evict under pressure.
With these in place, if the cluster runs out of memory, background workloads
(e.g. Ollama) are evicted before interactive ones (e.g. an agent).

### Step 2 — Verify the policy was applied

```bash
./scripts/apply-resource-policy.sh --verify
```

You should see `interactive` and `background` listed under PriorityClasses,
and a `LimitRange` entry in the `ollama` namespace. `apply-resource-policy.sh`
only owns tpi-bro's own platform services — applications manage their own
namespace's LimitRange (see [DEPLOYING-AN-AGENT.md](DEPLOYING-AN-AGENT.md)).

### Step 3 — Restart existing pods to pick up priorityClassName

If Ollama or an application Deployment were already running before you
applied the policy, their pods need to be restarted to get the
`priorityClassName` field:

```bash
kubectl rollout restart deployment -n ollama
kubectl rollout restart deployment -n YOUR_NAMESPACE
```

Check the new pods have the right priority:
```bash
kubectl describe pod -n ollama -l app=ollama-node1 | grep Priority
# Should show: Priority: 100 / PriorityClassName: background

kubectl get pod -n YOUR_NAMESPACE -o wide
kubectl describe pod -n YOUR_NAMESPACE -l app=YOUR_APP | grep Priority
# Should show: Priority: 1000 / PriorityClassName: interactive
```

---

## CFG-01: Personal config in `~/.turingpi/`

By default the bootstrap scripts look for config files in the repo root
(`./bootstrap-config.kv`, `./images-manifest.kv`, `./image-cache/`). That
means personal settings live inside your clone — they're gitignored, but
they also get lost if you re-clone or switch to a different machine.

You can keep everything in `~/.turingpi/` instead. The scripts check there
automatically when no repo-local file exists.

### What goes where

```
~/.turingpi/
  credentials.kv          ← already here (registry, Tailscale, Grafana secrets)
  bootstrap-config.kv     ← personal overrides (BMC host, node count, etc.)
  images-manifest.kv      ← OS image URLs + SHA256s for your hardware
  bmc-manifest.kv         ← BMC firmware version + URL
  image-cache/            ← downloaded image files (can be several GB)
```

### Setting it up

Create `~/.turingpi/bootstrap-config.kv` with your personal settings:

```bash
mkdir -p ~/.turingpi
chmod 700 ~/.turingpi
cat > ~/.turingpi/bootstrap-config.kv <<'EOF'
# Personal tpi-bro config — never committed to git
BMC_HOST=192.168.1.10
NODE_COUNT=4
MANIFEST_FILE=~/.turingpi/images-manifest.kv
IMAGE_CACHE_DIR=~/.turingpi/image-cache
EOF
```

Copy the example manifests as starting points:

```bash
cp images-manifest.kv.example ~/.turingpi/images-manifest.kv
cp bmc-manifest.kv.example    ~/.turingpi/bmc-manifest.kv
# Then edit each file to fill in your image URLs and SHA256 checksums
```

### How the fallback works

The lookup order for each script is:

1. `--config FILE` (explicit flag — always wins)
2. `./bootstrap-config.kv` (repo-local — exists during active development)
3. `~/.turingpi/bootstrap-config.kv` (user-global — used when no repo-local file)

The same fallback applies to `MANIFEST_FILE` and `IMAGE_CACHE_DIR`: if
`./images-manifest.kv` doesn't exist in the repo, the script defaults to
`~/.turingpi/images-manifest.kv`. You can also override these explicitly in
your `bootstrap-config.kv`.

> **Tip:** Once your `~/.turingpi/` is set up you can delete the gitignored
> copies from the repo root — the scripts will find the right files automatically.

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

---

## NPU model management

See [`docs/NPU-MODELS.md`](NPU-MODELS.md) for:
- Downloading pre-converted RKNN models onto cluster nodes
- Converting models from HuggingFace using the rknn-llm toolkit
- Storage layout, permissions, and quantization format guide
