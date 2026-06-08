# n8n + Agent Sandbox

Execute isolated Python code from an n8n workflow.

## What this example does

A manual trigger fires two parallel HTTP calls from n8n to a **bridge service**
running in the same cluster. The bridge claims a pre-warmed sandbox pod,
executes the requested command or script inside it, and returns the result to
n8n — all within a single HTTP round-trip.

```
Browser (n8n UI)
   │ click "Test workflow"
   ▼
n8n pod (n8n-demo namespace)
   │ POST /execute  {"command": "..."}   ┐  parallel
   │ POST /execute  {"script":  "..."}   ┘
   ▼
bridge pod  (n8n-sandbox-bridge)
   │ SandboxClient.create_sandbox()  →  K8s API: create SandboxClaim
   │                                 ←  sandbox pod allocated from WarmPool
   │ sandbox.commands.run(...)       →  HTTP POST sandbox-pod:8888/execute
   │                                 ←  {stdout, stderr, exit_code}
   │ sandbox.terminate()             →  K8s API: delete SandboxClaim
   ▼
n8n "Combine Results" Code node
```

**Isolation model:** each execution runs inside its own ephemeral Kubernetes pod.
The pod is claimed from a pre-warmed pool, used once, and terminated. Isolation
is at the container level — code in one execution cannot affect another
execution or the host cluster. The container's own filesystem is readable
(you see a standard Linux root), but it is completely separate from every other
pod and from the node's filesystem.

## Repository layout

```
examples/n8n-sandbox/
├── run-demo.sh              # One-shot setup for KIND (local)
├── n8n-workflow.json        # Importable n8n workflow
├── bridge/
│   ├── main.py              # FastAPI bridge — n8n → Python SDK → sandbox
│   ├── Dockerfile
│   └── requirements.in
└── k8s/
    ├── namespace.yaml        # n8n-demo namespace
    ├── sandbox-template.yaml # SandboxTemplate (python-runtime image)
    ├── sandbox-warmpool.yaml # 2 pre-warmed sandbox pods
    ├── bridge.yaml           # Bridge Deployment + RBAC + Service
    └── n8n.yaml              # n8n Deployment + Service
```

---

## Option A — Local with KIND

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker | ≥ 20.10 | https://docs.docker.com/get-docker/ |
| KIND | ≥ 0.20 | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| kubectl | ≥ 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| curl | any | pre-installed on most systems |

### Quick start

```bash
cd examples/n8n-sandbox
./run-demo.sh
```

The script:
1. Creates a KIND cluster named `n8n-sandbox-demo`
2. Installs the Agent Sandbox controller + extensions CRDs
3. Builds the bridge Docker image and loads it into KIND
4. Applies all Kubernetes manifests
5. Waits for all pods to be ready
6. Port-forwards n8n to `http://localhost:5678`

To pin a specific controller version:

```bash
AGENT_SANDBOX_VERSION=v0.4.6 ./run-demo.sh
```

### Teardown

```bash
kind delete cluster --name n8n-sandbox-demo
```

---

## Option B — GKE (Google Kubernetes Engine)

### Prerequisites

| Tool | Install |
|------|---------|
| gcloud CLI | https://cloud.google.com/sdk/docs/install |
| kubectl | `gcloud components install kubectl` |
| Docker | https://docs.docker.com/get-docker/ |

### 1. Create a GKE cluster

```bash
gcloud container clusters create n8n-sandbox-demo \
  --zone us-central1-a \
  --num-nodes 3 \
  --machine-type e2-standard-4

gcloud container clusters get-credentials n8n-sandbox-demo --zone us-central1-a
```

### 2. Install the Agent Sandbox controller

```bash
# Pin a version or use the latest (v0.4.6 tested)
AGENT_SANDBOX_VERSION=v0.4.6
BASE_URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}"
kubectl apply -f "${BASE_URL}/manifest.yaml"
kubectl apply -f "${BASE_URL}/extensions.yaml"

kubectl rollout status deployment/agent-sandbox-controller \
  -n agent-sandbox-system --timeout=120s
```

### 3. Build and push the bridge image

```bash
PROJECT_ID=$(gcloud config get-value project)
REGION=us-central1
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/n8n-sandbox/n8n-sandbox-bridge:latest"

# Create the Artifact Registry repository (once)
gcloud artifacts repositories create n8n-sandbox \
  --repository-format=docker \
  --location=${REGION} || true

gcloud auth configure-docker ${REGION}-docker.pkg.dev

docker build -t "${IMAGE}" examples/n8n-sandbox/bridge
docker push "${IMAGE}"
```

### 4. Update bridge.yaml with your image

Edit `k8s/bridge.yaml` and replace the `image:` line:

```yaml
image: <YOUR_IMAGE>      # e.g. us-central1-docker.pkg.dev/my-project/n8n-sandbox/n8n-sandbox-bridge:latest
imagePullPolicy: Always  # change from IfNotPresent
```

