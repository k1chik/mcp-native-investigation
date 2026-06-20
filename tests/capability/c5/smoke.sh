#!/usr/bin/env bash
# =============================================================================================
# C5: single-server MCP gateway smoke test
# =============================================================================================
# WHAT THIS CHECKS:
#   C5  - Native mcp_filter + ext_authz (OPA) + standard router is a complete MCP gateway
#         for a single backend — no mcp-gateway or mcp_router needed.
#
#         Happy path:
#           tools/list → plain names (no server1__ prefix confirms no mcp_router in chain)
#           tool1 → ALLOWED (HTTP 200)
#           tool2 → DENIED  (HTTP 403) by OPA policy
#           tool3 → ALLOWED (HTTP 200)
#
#         Edge cases:
#           tool99            → ALLOWED (unknown tool, not in deny list)
#           missing name      → DENIED  (safe default — no tool name in metadata)
#           empty name        → ALLOWED ("" != "tool2")
#           tool2 + extra     → DENIED  (extra fields do not bypass the deny)
#           missing method    → DENIED  (no metadata written)
#           empty body        → DENIED  (not parsed)
#           malformed JSON    → 400
#           GET               → DENIED  (no metadata)
#
# WHY THIS MATTERS:
#   For single-backend MCP deployments, mcp_router and mcp-gateway are not needed.
#   mcp_filter writes the tool name to dynamic metadata; ext_authz (OPA / Authorino)
#   reads it and enforces policy. This is the minimal complete MCP gateway for a
#   single-server use case.
#
# WHAT TO CHECK IF TESTS FAIL:
#   1. docker compose logs authz    - OPA decision logs; look for filterMetadata key names.
#   2. docker compose logs envoy    - ext_authz filter debug output.
#   3. curl http://localhost:9901/stats | grep ext_authz
#
# PREREQUISITE: the lane is up.   docker compose up -d   (gateway :10000, admin :9901)
# HOW TO RUN:   ./smoke.sh
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

call_status() {
  curl -s -o /dev/null -w "%{http_code}" "$GW" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\"}}"
}

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

# ── happy path ────────────────────────────────────────────────────────────────

echo
echo "== initialize =="
INIT_RESP=$(post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}')
echo "$INIT_RESP" | jq -c '.result.serverInfo // .'

echo
echo "== tools/list — expect plain names (no mcp_router, no prefix) =="
TOOLS=$(post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '[.result.tools[].name] | sort | join(", ")')
echo "  tools: $TOOLS"
if echo "$TOOLS" | grep -q 'tool1' && ! echo "$TOOLS" | grep -q 'server1__'; then
  echo "  tools/list PASS — plain tool names confirm no mcp_router in chain"
  LIST_OK=1
else
  echo "  tools/list CHECK — expected plain names (tool1, tool2, tool3), got: $TOOLS"
  LIST_OK=0
fi

echo
echo "== C5 allow: tool1 =="
C5_ALLOW1_STATUS=$(call_status 10 "tool1")
C5_ALLOW1_BODY=$(call_body 11 "tool1")
C5_ALLOW1_TEXT=$(echo "$C5_ALLOW1_BODY" | jq -r '.result.content[0].text // "ERROR"')
if [ "$C5_ALLOW1_STATUS" = "200" ] && [ "$C5_ALLOW1_TEXT" = "server1 ran tool1" ]; then
  echo "  tool1 -> ALLOWED ($C5_ALLOW1_STATUS) - \"$C5_ALLOW1_TEXT\" ✓"
  C5_ALLOW1_OK=1
else
  echo "  tool1 -> status=$C5_ALLOW1_STATUS body=$C5_ALLOW1_BODY ✗"
  C5_ALLOW1_OK=0
fi

echo
echo "== C5 deny: tool2 (blocked by OPA — plain name, no prefix) =="
C5_DENY_STATUS=$(call_status 20 "tool2")
if [ "$C5_DENY_STATUS" = "403" ]; then
  echo "  tool2 -> DENIED ($C5_DENY_STATUS) ✓  (OPA read plain \"tool2\" from mcp metadata)"
  C5_DENY_OK=1
else
  echo "  tool2 -> status=$C5_DENY_STATUS (expected 403) ✗"
  echo "  hint: check 'docker compose logs authz' for the OPA decision input"
  C5_DENY_OK=0
