# Deploying an agent onto tpi-bro

tpi-bro provides the platform primitives — the cluster, the registry, Ollama
as a service, PriorityClasses, StorageClasses, the Tailscale operator. How an
application deploys onto those primitives is the application's concern, not
tpi-bro's. This page documents the generic pattern: build an ARM64 image,
push it to the cluster registry, apply a Deployment + Service, expose it on
the Tailnet. No application names — your own repo owns its Dockerfile,
Kubernetes manifests, and build tooling (a `Makefile` target is a reasonable
place for it).

---

## One-time laptop setup: cross-building ARM64 images

The RK1 nodes are ARM64; your laptop is very likely x86_64. Cross-building
needs QEMU emulation and a `docker buildx` builder — this is a platform
concern (any application deploying to this cluster needs it), so it's
documented here rather than baked into any one application's tooling.

```bash
# Register the QEMU ARM64 binfmt handler (survives until reboot; re-run after)
docker run --privileged --rm tonistiigi/binfmt --install arm64

# Create (or reuse) the docker-container buildx builder — idempotent
./scripts/ensure-buildx-builder.sh
```

## Build and push your image

```bash
docker buildx build \
  --builder tpi-bro-builder \
  --platform linux/arm64 \
  --tag rk1-node1:5000/YOUR_IMAGE:latest \
  --file path/to/Your.Dockerfile \
  --load \
  .

# Log in with credentials from ~/.turingpi/credentials.kv, then push
echo "$REGISTRY_PASSWORD" | docker login rk1-node1:5000 -u "$REGISTRY_USER" --password-stdin
docker push rk1-node1:5000/YOUR_IMAGE:latest
```

Off-LAN (laptop not on the same network as the cluster): run
`./scripts/setup-offnet-access.sh` once, then use the Tailscale IP instead of
`rk1-node1` — see [GETTING-STARTED.md](GETTING-STARTED.md#step-6--populate-the-registry-with-your-own-images).

## Deploy

A minimal Deployment + ClusterIP Service:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: YOUR_APP
  namespace: YOUR_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels: { app: YOUR_APP }
  template:
    metadata:
      labels: { app: YOUR_APP }
    spec:
      priorityClassName: interactive   # or 'background' — see below
      containers:
        - name: YOUR_APP
          image: rk1-node1:5000/YOUR_IMAGE:latest
          ports:
            - containerPort: YOUR_PORT
          env:
            - name: OLLAMA_URL
              value: http://ollama-node1.ollama:11434   # if using Ollama
---
apiVersion: v1
kind: Service
metadata:
  name: YOUR_APP
  namespace: YOUR_NAMESPACE
spec:
  selector: { app: YOUR_APP }
  ports:
    - port: YOUR_PORT
```

```bash
kubectl apply -f your-manifest.yaml
kubectl rollout status deployment/YOUR_APP -n YOUR_NAMESPACE --timeout=120s
```

## Resource policy: PriorityClasses vs. LimitRange

tpi-bro applies two cluster-scoped `PriorityClass`es (`interactive` and
`background`, via `./scripts/apply-resource-policy.sh`) that any Deployment
can reference — pick `interactive` for user-facing/latency-sensitive
workloads, `background` for batch/bulk work that should be evicted first
under memory pressure.

**LimitRange is per-namespace and owned by the application**, not tpi-bro —
apply your own alongside your Deployment:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: YOUR_APP-defaults
  namespace: YOUR_NAMESPACE
spec:
  limits:
    - type: Container
      defaultRequest: { cpu: "100m", memory: "128Mi" }
      default: { cpu: "500m", memory: "512Mi" }
      max: { memory: "2Gi" }
```

## Expose on the Tailnet

Once the Tailscale operator is deployed (`./scripts/setup-tailscale-operator.sh`,
see [PREREQUISITES.md](PREREQUISITES.md#network-layer-n-01-tailscale)):

```bash
kubectl annotate svc YOUR_APP -n YOUR_NAMESPACE tailscale.com/expose=true
# → reachable at http://YOUR_NAMESPACE-YOUR_APP.<tailnet>.ts.net:YOUR_PORT
#   from any device on the Tailnet — no ingress, no port-forward
```

No further tpi-bro-side configuration needed — new agents self-advertise on
the Tailnet just by being annotated.
