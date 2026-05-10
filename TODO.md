# What work is needed to make it production-ready?

There are a few buckets of work: [Phase B–D implementation](#phase-b-k3s--persistent-registry), [testing and QA](#tests-and-test-coverage), [extended features](#extended-feature-set), and glue work (docs, legal, process).

---

## Phase B — k3s + Persistent Registry

**Prerequisite:** All 4 nodes and the BMC must have stable IPs before any Phase B work. All k3s TLS SANs and registry cert SANs are baked into certs at install time — IP changes later require re-issuing certs.

Static IP scheme: BMC=TPI_BASE_IP_ADDR, node N=base+N. Configure TPI_BASE_IP_ADDR, GATEWAY, DNS_SERVERS in bootstrap-config.kv.

### B0 — Pre-flight

- [ ] Run `./setup-static-ips.sh` — configures netplan on all 4 nodes and updates `bootstrap-state.kv` + `/etc/hosts`
- [ ] Set up SSH key-based auth on all nodes + passwordless `sudo` — eliminates the need for Expect wrappers in Phase B+ scripts; the full `make`-based automation depends on this
- [ ] Create `bootstrap.env` (see template below) as the single config source for all Phase B scripts
- [ ] Create `bootstrap.env.example` (committed) documenting all vars; add `bootstrap.env` to `.gitignore`

**`bootstrap.env` variables to document:**
```
K3S_SERVER_HOST=rk1-node1
K3S_SERVER_IP=<TPI_BASE_IP_ADDR+1>
RK1_NODES=(rk1-node1 rk1-node2 rk1-node3 rk1-node4)
SSH_USER=ubuntu
SSH_PASS=          # blank = use SSH keys
API_SAN_1=rk1-node1
API_SAN_2=<TPI_BASE_IP_ADDR+1>
REG_HOST_IP=<TPI_BASE_IP_ADDR+1>   # switch to MetalLB VIP when available
REG_PORT=5000
REG_ADDR=<REG_HOST_IP>:<REG_PORT>
REG_USERNAME=push
REG_PASSWORD=<secret>
CERT_DIR=./registry-certs
DRY_RUN=0
```

### B1 — k3s Install

- [ ] Write `install-k3s-server.sh` — idempotent; install k3s on rk1-node1 with:
  - `--node-name rk1-node1`
  - `--write-kubeconfig-mode 644`
  - `--tls-san rk1-node1 --tls-san <node1-ip>` (required for remote kubectl — add both hostname and IP; if omitted, kubectl gets SAN mismatch and k3s must be reinstalled)
- [ ] Write `install-k3s-agent.sh` — idempotent; reads `SERVER_URL`, `TOKEN`, `NODE_NAME` from env; joins nodes 2–4
- [ ] Write `prep-kubeconfig-local.sh` — copies `/etc/rancher/k3s/k3s.yaml` from rk1-node1 to `~/.kube/config`, rewrites server field from `127.0.0.1:6443` to `https://rk1-node1:6443`; uses `yq` with `sed` fallback
- [ ] Verify: `kubectl get nodes` shows all 4 nodes Ready

### B2 — Persistent Registry (TLS + Auth)

Designed stage sequence:

- [ ] **B2-certs**: Update and run `gen-registry-certs.sh` (multi-SAN version):
  - Generate private CA (`myCA.key` + `myCA.crt`), valid 10 years
  - Generate registry server cert signed by CA; valid ~27 months (`-days 825`)
  - SAN arrays: `REG_SAN_DNS=("rk1-node1" "registry.home")` and `REG_SAN_IP=("<node1-ip>" "<MetalLB-VIP-when-available>")` — include MetalLB VIP proactively so cert doesn't need regenerating when MetalLB is added
  - Wildcards allowed for DNS SANs, not for IPs
  - Idempotent: do not regenerate CA if `myCA.key` already exists
  - Output to `./registry-certs/`; **never** commit `myCA.key` or `registry.key`
  - `myCA.key` never leaves the laptop and never enters the cluster

- [ ] **B2-storage**: Mount SSD, move registry data to `/mnt/ssdA/registry`; create `local-ssd` StorageClass (RWO) and `nfs-rwx` StorageClass (RWX, for future shared volumes)

- [ ] **B2-htpasswd**: Generate htpasswd with bcrypt: `htpasswd -Bbn push <secret> > htpasswd`

- [ ] **B2-registry-upgrade**: Replace ephemeral Phase A container with TLS+auth Helm chart deployment:
  - Write `/opt/registry/config.yaml` with TLS + htpasswd sections (or use `registry-chart/` Helm chart)
  - Auth toggle: **start with `auth.enabled: false`** to verify TLS works end-to-end first, then flip to `true` — avoids chasing two problems at once
  - Registry delete API is **disabled by default** in `registry:2`; enable with `REGISTRY_STORAGE_DELETE_ENABLED=true` in `registry.extraEnv` if needed

- [ ] **B2-ca-distribute**: Write `install-ca.sh` — run per node:
  - `scp myCA.crt ubuntu@<node>:/usr/local/share/ca-certificates/registry-ca.crt`
  - `ssh ubuntu@<node> sudo update-ca-certificates`
  - Write `/etc/rancher/k3s/registries.yaml` with `tls.ca_file`
  - `sudo systemctl restart k3s` / `k3s-agent`

- [ ] **B2-containerd-mirrors**: Write `registries.yaml` on each node for containerd mirror config; restart k3s/k3s-agent

- [ ] Write `setup-registry-after-certs.sh` orchestrating steps above (laptop-side: Docker trust + kubectl secrets + per-node CA install loop)

- [ ] **B2-verify**: End-to-end smoke test — `docker login`, `docker push`, k3s pull from cluster registry

### B3 — Makefile (Orchestration Layer)

- [ ] Write `Makefile` with targets:
  - `make discover` — runs `discover-nodes.sh`, writes `node-map.kv`
  - `make k3s-server` — SSH installs k3s server on `K3S_SERVER_HOST`
  - `make k3s-agents` — reads token from server, installs k3s-agent on remaining nodes
  - `make kubeconfig` — runs `prep-kubeconfig-local.sh`
  - `make certs` — runs `gen-registry-certs.sh`
  - `make registry-setup` — runs `setup-registry-after-certs.sh`
  - `make registry-helm` — `helm upgrade --install registry ./registry-chart -n registry --create-namespace --set service.port=$(REG_PORT)`
  - `make all` — chains: discover → k3s-server → k3s-agents → kubeconfig → certs → registry-setup
  - All targets respect `DRY_RUN=1`; loads `bootstrap.env` and `node-map.kv` automatically
  - Target user experience: "Edit `bootstrap.env` once, run `make all`, run `make registry-helm`."

- [ ] Write `discover-nodes.sh` — tries DNS first (`getent hosts`), falls back to `nmap -sn <subnet>` + SSH hostname probe; outputs `node-map.kv`; add `node-map.kv` to `.gitignore`

### B4 — GitOps Controller

- [ ] Install Argo CD or Flux (decision: Argo CD is lower barrier; Flux is more GitOps-pure)
- [ ] Create platform repo structure:
  ```
  platform/
    apps/
      multi-agent/
        helm/
          Chart.yaml        # umbrella chart
          values-dev.yaml
          charts/
            agent-perf/
            agent-pair/
            agent-buildopt/
        README.md
    infra/
      ingress/              # Traefik / MetalLB config
      messaging/            # Redis or NATS via HelmRelease
      storage/              # StorageClass, PVC templates
    argo/
      application.yaml      # Argo CD app pointing at apps/multi-agent
  ```
- [ ] Write `argo/application.yaml` pointing at `apps/multi-agent`
- [ ] Create `docs/CLUSTER-DEFAULTS.md` (platform contract): registry address + naming convention, namespace structure, StorageClass names, Ingress hostname patterns, standard port (8080), health endpoint paths (`/healthz`, `/ready`), resource request defaults

### B5 — MetalLB

- [ ] Install MetalLB; assign stable VIP for registry service
- [ ] After MetalLB: update `REG_HOST_IP` in `bootstrap.env` to the VIP, run `make certs` (regenerate `registry.crt` with new SAN), run `make registry-setup`
- [ ] The CA cert (`myCA.crt`) does **not** need regenerating — only the server cert changes
- [ ] Pick a single canonical registry address (hostname or VIP) and use it everywhere to avoid confusion and cache duplication

---

## Phase C — Resilience + Laptop Mirror

- [ ] **C1** `local_registry_mirror` — run `registry:2` on laptop configured as pull-through cache
- [ ] **C2** `skopeo_sync` — one-way laptop→cluster sync: `skopeo sync --src docker --dest docker <image> <cluster-reg>` (layer-idempotent)
- [ ] **C3** `sync_resilience` — probe script checking cluster registry health; falls back to laptop mirror if cluster registry unreachable

---

## Phase D — Multi-Agent Workloads

- [ ] Deploy multi-agent "hello world" umbrella Helm chart (`agents-dev` namespace):
  - 3 Deployments (agent-perf, agent-pair, agent-buildopt), replicas: 1 each
  - 3 ClusterIP Services
  - 1 Ingress routing `/pair`, `/perf`, `/buildopt`
  - 1 ConfigMap for shared settings (message bus URL)
  - Optional: NATS or Redis message bus (deploy via HelmRelease in `infra/messaging/`)
- [ ] Integrate Ollama; wire `/ready` endpoint to return `{"ok": false}` until Ollama reachable
- [ ] Observability: kube-prometheus-stack (defer until "hello world" is running; use `/healthz` until then)
- [ ] CI pipeline: GitHub Actions builds + pushes images to cluster registry on commit; Argo/Flux reconciles
- [ ] Secrets: SealedSecrets or SOPS — no raw secrets in git

---

## Security Hardening

- [ ] SSH key distribution + passwordless sudo on all nodes (prerequisite for full Makefile automation)
- [ ] Rotate default credentials; store in `~/.turingpi/credentials.kv` (chmod 600)
- [ ] Tailscale for remote access
- [ ] Reverse proxy (Traefik ingress, already included with k3s)
- [ ] htpasswd basic auth for registry (see Phase B2 above)
- [ ] SealedSecrets or SOPS for secret management in git (required before any CI/GitOps workflow)
- [ ] ResourceQuotas + PriorityClasses when moving to multi-tenant workloads

---

## Tests and Test Coverage

* Essentially, **test everything**, and make the code resilient before open sourcing anything
   * All stages/phases individually
      * Initial bootstrapping (Expect dryrun and stubbed(?) code)
      * GitOps workflow tests (GitHub Actions + ...)
   * All branches (in particular the flashing options)
   * Test all options that can be given

Note: The initial stage is not declarative, but imperative, so we need to test that we have reached a wanted state accordingly.

---

## Extended Feature Set

- **Reverse proxy capabilities** for remote access (and potentially for load balancing in a multi-cluster setup)
   - Requirement: security measures to harden the system
- **Multi-tenancy** for invited users
   - Compartmentalization of user data so that certain SSD volumes and/or partitions are only possible to mount for specific users
   - K8s mechanisms: separate namespaces + RBAC, per-project registry namespaces, separate PVCs/StorageClasses per tenant
- **Prioritization of application compute** based on strict hierarchy
   - Priority of user A over users B, C and D
   - Priority of application X over applications Y and Z
   - Block new compute requests given a specific GPU/NPU utilization threshold or scheduled dedicated compute time
   - Ensure graceful handling of users and applications when the above happens
   - K8s mechanisms: `ResourceQuotas` + `PriorityClasses`; NPU/GPU utilization triggers
- **External storage** — handle mounting of databases / storage on connected resources (e.g., NAS)
   - K8s mechanism: NFS/CSI StorageClass (`nfs-rwx`, RWX)
- **AI application templates** for multi-agentic setups
   - RAM pooling across compute modules is possible for non-LLM workloads (LLMs require contiguous memory)
   - These templates may live in a dedicated repository
- **Inner dev loop tooling**: Skaffold or Tilt for rapid `build → push → deploy` while coding
- **Kustomize overlays**: `dev` (active), `staging`, `prod` namespace environments
- **Cilium** CNI (replace Flannel, the k3s default): possible future upgrade without app YAML changes