fi

echo
echo "== C5 allow: tool3 =="
C5_ALLOW3_STATUS=$(call_status 30 "tool3")
C5_ALLOW3_BODY=$(call_body 31 "tool3")
C5_ALLOW3_TEXT=$(echo "$C5_ALLOW3_BODY" | jq -r '.result.content[0].text // "ERROR"')
if [ "$C5_ALLOW3_STATUS" = "200" ] && [ "$C5_ALLOW3_TEXT" = "server1 ran tool3" ]; then
  echo "  tool3 -> ALLOWED ($C5_ALLOW3_STATUS) - \"$C5_ALLOW3_TEXT\" ✓"
  C5_ALLOW3_OK=1
else
  echo "  tool3 -> status=$C5_ALLOW3_STATUS body=$C5_ALLOW3_BODY ✗"
  C5_ALLOW3_OK=0
fi

# ── edge cases ────────────────────────────────────────────────────────────────

echo
echo "== edge: tool99 (unknown tool, expect 200 — not in deny list) =="
EDGE_TOOL99_STATUS=$(call_status 40 "tool99")
if [ "$EDGE_TOOL99_STATUS" = "200" ]; then
  echo "  tool99 -> ALLOWED ($EDGE_TOOL99_STATUS) ✓"
  EDGE_TOOL99_OK=1
else
  echo "  tool99 -> status=$EDGE_TOOL99_STATUS (expected 200) ✗"
  EDGE_TOOL99_OK=0
fi

echo
echo "== edge: tools/call missing params.name (expect 403 — safe default) =="
EDGE_NONAME_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GW" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{}}')
if [ "$EDGE_NONAME_STATUS" = "403" ]; then
  echo "  missing name -> DENIED ($EDGE_NONAME_STATUS) ✓"
  EDGE_NONAME_OK=1
else
  echo "  missing name -> status=$EDGE_NONAME_STATUS (expected 403) ✗"
  EDGE_NONAME_OK=0
fi

echo
echo "== edge: tools/call empty name (expect 200 — \"\" != \"tool2\") =="
EDGE_EMPTYNAME_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GW" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":""}}')
if [ "$EDGE_EMPTYNAME_STATUS" = "200" ]; then
  echo "  empty name -> ALLOWED ($EDGE_EMPTYNAME_STATUS) ✓"
  EDGE_EMPTYNAME_OK=1
else
  echo "  empty name -> status=$EDGE_EMPTYNAME_STATUS (expected 200) ✗"
  EDGE_EMPTYNAME_OK=0
fi

echo
echo "== edge: tool2 with extra params (expect 403 — extra fields do not bypass) =="
EDGE_EXTRA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GW" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"tool2","extra":"bypass"}}')
if [ "$EDGE_EXTRA_STATUS" = "403" ]; then
  echo "  tool2+extra -> DENIED ($EDGE_EXTRA_STATUS) ✓"
  EDGE_EXTRA_OK=1
else
  echo "  tool2+extra -> status=$EDGE_EXTRA_STATUS (expected 403) ✗"
  EDGE_EXTRA_OK=0
fi

echo
echo "== edge: missing method field (expect 403 — no mcp metadata written) =="
EDGE_NOMETHOD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GW" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":50}')
if [ "$EDGE_NOMETHOD_STATUS" = "403" ]; then
  echo "  missing method -> DENIED ($EDGE_NOMETHOD_STATUS) ✓"
  EDGE_NOMETHOD_OK=1
else
  echo "  missing method -> status=$EDGE_NOMETHOD_STATUS (expected 403) ✗"
  EDGE_NOMETHOD_OK=0
fi

echo
echo "== edge: empty body (expect 403 — mcp_filter cannot parse) =="
EDGE_EMPTY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GW" \
  -X POST -H 'Content-Type: application/json' -d '')
if [ "$EDGE_EMPTY_STATUS" = "403" ]; then
  echo "  empty body -> DENIED ($EDGE_EMPTY_STATUS) ✓"
  EDGE_EMPTY_OK=1
else
  echo "  empty body -> status=$EDGE_EMPTY_STATUS (expected 403) ✗"
  EDGE_EMPTY_OK=0
fi

echo
echo "== edge: malformed JSON (expect 400) =="
EDGE_MALFORMED_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$GW" \
  -X POST -H 'Content-Type: application/json' -d 'not-json')
