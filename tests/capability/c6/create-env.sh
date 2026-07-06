#!/usr/bin/env bash
# create-env.sh — one-shot setup for the C6 lane: Istio 1.30 (bundles Envoy 1.38)
# + Kuadrant AuthPolicy, testing whether the native mcp_filter + AuthPolicy can
# replace the C5/kuadrant lane's standalone Envoy + hand-written AuthConfig.
#
# What this does:
#   1. Creates a kind cluster (kuadrant-native-poc) — separate from C5/kuadrant's
#      "kuadrant-poc" cluster so both can coexist.
#   2. Installs Gateway API CRDs
#   3. Installs Istio 1.30 (its Gateway API-managed Gateway workload runs Envoy
#      1.38.1 natively — confirmed via /server_info, no standalone Envoy needed
#      for the version requirement itself)
#   4. Installs Kuadrant operator + Kuadrant CR (provisions Authorino)
#   5. Builds the test-server1 MCP server from Kuadrant/mcp-gateway's own test suite
#      and loads it into kind
#   6. Applies a Gateway + HTTPRoute (Gateway API, gatewayClassName: istio) — Istio
#      auto-provisions the proxy workload, no manual Envoy config at all
#
# Requirements: kind, helm, kubectl, istioctl (1.30+), docker, git
# istioctl 1.30: download from https://istio.io/downloadIstio — as of this writing
# Homebrew's istioctl formula may lag behind; check `istioctl version --remote=false`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCPGW_REPO="https://github.com/Kuadrant/mcp-gateway.git"
MCPGW_SRC_DIR="$SCRIPT_DIR/.mcp-gateway-src"   # scratch clone, gitignored — only used to build tests/servers/server1

# ── prereqs ──────────────────────────────────────────────────────────────────
for cmd in kind helm kubectl istioctl docker git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done
ISTIO_VER=$(istioctl version --remote=false --short 2>/dev/null || true)
case "$ISTIO_VER" in
  1.3[0-9]*|1.[4-9][0-9]*) ;;
  *) echo "WARNING: istioctl reports '$ISTIO_VER' — this lane needs 1.30+ (Envoy 1.38 in the Gateway workload). Continuing anyway." ;;
esac

# ── kind cluster ─────────────────────────────────────────────────────────────
echo "== creating kind cluster (kuadrant-native-poc) =="
kind delete cluster --name kuadrant-native-poc 2>/dev/null || true
kind create cluster --name kuadrant-native-poc --config - <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30001
        hostPort: 30001
        protocol: TCP
KINDEOF

# ── gateway api crds ──────────────────────────────────────────────────────────
echo "== installing Gateway API CRDs =="
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# ── istio ─────────────────────────────────────────────────────────────────────
echo "== installing Istio 1.30 (Gateway API-managed Gateway runs Envoy natively) =="
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
kubectl -n kuadrant-system wait --for=condition=Ready pod -l app=limitador --timeout=180s

# ── app namespace ─────────────────────────────────────────────────────────────
echo "== creating mcp-demo namespace =="
kubectl apply -f "$SCRIPT_DIR/manifests/namespace.yaml"

# ── test MCP server (server1) ─────────────────────────────────────────────────
echo "== building test MCP server (server1) =="
if [ -d "$MCPGW_SRC_DIR/.git" ]; then
  git -C "$MCPGW_SRC_DIR" fetch --quiet origin main
  git -C "$MCPGW_SRC_DIR" checkout --quiet main
  git -C "$MCPGW_SRC_DIR" reset --hard --quiet origin/main
else
  git clone --quiet --depth 1 "$MCPGW_REPO" "$MCPGW_SRC_DIR"
fi
docker build --quiet -t mcp-server1:demo "$MCPGW_SRC_DIR/tests/servers/server1" >/dev/null
kind load docker-image mcp-server1:demo --name kuadrant-native-poc

echo "== deploying test MCP server (server1) =="
kubectl -n mcp-demo apply -f "$SCRIPT_DIR/manifests/mock-backend.yaml"
kubectl -n mcp-demo wait --for=condition=Ready pod -l app=mock-mcp-server --timeout=120s

# ── gateway api: Gateway + HTTPRoute (no manual Envoy config) ────────────────
echo "== applying Gateway + HTTPRoute (Istio auto-provisions the proxy workload) =="
kubectl apply -f "$SCRIPT_DIR/manifests/gateway.yaml"
kubectl -n mcp-demo wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=mcp-gateway --timeout=120s

echo ""
echo "== setup complete =="
echo "Port-forward:  kubectl -n mcp-demo port-forward svc/mcp-gateway-istio 18080:80"
echo "Run smoke:     ./smoke.sh"
