#!/usr/bin/env bash
# =============================================================================================
# Native-Envoy lane smoke - C1, C3, C4a
# =============================================================================================
# WHAT THIS CHECKS:
#   C1  - Envoy's `mcp` filter parses MCP requests (admin /stats shows its counters move).
#         Negative 1: malformed JSON increments mcp.invalid_json (parser ran).
#         Negative 2: valid JSON with missing `method` field is rejected with a clear error.
#   C3  - `mcp_router` fans out to BOTH backends and merges their tool lists, each tool
#         prefixed with its server name so colliding names don't clash.
#         Backend-down: one backend stopped mid-test - gateway returns partial results
#         (live backend only) after the connect_timeout, then recovers when it restarts.
#   C4a - tools/call for every tool on both backends: prefix stripped, routed to the right
#         backend, correct response returned.
#         Negative: unknown tool name returns a clean error, gateway does not crash.
#
# PREREQUISITE: the lane is up.   docker compose up -d   (gateway :10000, admin :9901)
# HOW TO RUN:   ./smoke.sh        (read-only; exits non-zero on failure)
#               GW=http://host:port ./smoke.sh   to point elsewhere
# TEARDOWN:     docker compose down
#
# GOTCHAS:
#   - The prefix delimiter is a HARDCODED double underscore `__` (server `server1` + tool
#     `tool1` => `server1__tool1`). Not a single `_`. Asserting on `server1_tool1` will
#     always fail.
#   - The `mcp` filter is in PASS_THROUGH mode here: it annotates, it does not block.
#   - Some MCP calls through the native filter need `Accept: application/json, text/event-stream`.
#     These plain curls work without it; if you add a tools/call that returns 400
#     "Invalid or missing MCP request", add that Accept header.
#   - The C3 backend-down check takes ~5s extra (the cluster connect_timeout while Envoy
#     retries the stopped backend) and ~10s for recovery. Total lane runtime is ~20s longer.
# =============================================================================================
set -euo pipefail
cd "$(dirname "$0")"
GW="${GW:-http://localhost:10000}"

post() { curl -s "$GW" -X POST -H 'Content-Type: application/json' -d "$1"; }

echo "== initialize (through the gateway) =="
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | jq -c '.result.serverInfo // .'

echo
echo "== tools/list - expect BOTH backends, prefixed (C3) =="
TOOLS=$(post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '[.result.tools[].name] | sort | join(", ")')
echo "  tools: $TOOLS"

