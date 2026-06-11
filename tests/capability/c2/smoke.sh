#!/usr/bin/env bash
# =============================================================================================
# C2: native-lane-authz smoke test
# =============================================================================================
# WHAT THIS CHECKS:
#   C2  - An external authorizer (OPA) reads envoy.filters.http.mcp dynamic metadata
#         and allows/denies requests by tool name - without header injection from ext-proc.
#
#         Positive: server1__tool1 and server2__tool1 are ALLOWED (HTTP 200).
#         Negative: server1__tool2 is DENIED (HTTP 403) by the OPA policy.
#         Bypass check: tools/list (no tool_name in metadata) is ALLOWED.
#
# WHY THIS MATTERS:
#   In production, ext-proc currently injects x-mcp-toolname headers so that
#   Authorino can check the tool name. If native Envoy exposes the same data as
#   dynamic metadata (readable by any gRPC ext_authz peer), header injection is
#   no longer needed. C2 settles that question.
#
# WHAT TO CHECK IF TESTS FAIL:
#   1. docker compose logs authz    - OPA decision logs show the full CheckRequest input.
#      Look for "filter_metadata" to see the exact keys mcp_filter wrote.
#      If the key is not "tool_name", update authz/policy.rego accordingly.
#   2. docker compose logs envoy    - shows ext_authz filter debug output.
#   3. curl http://localhost:9901/stats | grep ext_authz  - Envoy ext_authz counters.
#
# PREREQUISITE: the lane is up.   docker compose up -d   (gateway :10000, admin :9901)
# HOW TO RUN:   ./smoke.sh        (read-only; exits non-zero on failure)
#               GW=http://host:port ./smoke.sh   to point elsewhere
# TEARDOWN:     docker compose down
# =============================================================================================
set -uo pipefail
cd "$(dirname "$0")"
GW="${GW:-http://localhost:10000}"
OPA="${OPA:-http://localhost:8181}"

post() {
  curl -s "$GW" -X POST -H 'Content-Type: application/json' -d "$1"
}

# Returns the HTTP status code for a tools/call request; discards the body.
call_status() {
  curl -s -o /dev/null -w "%{http_code}" "$GW" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\"}}"
}

# Returns the response body for a tools/call request.
call_body() {
  curl -s "$GW" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\"}}"
}

echo "== waiting for OPA health =="
OPA_READY=0
for _ in $(seq 1 30); do
  curl -sf "${OPA}/health" >/dev/null 2>&1 && OPA_READY=1 && break
  sleep 0.5
done
[ "$OPA_READY" = 1 ] && echo "  OPA ready" || { echo "  OPA did not become healthy in 15s - aborting"; exit 1; }

echo
echo "== initialize (through the gateway + authz) =="
# initialize carries no tool_name - OPA policy allows it unconditionally.
INIT_RESP=$(post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}')
echo "$INIT_RESP" | jq -c '.result.serverInfo // .'

echo
echo "== tools/list - no tool_name in metadata, expect ALLOW (both backends) =="
TOOLS=$(post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '[.result.tools[].name] | sort | join(", ")')
echo "  tools: $TOOLS"
if echo "$TOOLS" | grep -q 'server1__tool1' && echo "$TOOLS" | grep -q 'server2__tool1'; then
  echo "  tools/list PASS - both backends returned (authz did not block discovery)"
  LIST_OK=1
else
  echo "  tools/list CHECK - expected both backends: $TOOLS"
  LIST_OK=0
fi

echo
echo "== C2 allow: server1__tool1 (not blocked) =="
C2_ALLOW1_STATUS=$(call_status 10 "server1__tool1")
C2_ALLOW1_BODY=$(call_body 11 "server1__tool1")
C2_ALLOW1_TEXT=$(echo "$C2_ALLOW1_BODY" | jq -r '.result.content[0].text // "ERROR"')
if [ "$C2_ALLOW1_STATUS" = "200" ] && [ "$C2_ALLOW1_TEXT" = "server1 ran tool1" ]; then
  echo "  server1__tool1 -> ALLOWED ($C2_ALLOW1_STATUS) - \"$C2_ALLOW1_TEXT\" ✓"
  C2_ALLOW1_OK=1
else
  echo "  server1__tool1 -> status=$C2_ALLOW1_STATUS body=$C2_ALLOW1_BODY ✗"
  C2_ALLOW1_OK=0
fi

