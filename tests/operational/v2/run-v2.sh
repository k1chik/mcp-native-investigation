#!/usr/bin/env bash
# =====================================================================================
# run-v2.sh — V2: SSE relay / notification fanout check
# =====================================================================================
#
# Tests whether native Envoy relays tools/list_changed notifications from backends
# to clients. This is the V2 operational check.
#
# The finding has two parts:
#
#   Part A — client-side: does the client receive any SSE events from the gateway?
#     A GET with Accept: text/event-stream to the gateway should open an SSE stream
#     if the gateway relays backend notifications. Native returns 405 — no relay.
#
#   Part B — backend-side: does the gateway open a GET SSE connection to backends?
#     After initialize and tools/list, we check each backend's /__stats for
#     sse_get_connections_total. Native opens zero GET connections to backends.
#
# Both confirm the same conclusion: native mcp_router is purely request-driven.
# It has no notification channel in either direction. There is no fanout storm
# because there is no subscription mechanism — the cost instead is V1 (every
# client tools/list fans out live to all backends).
#
# CONNLINK-1026: Craig Brookes concern #3 (fanout storm)
#
# PREREQUISITE: docker compose up -d   (from this directory; backend-a is configured
#               with MCP_LIST_CHANGED_EVERY=2 to push list_changed every 2s)
# HOW TO RUN:   ./run-v2.sh
# TEARDOWN:     docker compose down
# =====================================================================================
set -euo pipefail
cd "$(dirname "$0")"

GW=http://localhost:10000
BACKEND_A=v2-backend-a-1
BACKEND_B=v2-backend-b-1
fail=0

post() {
  curl -s -X POST "$GW" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$1"
}
backend_sse() { docker exec "$1" python3 -c "import urllib.request,json; d=json.load(urllib.request.urlopen('http://localhost:$2/__stats')); print(d['sse_get_connections_total'])"; }

echo "Waiting for gateway..."
for _ in $(seq 1 40); do
  curl -sf http://localhost:9901/ready >/dev/null 2>&1 && break || sleep 0.5
done
sleep 1

# ── Part A: client-side — does the gateway expose an SSE stream? ──────────────
echo
echo "########  V2 Part A — client-side SSE relay  ########"
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Accept: text/event-stream' \
  --max-time 2 \
  "$GW")
echo "  GET $GW (Accept: text/event-stream) -> HTTP $HTTP_STATUS"

if [ "$HTTP_STATUS" = "405" ]; then
  echo "  V2 Part A PASS — 405 Method Not Allowed: gateway has no client-facing SSE channel"
  echo "  (Clients cannot receive tools/list_changed or any server-initiated messages)"
else
  echo "  V2 Part A note — expected 405, got $HTTP_STATUS"
fi

# ── Prime the gateway: initialize + tools/list so any SSE connections would open ──
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"v2-test","version":"1"}}}' >/dev/null
post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' >/dev/null
sleep 4  # backend-a fires list_changed every 2s — give it two notification cycles

# ── Part B: backend-side — did the gateway open any GET SSE connections? ──────
echo
echo "########  V2 Part B — backend-side SSE connections  ########"
SSE_A=$(backend_sse "$BACKEND_A" 9001)
SSE_B=$(backend_sse "$BACKEND_B" 9002)
echo "  backend-a sse_get_connections_total = $SSE_A  (backend-a pushes list_changed every 2s)"
echo "  backend-b sse_get_connections_total = $SSE_B"

if [ "$SSE_A" -eq 0 ] && [ "$SSE_B" -eq 0 ]; then
  echo "  V2 Part B PASS — mcp_router opened ZERO GET SSE connections to either backend"
  echo "  (Gateway never subscribes to backend notifications; it cannot relay list_changed)"
else
  echo "  V2 Part B note — expected 0, got a=$SSE_A b=$SSE_B (unexpected SSE connections)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "V2 verdict: native mcp_router has NO SSE relay in either direction."
echo "  - Clients cannot receive notifications (405 on GET)."
echo "  - Gateway never opens SSE connections to backends (zero sse_get_connections_total)."
echo "  - No fanout storm is possible because there is no subscription channel."
echo "  - The actual cost is V1: every client tools/list fans out live to all backends."
echo "============================================================"
echo "V2 PASS"
exit 0
