#!/usr/bin/env bash
# Copyright 2025 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# run-demo.sh — end-to-end setup for the n8n + Agent Sandbox demo on KIND.
#
# What this script does:
#   1. Verifies prerequisites (kind, kubectl, docker)
#   2. Creates a KIND cluster named "n8n-sandbox-demo"
#   3. Installs the Agent Sandbox controller + extensions CRDs
#   4. Builds the bridge Docker image and loads it into KIND
#   5. Applies all Kubernetes manifests
#   6. Waits for all pods to be ready
#   7. Port-forwards n8n to localhost:5678
#   8. Prints the import URL for the n8n workflow

set -euo pipefail

CLUSTER_NAME="n8n-sandbox-demo"
NAMESPACE="n8n-demo"
BRIDGE_IMAGE="n8n-sandbox-bridge:local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in kind kubectl docker; do
  command -v "$cmd" &>/dev/null || die "'$cmd' not found. Please install it and retry."
done
success "kind, kubectl, docker are available."

# ─── 2. KIND cluster ──────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "KIND cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  info "Creating KIND cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}"
  success "Cluster created."
fi

# Point kubectl at the new cluster
kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null

# ─── 3. Agent Sandbox controller + extensions ─────────────────────────────────
# Detect the latest release tag from GitHub, or override with AGENT_SANDBOX_VERSION.
if [[ -z "${AGENT_SANDBOX_VERSION:-}" ]]; then
  info "Fetching latest Agent Sandbox release tag from GitHub..."
  AGENT_SANDBOX_VERSION=$(
    curl -fsSL "https://api.github.com/repos/kubernetes-sigs/agent-sandbox/releases/latest" \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/'
  ) || die "Could not determine latest release. Set AGENT_SANDBOX_VERSION=vX.Y.Z and retry."
fi
info "Installing Agent Sandbox ${AGENT_SANDBOX_VERSION}..."

BASE_URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}"
kubectl apply -f "${BASE_URL}/manifest.yaml"
kubectl apply -f "${BASE_URL}/extensions.yaml"

info "Waiting for agent-sandbox-controller-manager to be ready..."
kubectl rollout status deployment/agent-sandbox-controller-manager \
  -n agent-sandbox-system --timeout=120s
success "Agent Sandbox controller is running."

# ─── 4. Build & load bridge image ─────────────────────────────────────────────
info "Building bridge image '${BRIDGE_IMAGE}'..."
docker build -t "${BRIDGE_IMAGE}" "${SCRIPT_DIR}/bridge"
success "Bridge image built."

info "Loading '${BRIDGE_IMAGE}' into KIND cluster '${CLUSTER_NAME}'..."
kind load docker-image "${BRIDGE_IMAGE}" --name "${CLUSTER_NAME}"
success "Image loaded."

# ─── 5. Apply Kubernetes manifests ────────────────────────────────────────────
info "Applying manifests..."
kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/sandbox-template.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/sandbox-warmpool.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/bridge.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/n8n.yaml"
success "Manifests applied."

# ─── 6. Wait for pods ─────────────────────────────────────────────────────────
info "Waiting for bridge deployment to be ready (up to 2 min)..."
kubectl rollout status deployment/n8n-sandbox-bridge -n "${NAMESPACE}" --timeout=120s
success "Bridge is ready."

info "Waiting for n8n deployment to be ready (up to 3 min — image pull may take a moment)..."
kubectl rollout status deployment/n8n -n "${NAMESPACE}" --timeout=180s
success "n8n is ready."

info "Waiting for the warm pool to have at least 1 ready sandbox (up to 3 min)..."
DEADLINE=$(( $(date +%s) + 180 ))
while true; do
  READY=$(kubectl get sandboxwarmpool n8n-sandbox-warmpool -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [[ "${READY:-0}" -ge 1 ]] && break
  [[ $(date +%s) -gt $DEADLINE ]] && {
    warn "Warm pool not ready within 3 min. The demo will still work once sandbox pods start."
    break
  }
  echo -n "."
  sleep 5
done
echo ""
success "Warm pool has ${READY:-0} ready sandbox(es)."

# ─── 7. Port-forward n8n ──────────────────────────────────────────────────────
info "Starting port-forward: localhost:5678 → n8n (press Ctrl+C to stop)"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  n8n UI:  http://localhost:5678${NC}"
echo ""
echo -e "  Import the workflow:"
echo -e "    1. Open http://localhost:5678 in your browser"
echo -e "    2. Create an account (first run only)"
echo -e "    3. Click '+ New workflow' → '...' (top-right) → 'Import from file'"
echo -e "    4. Select: ${SCRIPT_DIR}/n8n-workflow.json"
echo -e "    5. Click 'Test workflow' (top-right) — both sandbox executions run in parallel"
echo ""
echo -e "  Bridge health check (from another terminal):"
echo -e "    kubectl port-forward svc/n8n-sandbox-bridge-svc 8000:8000 -n ${NAMESPACE}"
echo -e "    curl -s http://localhost:8000/healthz"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

kubectl port-forward svc/n8n-svc 5678:5678 -n "${NAMESPACE}"