echo
echo "== C2 deny: server1__tool2 (blocked by OPA policy) =="
# This is the core C2 test: OPA reads the tool_name from envoy.filters.http.mcp
# metadata and returns PERMISSION_DENIED without any header injection.
C2_DENY_STATUS=$(call_status 20 "server1__tool2")
if [ "$C2_DENY_STATUS" = "403" ]; then
  echo "  server1__tool2 -> DENIED ($C2_DENY_STATUS) ✓  (OPA read tool_name from metadata)"
  C2_DENY_OK=1
else
  echo "  server1__tool2 -> status=$C2_DENY_STATUS (expected 403) ✗"
  echo "  hint: check 'docker compose logs authz' for the OPA decision input"
  C2_DENY_OK=0
fi

echo
echo "== C2 allow: server2__tool1 (cross-backend, not blocked) =="
C2_ALLOW2_STATUS=$(call_status 30 "server2__tool1")
C2_ALLOW2_BODY=$(call_body 31 "server2__tool1")
C2_ALLOW2_TEXT=$(echo "$C2_ALLOW2_BODY" | jq -r '.result.content[0].text // "ERROR"')
if [ "$C2_ALLOW2_STATUS" = "200" ] && [ "$C2_ALLOW2_TEXT" = "server2 ran tool1" ]; then
  echo "  server2__tool1 -> ALLOWED ($C2_ALLOW2_STATUS) - \"$C2_ALLOW2_TEXT\" ✓"
  C2_ALLOW2_OK=1
else
  echo "  server2__tool1 -> status=$C2_ALLOW2_STATUS body=$C2_ALLOW2_BODY ✗"
  C2_ALLOW2_OK=0
fi

echo
echo "== metadata inspection: what did OPA receive from Envoy? =="
# Dump the MCP metadata from OPA's decision logs.
# If "tool_name" is not the field name mcp_filter uses, the deny test above will
# fail and this block will show the actual field names to fix in policy.rego.
MCP_META=$(docker compose logs authz 2>/dev/null \
  | python3 - <<'PYEOF'
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    # docker compose logs prefixes lines with "authz-1  | "
    if ' | ' in line:
        line = line.split(' | ', 1)[1].strip()
    try:
        d = json.loads(line)
        # OPA decision log: protojson uses camelCase (metadataContext, filterMetadata)
        attrs = d.get('input', {}).get('attributes', {})
        fm = attrs.get('metadataContext', {}).get('filterMetadata', {})
        if 'envoy.filters.http.mcp' in fm:
            print(json.dumps(fm['envoy.filters.http.mcp'], indent=2))
            break
    except Exception:
        pass
PYEOF
)
if [ -n "$MCP_META" ]; then
  echo "  envoy.filters.http.mcp metadata received by OPA:"
  echo "$MCP_META" | sed 's/^/    /'
else
  echo "  (could not extract metadata from OPA logs - run: docker compose logs authz)"
fi

echo
echo "== ext_authz counters (from Envoy admin) =="
curl -s http://localhost:9901/stats 2>/dev/null \
  | grep -iE 'ext_authz|http\.mcp_gw\.mcp\.' \
  | head -15 \
  || echo "  (no ext_authz stats - check Envoy admin)"

echo
echo "== verdict =="
FAIL=0
if [ "$LIST_OK" = 1 ]; then
  echo "  C2  PASS - tools/list allowed (no tool_name in metadata, policy passes through)"
else
  echo "  C2  CHECK - tools/list was blocked or returned wrong tools"
  FAIL=1
fi
if [ "$C2_ALLOW1_OK" = 1 ]; then
  echo "  C2  PASS - server1__tool1 allowed"
else
  echo "  C2  CHECK - server1__tool1 was not allowed"
  FAIL=1
fi
if [ "$C2_DENY_OK" = 1 ]; then
  echo "  C2  PASS - server1__tool2 denied by OPA reading mcp metadata (no header needed)"
else
  echo "  C2  CHECK - server1__tool2 was not denied (403 expected)"
  FAIL=1
fi
if [ "$C2_ALLOW2_OK" = 1 ]; then
  echo "  C2  PASS - server2__tool1 allowed (cross-backend unaffected by policy)"
else
  echo "  C2  CHECK - server2__tool1 was not allowed"
  FAIL=1
fi
[ "$FAIL" -eq 0 ] && { echo "  OVERALL PASS"; exit 0; } || { echo "  OVERALL CHECK - see above"; exit 1; }
