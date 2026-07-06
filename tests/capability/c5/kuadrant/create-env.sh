#!/usr/bin/env bash
# create-env.sh — one-shot setup for the C5 Kuadrant POC.
#
# What this does:
#   1. Creates a kind cluster (kuadrant-poc)
#   2. Installs Gateway API CRDs
#   3. Installs Istio 1.27 (provides the service mesh; Envoy 1.35 — does NOT have mcp_filter)
#   4. Installs Kuadrant operator + Kuadrant CR (provisions Authorino)
#   5. Builds the test-server1 MCP server from Kuadrant/mcp-gateway's own test suite
#      (https://github.com/Kuadrant/mcp-gateway/tree/main/tests/servers/server1) and
#      loads it into kind, then deploys it + standalone Envoy 1.38 in mcp-demo namespace
#   6. Applies the AuthConfig that reads mcp metadata and denies the "slow" tool
#
# Requirements: kind, helm, kubectl, istioctl (1.27+), docker, git
# istioctl: download from https://istio.io/downloadIstio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCPGW_REPO="https://github.com/Kuadrant/mcp-gateway.git"
MCPGW_SRC_DIR="$SCRIPT_DIR/.mcp-gateway-src"   # scratch clone, gitignored — only used to build tests/servers/server1

# ── prereqs ──────────────────────────────────────────────────────────────────
for cmd in kind helm kubectl istioctl docker git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done

# ── kind cluster ─────────────────────────────────────────────────────────────
echo "== creating kind cluster =="
kind delete cluster --name kuadrant-poc 2>/dev/null || true
kind create cluster --name kuadrant-poc --config - <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30000
        hostPort: 30000
        protocol: TCP
KINDEOF

# ── gateway api crds ──────────────────────────────────────────────────────────
echo "== installing Gateway API CRDs =="
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# ── istio ─────────────────────────────────────────────────────────────────────
echo "== installing Istio (mesh only; mcp_filter requires Envoy 1.38 — use standalone envoy138 deployment) =="
istioctl install -y --set profile=minimal --set meshConfig.accessLogFile=/dev/stdout

# ── kuadrant ──────────────────────────────────────────────────────────────────
echo "== installing Kuadrant operator =="
helm repo add kuadrant https://kuadrant.io/helm-charts/ 2>/dev/null || true
helm repo update kuadrant
helm install kuadrant-operator kuadrant/kuadrant-operator \
  --namespace kuadrant-system --create-namespace --wait --timeout=5m

echo "== provisioning Kuadrant (Authorino + Limitador) =="
kubectl -n kuadrant-system apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
EOF
kubectl -n kuadrant-system wait --for=condition=Ready pod -l authorino-resource=authorino --timeout=180s

# ── app namespace ─────────────────────────────────────────────────────────────
echo "== creating mcp-demo namespace =="
kubectl apply -f "$SCRIPT_DIR/manifests/namespace.yaml"

# ── test MCP server (server1) ─────────────────────────────────────────────────
# Real test server from Kuadrant/mcp-gateway's own test suite, not a hand-rolled mock:
# https://github.com/Kuadrant/mcp-gateway/tree/main/tests/servers/server1
# Exposes "time" (allowed) and "slow" (blocked by the demo's policy), plus
# "greet", "headers", "add_tool".
echo "== building test MCP server (server1) =="
if [ -d "$MCPGW_SRC_DIR/.git" ]; then
  git -C "$MCPGW_SRC_DIR" fetch --quiet origin main
  git -C "$MCPGW_SRC_DIR" checkout --quiet main
  git -C "$MCPGW_SRC_DIR" reset --hard --quiet origin/main
else
  git clone --quiet --depth 1 "$MCPGW_REPO" "$MCPGW_SRC_DIR"
fi
docker build --quiet -t mcp-server1:demo "$MCPGW_SRC_DIR/tests/servers/server1" >/dev/null
kind load docker-image mcp-server1:demo --name kuadrant-poc

echo "== deploying test MCP server (server1) =="
kubectl -n mcp-demo apply -f "$SCRIPT_DIR/manifests/mock-backend.yaml"
kubectl -n mcp-demo wait --for=condition=Ready pod -l app=mock-mcp-server --timeout=120s

# ── envoy 1.38 + authconfig ───────────────────────────────────────────────────
echo "== deploying standalone Envoy 1.38 + AuthConfig =="
kubectl -n mcp-demo apply -f "$SCRIPT_DIR/manifests/envoy138.yaml"
kubectl -n mcp-demo apply -f "$SCRIPT_DIR/manifests/authconfig.yaml"
kubectl -n mcp-demo wait --for=condition=Ready pod -l app=envoy138 --timeout=120s

echo ""
echo "== setup complete =="
echo "Port-forward:  kubectl -n mcp-demo port-forward svc/envoy138 10000:10000 9901:9901"
echo "Run smoke:     ./smoke.sh"