### 5. Apply manifests

```bash
cd examples/n8n-sandbox

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/sandbox-template.yaml
kubectl apply -f k8s/sandbox-warmpool.yaml
kubectl apply -f k8s/bridge.yaml
kubectl apply -f k8s/n8n.yaml
```

### 6. Wait for pods

```bash
kubectl rollout status deployment/n8n-sandbox-bridge -n n8n-demo --timeout=120s
kubectl rollout status deployment/n8n -n n8n-demo --timeout=180s

# Warm pool (wait for at least 1 ready sandbox)
kubectl get sandboxwarmpool -n n8n-demo -w
```

Expected pod list once ready:

```
n8n-7b48f97889-xxxx             1/1  Running
n8n-sandbox-bridge-xxxx         1/1  Running
n8n-sandbox-warmpool-xxxx       1/1  Running   # ×2 (or more)
```

### 7. Access n8n

```bash
kubectl port-forward svc/n8n-svc 5678:5678 -n n8n-demo
```

Open `http://localhost:5678`.

### Teardown

```bash
gcloud container clusters delete n8n-sandbox-demo --zone us-central1-a
```

---

## Using the workflow

1. Open `http://localhost:5678`
2. Create an account (first run only)
3. Click **+ New workflow** → **⋮** (top-right) → **Import from file**
4. Select `examples/n8n-sandbox/n8n-workflow.json`
5. Click **Test workflow** — both sandbox executions run in parallel

### Verify via curl (without the UI)

You can also test the bridge directly:

```bash
kubectl port-forward svc/n8n-sandbox-bridge-svc 8001:8000 -n n8n-demo

# Health check
curl http://localhost:8001/healthz
# → {"status":"ok"}

# Run a shell command
curl -s -X POST http://localhost:8001/execute \
  -H "Content-Type: application/json" \
  -d '{"command": "python3 -c \"print(42)\""}'
# → {"stdout":"42\n","stderr":"","exit_code":0}

# Run a Python script
curl -s -X POST http://localhost:8001/execute \
  -H "Content-Type: application/json" \
  -d '{"script": "primes = [x for x in range(2,20) if all(x%i!=0 for i in range(2,x))]\nprint(primes)\n"}'
# → {"stdout":"[2, 3, 5, 7, 11, 13, 17, 19]\n","stderr":"","exit_code":0}
```

---

## How it works

### Bridge service (`bridge/main.py`)

A minimal FastAPI app with a single endpoint:

```
POST /execute
  Body: {"command": "<shell string>"}   — or —
  Body: {"script":  "<python source>"}

Response: {"stdout": "...", "stderr": "...", "exit_code": 0}
```

It uses the Python SDK in **in-cluster mode** (`SandboxInClusterConnectionConfig`),
which connects directly to each sandbox pod via cluster-internal DNS:

```
http://{sandbox-id}.n8n-demo.svc.cluster.local:8888
```

No sandbox router is required.

### SandboxTemplate (`k8s/sandbox-template.yaml`)

Two settings are intentional:

| Field | Value | Why |
|-------|-------|-----|
| `spec.service` | `true` | Creates a headless Service per sandbox pod, enabling DNS-based routing |
| `spec.networkPolicyManagement` | `Unmanaged` | Skips auto-generated NetworkPolicy (needed on KIND; safe on GKE) |

### SandboxWarmPool (`k8s/sandbox-warmpool.yaml`)

Keeps **2 sandbox pods** pre-started. When the bridge calls `create_sandbox()`,
it gets an already-running pod in < 1 second. The pool replenishes automatically
after each claim.

### n8n workflow (`n8n-workflow.json`)

| Node | Type | What it does |
|------|------|-------------|
| When clicking 'Test workflow' | Manual Trigger | Fires the workflow |
| Run Shell Command | HTTP Request | `POST /execute {"command": "python3 -c ..."}` to bridge |
| Run Python Script | HTTP Request | `POST /execute {"script": "def is_prime..."}` to bridge |
| Combine Results | Code (JS) | Merges both responses into one output object |

The two HTTP Request nodes run **in parallel** — n8n fans them out from the single trigger.

---

## Adapting this example

**Change the Python code** — edit the `value` fields in `n8n-workflow.json` and re-import,
or edit them directly in the n8n UI.

**Add more sandbox calls** — duplicate either HTTP Request node and change the body.
Each call claims its own sandbox from the warm pool.

**Enable strong isolation** — uncomment `runtimeClassName: gvisor` (or `kata-qemu`)
in `k8s/sandbox-template.yaml` on a cluster that has gVisor or Kata Containers installed.

**Trigger from a webhook** — replace the Manual Trigger node with an
`n8n-nodes-base.webhook` node. Send a `POST` with `{"command": "..."}` in the body
and pass it through to the bridge unchanged.
