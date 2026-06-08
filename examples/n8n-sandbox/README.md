# n8n + Agent Sandbox

Execute isolated Python code from an n8n workflow.

## What this example does

A manual trigger fires two parallel HTTP calls from n8n to a **bridge service**
running in the same cluster.  The bridge claims a pre-warmed sandbox pod,
executes the requested command or script inside it, and streams the result back
to n8n — all within a single HTTP round-trip.

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

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker | ≥ 20.10 | https://docs.docker.com/get-docker/ |
| KIND | ≥ 0.20 | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| kubectl | ≥ 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| curl | any | pre-installed on most systems |

## Quick start (< 10 minutes)

```bash
cd examples/n8n-sandbox
./run-demo.sh
```

The script:
1. Creates a KIND cluster named `n8n-sandbox-demo`
2. Installs the Agent Sandbox controller + extensions
3. Builds the bridge Docker image and loads it into KIND
4. Deploys the bridge, n8n, the SandboxTemplate, and the SandboxWarmPool
5. Waits for all pods to be ready
6. Port-forwards n8n to `http://localhost:5678`

Once the port-forward is active, open `http://localhost:5678`, create an account,
then import `n8n-workflow.json` and click **Test workflow**.

To pin a specific controller version instead of auto-detecting the latest:

```bash
AGENT_SANDBOX_VERSION=v0.2.0 ./run-demo.sh
```

## Repository layout

```
examples/n8n-sandbox/
├── run-demo.sh              # One-shot setup (KIND)
├── n8n-workflow.json        # Importable n8n workflow
├── bridge/
│   ├── main.py              # FastAPI bridge — n8n → Python SDK → sandbox
│   ├── Dockerfile
│   └── requirements.in
└── k8s/
    ├── namespace.yaml        # n8n-demo namespace
    ├── sandbox-template.yaml # SandboxTemplate (python-runtime image)
    ├── sandbox-warmpool.yaml # 2 pre-warmed sandbox pods
    ├── bridge.yaml           # Bridge deployment + RBAC + Service
    └── n8n.yaml              # n8n deployment + Service
```

## How it works

### Bridge service (`bridge/main.py`)

A minimal FastAPI app with a single endpoint:

```
POST /execute
  Body: {"command": "<shell string>"}
  Body: {"script":  "<python source>"}

Response: {"stdout": "...", "stderr": "...", "exit_code": 0}
```

It uses the Python SDK in **in-cluster mode** (`SandboxInClusterConnectionConfig`), which connects
directly to each sandbox pod via cluster-internal DNS:

```
http://{sandbox-id}.n8n-demo.svc.cluster.local:8888
```

No sandbox router is required.

### SandboxTemplate (`k8s/sandbox-template.yaml`)

Two settings are intentional:

| Field | Value | Why |
|-------|-------|-----|
| `spec.service` | `true` | Creates a headless Service per sandbox pod, enabling the DNS-based routing above |
| `spec.networkPolicyManagement` | `Unmanaged` | Skips auto-generated NetworkPolicy (KIND doesn't enforce them, and `Unmanaged` avoids overriding the pod's DNS config) |

### SandboxWarmPool (`k8s/sandbox-warmpool.yaml`)

Keeps **2 sandbox pods** pre-started.  When the bridge calls
`create_sandbox()`, it gets an already-running pod in < 1 second.  The pool
automatically replenishes after each claim.

### n8n workflow (`n8n-workflow.json`)

Four nodes:

| Node | Type | What it does |
|------|------|-------------|
| When clicking 'Test workflow' | Manual Trigger | Fires the workflow |
| Run Shell Command | HTTP Request | Sends `{"command": "python3 -c ..."}`  to bridge |
| Run Python Script | HTTP Request | Sends `{"script": "def is_prime..."}` to bridge |
| Combine Results | Code (JS) | Merges the two responses into one output object |

The two HTTP Request nodes run **in parallel** — n8n fans them out from the
single trigger.

## Manual teardown

```bash
# Stop the port-forward: Ctrl+C in the terminal running run-demo.sh

# Delete the KIND cluster (removes everything):
kind delete cluster --name n8n-sandbox-demo
```

## Adapting this example

**Change the Python code** — edit the `value` fields in
[n8n-workflow.json](n8n-workflow.json) and re-import, or edit them directly
in the n8n UI.

**Add more sandbox calls** — duplicate either HTTP Request node in n8n and
change the body. Each call claims its own sandbox from the warm pool.

**Use a real cluster (GKE/EKS/AKS)** — replace `SandboxInClusterConnectionConfig`
in [bridge/main.py](bridge/main.py) with `SandboxGatewayConnectionConfig` and
deploy the sandbox-router.

**Enable strong isolation** — uncomment `runtimeClassName: gvisor` (or
`kata-qemu`) in [k8s/sandbox-template.yaml](k8s/sandbox-template.yaml) on a
cluster that has gVisor or Kata Containers installed.

**Trigger from a webhook** — replace the Manual Trigger node with an
`n8n-nodes-base.webhook` node and send a `POST` with `{"command": "..."}` in
the body.  Pass it through to the bridge unchanged.