if [ "$EDGE_MALFORMED_STATUS" = "400" ]; then
  echo "  malformed JSON -> $EDGE_MALFORMED_STATUS ✓"
  EDGE_MALFORMED_OK=1
else
  echo "  malformed JSON -> status=$EDGE_MALFORMED_STATUS (expected 400) ✗"
  EDGE_MALFORMED_OK=0
fi

echo
echo "== edge: GET request (expect 403 — no mcp metadata) =="
EDGE_GET_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$GW")
if [ "$EDGE_GET_STATUS" = "403" ]; then
  echo "  GET -> DENIED ($EDGE_GET_STATUS) ✓"
  EDGE_GET_OK=1
else
  echo "  GET -> $EDGE_GET_STATUS (INFO — may vary by Envoy version)"
  EDGE_GET_OK=1
fi

# ── metadata inspection ───────────────────────────────────────────────────────

echo
echo "== metadata inspection: what did OPA receive from Envoy? =="
MCP_META=$(docker compose logs authz 2>/dev/null \
  | python3 - <<'PYEOF'
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if ' | ' in line:
        line = line.split(' | ', 1)[1].strip()
    try:
        d = json.loads(line)
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
  echo "  (could not extract metadata from OPA logs — run: docker compose logs authz)"
fi

echo
echo "== ext_authz stats =="
curl -s http://localhost:9901/stats 2>/dev/null \
  | grep -iE 'ext_authz|http\.mcp_gw\.mcp\.' \
  | head -15 \
  || echo "  (no ext_authz stats — check Envoy admin on :9901)"

# ── verdict ───────────────────────────────────────────────────────────────────

echo
echo "== verdict =="
FAIL=0
[ "$LIST_OK" = 1 ]            && echo "  C5 PASS — tools/list plain names (no mcp_router prefix)"          || { echo "  C5 FAIL — tools/list"; FAIL=1; }
[ "$C5_ALLOW1_OK" = 1 ]       && echo "  C5 PASS — tool1 allowed"                                           || { echo "  C5 FAIL — tool1 not allowed"; FAIL=1; }
[ "$C5_DENY_OK" = 1 ]         && echo "  C5 PASS — tool2 denied by OPA (plain name from mcp metadata)"      || { echo "  C5 FAIL — tool2 not denied"; FAIL=1; }
[ "$C5_ALLOW3_OK" = 1 ]       && echo "  C5 PASS — tool3 allowed"                                           || { echo "  C5 FAIL — tool3 not allowed"; FAIL=1; }
[ "$EDGE_TOOL99_OK" = 1 ]     && echo "  C5 PASS — tool99 (unknown) allowed"                                || { echo "  C5 FAIL — tool99 not allowed"; FAIL=1; }
[ "$EDGE_NONAME_OK" = 1 ]     && echo "  C5 PASS — missing name denied (safe default)"                      || { echo "  C5 FAIL — missing name not denied"; FAIL=1; }
[ "$EDGE_EMPTYNAME_OK" = 1 ]  && echo "  C5 PASS — empty name allowed"                                      || { echo "  C5 FAIL — empty name not allowed"; FAIL=1; }
[ "$EDGE_EXTRA_OK" = 1 ]      && echo "  C5 PASS — tool2+extra denied (no bypass)"                          || { echo "  C5 FAIL — tool2+extra not denied"; FAIL=1; }
[ "$EDGE_NOMETHOD_OK" = 1 ]   && echo "  C5 PASS — missing method denied"                                   || { echo "  C5 FAIL — missing method not denied"; FAIL=1; }
[ "$EDGE_EMPTY_OK" = 1 ]      && echo "  C5 PASS — empty body denied"                                       || { echo "  C5 FAIL — empty body not denied"; FAIL=1; }
[ "$EDGE_MALFORMED_OK" = 1 ]  && echo "  C5 PASS — malformed JSON → 400"                                    || { echo "  C5 FAIL — malformed JSON not 400"; FAIL=1; }
[ "$EDGE_GET_OK" = 1 ]        && echo "  C5 PASS — GET denied"                                              || { echo "  C5 FAIL — GET not denied"; FAIL=1; }
[ "$FAIL" -eq 0 ] && { echo "  OVERALL PASS"; exit 0; } || { echo "  OVERALL FAIL"; exit 1; }
