#!/usr/bin/env bash
# create-env.sh — one-shot setup for the C5 Kuadrant POC.
#
# What this does:
#   1. Creates a kind cluster (kuadrant-poc)
#   2. Installs Gateway API CRDs
#   3. Installs Istio 1.27 (provides the service mesh; Envoy 1.35 — does NOT have mcp_filter)
#   4. Installs Kuadrant operator + Kuadrant CR (provisions Authorino)
#   5. Deploys mock-mcp-server and standalone Envoy 1.38 in mcp-demo namespace
#   6. Applies the AuthConfig that reads mcp metadata and denies tool2
#
# Requirements: kind, helm, kubectl, istioctl (1.27+)
# istioctl: download from https://istio.io/downloadIstio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK_SERVER_SRC="$SCRIPT_DIR/../../../../mocks/mock_mcp_server.py"

# ── prereqs ──────────────────────────────────────────────────────────────────
for cmd in kind helm kubectl istioctl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
[ -f "$MOCK_SERVER_SRC" ] || { echo "ERROR: mock_mcp_server.py not found at $MOCK_SERVER_SRC"; exit 1; }

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

# ── mock backend ──────────────────────────────────────────────────────────────
echo "== deploying mock MCP backend =="
kubectl -n mcp-demo create configmap mock-mcp-server-script \
  --from-file=mock_mcp_server.py="$MOCK_SERVER_SRC" --dry-run=client -o yaml | kubectl apply -f -
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
