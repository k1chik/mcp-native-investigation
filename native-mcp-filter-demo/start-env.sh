#!/usr/bin/env bash
# start-env.sh — Terminal 1 for the live demo.
#
# Checks that the already-running kuadrant-poc cluster and its pods are healthy,
# then starts (or reuses) the port-forward demo.sh talks to. This does NOT create
# or rebuild anything — if the cluster is missing, run
# tests/capability/c5/kuadrant/create-env.sh first (takes a few minutes; don't do
# this right before a talk).
set -uo pipefail

KCTX="kind-kuadrant-poc"

echo "== checking kind cluster =="
if ! kind get clusters 2>/dev/null | grep -qx "kuadrant-poc"; then
  echo "ERROR: kind cluster 'kuadrant-poc' not found."
  echo "Run: tests/capability/c5/kuadrant/create-env.sh (takes a few minutes)"
  exit 1
fi
echo "  ok — kuadrant-poc is up"

echo ""
echo "== checking pods =="
for ns_sel in "mcp-demo app=envoy138" "mcp-demo app=mock-mcp-server" \
              "kuadrant-system authorino-resource=authorino" \
              "kuadrant-system app=limitador"; do
  ns="${ns_sel%% *}"; sel="${ns_sel#* }"
  ready=$(kubectl --context "$KCTX" -n "$ns" get pod -l "$sel" \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  if [ "$ready" != "true" ]; then
    echo "ERROR: pod matching '$sel' in namespace '$ns' is not Ready."
    kubectl --context "$KCTX" -n "$ns" get pod -l "$sel" 2>&1
    exit 1
  fi
  echo "  ok — $sel ($ns)"
done

echo ""
echo "== port-forward =="
if lsof -nP -iTCP:10000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "  something is already listening on :10000 — assuming a port-forward is"
  echo "  already running from earlier. Not starting a second one."
  echo "  (verify: curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9901/stats)"
  exit 0
fi

echo "  starting: kubectl --context $KCTX -n mcp-demo port-forward svc/envoy138 10000:10000 9901:9901"
echo "  (leave this running — Ctrl+C to stop when the demo is over)"
echo ""
exec kubectl --context "$KCTX" -n mcp-demo port-forward svc/envoy138 10000:10000 9901:9901