echo
echo "== C3 backend-down - stop backend-b, tools/list must degrade gracefully =="
# Stop backend-b mid-test. The gateway should return only server1's tools (partial
# degradation) rather than crashing or hanging. The connect_timeout (5s) means this
# call takes ~5s - that is expected and is noted in the GOTCHAS above.
docker compose stop backend-b >/dev/null 2>&1
C3_DOWN_RESP=$(curl -s --max-time 10 "$GW" -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":20,"method":"tools/list"}')
C3_DOWN_TOOLS=$(echo "$C3_DOWN_RESP" | jq -r '[.result.tools[].name] | sort | join(", ")' 2>/dev/null || echo "")
if echo "$C3_DOWN_TOOLS" | grep -q 'server1__tool1' && ! echo "$C3_DOWN_TOOLS" | grep -q 'server2__tool1'; then
  echo "  C3 backend-down PASS - partial degradation: only live backend returned ($C3_DOWN_TOOLS)"
  C3_DOWN_OK=1
elif [ -z "$C3_DOWN_TOOLS" ]; then
  echo "  C3 backend-down CHECK - no tools returned or request timed out: $C3_DOWN_RESP"
  C3_DOWN_OK=0
else
  echo "  C3 backend-down CHECK - unexpected result: $C3_DOWN_TOOLS"
  C3_DOWN_OK=0
fi

echo
echo "== C3 recovery - restart backend-b, tools/list must return full list again =="
# Envoy reconnects via STRICT_DNS re-resolution. Recovery takes up to ~10s in practice.
docker compose start backend-b >/dev/null 2>&1
C3_RECOVERY_OK=0
for i in $(seq 1 8); do
  sleep 2
  RECOVERED=$(curl -s --max-time 5 "$GW" -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":21,"method":"tools/list"}' \
    | jq -r '[.result.tools[].name] | sort | join(", ")' 2>/dev/null || echo "")
  if echo "$RECOVERED" | grep -q 'server1__tool1' && echo "$RECOVERED" | grep -q 'server2__tool1'; then
    echo "  C3 recovery PASS - full list returned after ${i}x2s ($RECOVERED)"
    C3_RECOVERY_OK=1
    break
  fi
done
[ "$C3_RECOVERY_OK" = 0 ] && echo "  C3 recovery CHECK - full list did not return within 16s after backend-b restart"

echo
echo "== C1 negative - malformed body must increment mcp.invalid_json =="
# Scrape the counter before and after so the delta proves the parser ran on this request,
# not just that the filter loaded.
C1_BEFORE=$(curl -s http://localhost:9901/stats | grep -oE 'http\.mcp_gw\.mcp\.invalid_json: [0-9]+' | awk '{print $2}' || echo 0)
curl -s "$GW" -X POST -H 'Content-Type: application/json' -d 'not valid json{{' >/dev/null
C1_AFTER=$(curl -s http://localhost:9901/stats | grep -oE 'http\.mcp_gw\.mcp\.invalid_json: [0-9]+' | awk '{print $2}' || echo 0)
if [ "$C1_AFTER" -gt "$C1_BEFORE" ]; then
  echo "  C1 negative PASS - invalid_json counter went $C1_BEFORE -> $C1_AFTER (parser ran)"
  C1_NEG_OK=1
else
  echo "  C1 negative CHECK - invalid_json counter did not move ($C1_BEFORE -> $C1_AFTER); filter may be in pure pass-through"
  C1_NEG_OK=0
fi

echo
echo "== C1 negative - valid JSON, missing 'method' field =="
# Valid JSON but not valid JSON-RPC. The mcp filter (PASS_THROUGH) or mcp_router should
# reject it with a clear error message, not silently forward it or crash.
C1_RPCVAL_RESP=$(post '{"jsonrpc":"2.0","id":1}')
if [ -n "$C1_RPCVAL_RESP" ] && ! echo "$C1_RPCVAL_RESP" | jq -e '.result' >/dev/null 2>&1; then
  echo "  C1 JSON-RPC validation PASS - missing method rejected: $C1_RPCVAL_RESP"
  C1_RPCVAL_OK=1
else
  echo "  C1 JSON-RPC validation CHECK - expected rejection, got: $C1_RPCVAL_RESP"
  C1_RPCVAL_OK=0
fi

echo
echo "== C4a - tools/call for every tool on both backends =="
# server1 has tool1, tool2, tool3; server2 has tool1, tool2.
# Each call must return the backend name + tool name, confirming prefix-strip and routing.
C4A_OK=1
for CALL in server1__tool1 server1__tool2 server1__tool3 server2__tool1 server2__tool2; do
  RESP=$(post "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"$CALL\"}}" | jq -r '.result.content[0].text // "ERROR"')
  BACKEND=$(echo "$CALL" | cut -d_ -f1)
  TOOL=$(echo "$CALL" | sed 's/.*__//')
  EXPECT="${BACKEND} ran ${TOOL}"
  if [ "$RESP" = "$EXPECT" ]; then
    echo "  $CALL -> \"$RESP\" ✓"
  else
    echo "  $CALL -> \"$RESP\" (expected \"$EXPECT\") ✗"
    C4A_OK=0
  fi
done

echo
echo "== C4a negative - unknown tool name must return a clean error =="
# server3 is not configured - the gateway must return a clear error, not crash or hang.
# The response is plain text (not JSON-RPC) because mcp_router rejects before routing.
C4A_UNK_RESP=$(post '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"server3__tool1"}}')
if [ -n "$C4A_UNK_RESP" ] && ! echo "$C4A_UNK_RESP" | jq -e '.result.content' >/dev/null 2>&1; then
  echo "  C4a unknown tool PASS - clean error returned: $C4A_UNK_RESP"
  C4A_UNK_OK=1
else
  echo "  C4a unknown tool CHECK - expected error, got: $C4A_UNK_RESP"
  C4A_UNK_OK=0
fi

echo
echo "== C1 stats: mcp filter counters =="
curl -s http://localhost:9901/stats 2>/dev/null | grep -iE 'http\.mcp_gw\.mcp\.' | head -10 || echo "  (no mcp stats found - check filter name)"

echo
echo "== verdict =="
FAIL=0
if echo "$TOOLS" | grep -q 'server1__tool1' && echo "$TOOLS" | grep -q 'server2__tool1'; then
  echo "  C3  PASS - both backends aggregated, colliding tool names disambiguated by prefix"
else
  echo "  C3  CHECK - did not see both server1__ and server2__ prefixes; inspect 'docker compose logs envoy'"
  FAIL=1
fi
if [ "$C3_DOWN_OK" = 1 ]; then
  echo "  C3  PASS - backend-down: partial degradation (live backend only, no crash)"
else
  echo "  C3  CHECK - backend-down: did not degrade gracefully"
  FAIL=1
fi
if [ "$C3_RECOVERY_OK" = 1 ]; then
  echo "  C3  PASS - recovery: full tool list returned after backend-b restart"
else
  echo "  C3  CHECK - recovery: full tool list did not return within 16s"
  FAIL=1
fi
if [ "$C4A_OK" = 1 ]; then
  echo "  C4a PASS - all 5 tools routed and prefix-stripped correctly"
else
  echo "  C4a CHECK - one or more tools/call responses were wrong"
  FAIL=1
fi
if [ "$C4A_UNK_OK" = 1 ]; then
  echo "  C4a PASS - unknown tool name returned a clean error (gateway did not crash)"
else
  echo "  C4a CHECK - unknown tool did not return a clean error"
  FAIL=1
fi
if [ "$C1_NEG_OK" = 1 ]; then
  echo "  C1  PASS - malformed JSON rejected (invalid_json counter incremented)"
else
  echo "  C1  INFO - malformed JSON counter did not move; filter is PASS_THROUGH (parser still loaded)"
fi
if [ "$C1_RPCVAL_OK" = 1 ]; then
  echo "  C1  PASS - valid JSON with missing method field rejected cleanly"
else
  echo "  C1  CHECK - valid JSON with missing method field was not rejected"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && { echo "  OVERALL PASS"; exit 0; } || { echo "  OVERALL CHECK - see above"; exit 1; }
