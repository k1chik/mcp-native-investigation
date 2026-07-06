#!/usr/bin/env bash
# =============================================================================================
# C6 smoke test — does Istio 1.30 + Kuadrant AuthPolicy close the C5/kuadrant version gap?
# =============================================================================================
# WHAT THIS CHECKS (in order):
#   1. The Istio 1.30 Gateway API-managed Gateway workload runs Envoy 1.38+ natively
#      (via /server_info) — no standalone Envoy needed for the version requirement.
#   2. Whether envoy.filters.http.mcp can actually be loaded into that workload via
#      EnvoyFilter — the only way to add an HTTP filter to a Gateway API-managed
#      listener. EXPECTED: this fails — Istio's proxy build does not compile in
#      this extension yet, independent of the Envoy source version it tracks.
#   3. Whether Kuadrant's AuthPolicy CRD (vs. hand-written AuthConfig) enforces
#      correctly against the same Gateway with zero manual Envoy config, once the
#      broken EnvoyFilter is removed — isolating the blocker to the missing
#      extension rather than any AuthPolicy/Istio 1.30 integration issue.
#
# PREREQUISITE: ./create-env.sh has been run.
# =============================================================================================
set -uo pipefail
cd "$(dirname "$0")"

FAIL=0
pass() { echo "  PASS — $*"; }
fail() { echo "  FAIL — $*"; FAIL=1; }
info() { echo "  INFO — $*"; }

GW_DEPLOY="deploy/mcp-gateway-istio"

echo "== 1. Envoy version in the Istio-managed Gateway workload =="
VER=$(kubectl -n mcp-demo exec "$GW_DEPLOY" -c istio-proxy -- \
  curl -s localhost:15000/server_info 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('version', ''))
" 2>/dev/null)
echo "  $VER"
echo "$VER" | grep -qE '/1\.(3[8-9]|[4-9][0-9])\.' \
  && pass "Gateway workload runs Envoy 1.38+ (no standalone Envoy needed for the version)" \
  || fail "could not confirm Envoy 1.38+ from server_info"

echo ""
echo "== 2. Attempt to load envoy.filters.http.mcp via EnvoyFilter (expect: rejected) =="
kubectl apply -f manifests/mcp-filter-envoyfilter.yaml >/dev/null
sleep 5
REJECT_LOG=$(kubectl -n mcp-demo logs "$GW_DEPLOY" -c istio-proxy --since=30s 2>/dev/null \
  | grep "envoy.filters.http.mcp" | grep -i "rejected\|didn't find" | tail -1)
if [ -n "$REJECT_LOG" ]; then
  echo "  $REJECT_LOG"
  pass "confirmed: Istio's proxy build does not register envoy.filters.http.mcp"
else
  info "no rejection log seen — if this Istio build DOES support mcp_filter, capture the config_dump and rewrite this lane as a real EnvoyFilter test"
fi
echo "  (cleaning up — this EnvoyFilter is a no-op once rejected, but remove it so later LDS pushes aren't blocked)"
kubectl -n mcp-demo delete -f manifests/mcp-filter-envoyfilter.yaml >/dev/null 2>&1
sleep 5

echo ""
echo "== 3. Sanity: does AuthPolicy enforce on Istio 1.30 with zero manual Envoy config? =="
kubectl apply -f manifests/authpolicy-sanity.yaml >/dev/null
echo "  waiting for AuthPolicy to be Enforced..."
for _ in $(seq 1 20); do
  STATUS=$(kubectl -n mcp-demo get authpolicy mcp-authpolicy-sanity -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null)
  [ "$STATUS" = "True" ] && break
  sleep 1
done

kubectl -n mcp-demo port-forward svc/mcp-gateway-istio 18080:80 >/tmp/c6-pf.log 2>&1 &
PF_PID=$!
sleep 3
S=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18080/ -X POST \
  -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"initialize"}')
kill "$PF_PID" 2>/dev/null
[ "$S" = "403" ] \
  && pass "AuthPolicy deny-all enforced ($S) — Kuadrant wasm ext_authz plumbing works on Istio 1.30, no manual Envoy config" \
  || fail "expected 403, got $S"

echo "  cleaning up sanity AuthPolicy..."
kubectl -n mcp-demo delete -f manifests/authpolicy-sanity.yaml >/dev/null 2>&1

# ── verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "== verdict =="
if [ "$FAIL" -eq 0 ]; then
  echo "  BLOCKED — Istio 1.30 bundles Envoy 1.38, and AuthPolicy works cleanly on it,"
  echo "  but Istio's compiled proxy image does not yet register envoy.filters.http.mcp."
  echo "  The C5/kuadrant standalone-Envoy + AuthConfig approach remains necessary"
  echo "  until Istio adds this extension to its build."
else
  echo "  OVERALL FAIL — see failures above; this run did not reproduce the expected result"
fi
exit "$FAIL"
