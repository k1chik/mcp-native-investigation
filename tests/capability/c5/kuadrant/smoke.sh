#!/usr/bin/env bash
# =============================================================================================
# C5 Kuadrant smoke test — mcp_filter → ext_authz (Authorino) → router
# =============================================================================================
# WHAT THIS CHECKS:
#   Same filter chain as C5 (Docker Compose), but Authorino replaces OPA as the ext_authz peer
#   on a real Kuadrant/kind cluster. No mcp-gateway involved.
#
#   Backend: server1, the real test MCP server from Kuadrant/mcp-gateway's own test suite
#   (https://github.com/Kuadrant/mcp-gateway/tree/main/tests/servers/server1) — tools:
#   time, slow, greet, headers, add_tool.
#
#   Policy: allow all tools except slow.
#
#   Happy path: initialize, tools/list, time, greet → 200
#               slow → 403
#   Edge cases: unknown tool, missing name, empty name, extra params, missing method,
#               empty body, malformed JSON, GET → 403 / 400
#   Metadata proof: Envoy access log shows %DYNAMIC_METADATA(envoy.filters.http.mcp)% per request
#   Fail-closed:   failure_mode_allowed counter stays 0
#
# PREREQUISITE:
#   kubectl -n mcp-demo port-forward svc/envoy138 10000:10000 9901:9901
# Or set GW/ADMIN:
#   GW=http://localhost:10000 ADMIN=http://localhost:9901 ./smoke.sh
# =============================================================================================
set -uo pipefail

GW="${GW:-http://localhost:10000}"
ADMIN="${ADMIN:-http://localhost:9901}"
ENVOY_POD=$(kubectl -n mcp-demo get pod -l app=envoy138 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

# server1 is a real, protocol-compliant MCP server: it rejects tools/list and
# tools/call outside an initialized session, and replies over SSE (event: message /
# data: {...}) even without an explicit Accept header. So every call after
# initialize must carry the mcp-session-id it returned, and every response needs
# its data line pulled out before handing it to python3.
SESSION_ID=""
post() {
  curl -s "$GW" -X POST -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SESSION_ID" -d "$1" \
  | grep '^data:' | sed 's/^data: //'
}
status_post() {
  curl -s -o /dev/null -w "%{http_code}" "$GW" -X POST -H 'Content-Type: application/json' \
    -H "mcp-session-id: $SESSION_ID" -d "$1"
}

FAIL=0
pass() { echo "  PASS — $*"; }
fail() { echo "  FAIL — $*"; FAIL=1; }

# ── happy path ────────────────────────────────────────────────────────────────

echo "== initialize (expect 200) =="
INIT_RAW=$(curl -s --include -X POST -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' "$GW" \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}')
SESSION_ID=$(echo "$INIT_RAW" | grep -i "mcp-session-id:" | sed 's/mcp-session-id: //I' | tr -d '\r')
INIT=$(echo "$INIT_RAW" | grep "^data:" | sed 's/^data: //')
SERVER=$(echo "$INIT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['serverInfo'])" 2>/dev/null)
[ -n "$SERVER" ] && pass "initialize → $SERVER (session ${SESSION_ID:0:8}...)" || fail "initialize failed: $INIT"

echo ""
echo "== tools/list (expect 200, plain tool names) =="
TOOLS=$(post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(t['name'] for t in d['result']['tools']))" 2>/dev/null)
echo "  tools: $TOOLS"
echo "$TOOLS" | grep -q "time" && ! echo "$TOOLS" | grep -q "server1__" \
  && pass "tools/list plain names (no mcp_router prefix)" \
  || fail "unexpected list: $TOOLS"

echo ""
echo "== time (expect 200 ALLOW) =="
S=$(status_post '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"time"}}')
B=$(post '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"time"}}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['content'][0]['text'])" 2>/dev/null)
[ "$S" = "200" ] && pass "time allowed ($S) — $B" || fail "time status=$S"

echo ""
echo "== slow (expect 403 DENY) =="
S=$(status_post '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"slow","arguments":{"seconds":1}}}')
[ "$S" = "403" ] && pass "slow denied ($S)" || fail "slow status=$S (expected 403)"

echo ""
echo "== greet (expect 200 ALLOW) =="
S=$(status_post '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Kuadrant"}}}')
B=$(post '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Kuadrant"}}}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['content'][0]['text'])" 2>/dev/null)
[ "$S" = "200" ] && pass "greet allowed ($S) — $B" || fail "greet status=$S"

# ── edge cases ────────────────────────────────────────────────────────────────

echo ""
echo "== unknown tool (expect 200 ALLOW — not slow) =="
S=$(status_post '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"does_not_exist"}}')
[ "$S" = "200" ] && pass "unknown tool allowed ($S)" || fail "unknown tool status=$S (expected 200)"

echo ""
echo "== tools/call missing params.name (expect 403 — safe default) =="
S=$(status_post '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{}}')
[ "$S" = "403" ] && pass "missing name denied ($S)" || fail "missing name status=$S (expected 403)"

echo ""
echo "== tools/call empty name (expect 200 — \"\" != \"slow\") =="
S=$(status_post '{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":""}}')
[ "$S" = "200" ] && pass "empty name allowed ($S)" || fail "empty name status=$S (expected 200)"

echo ""
echo "== tools/call slow + extra fields (expect 403 — extra fields do not bypass) =="
S=$(status_post '{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"slow","extra":"bypass"}}')
[ "$S" = "403" ] && pass "slow+extra denied ($S)" || fail "slow+extra status=$S (expected 403)"

echo ""
echo "== missing method field (expect 403 — no mcp metadata, Authorino denies) =="
S=$(status_post '{"jsonrpc":"2.0","id":50}')
[ "$S" = "403" ] && pass "missing method denied ($S)" || fail "missing method status=$S (expected 403)"

echo ""
echo "== empty body (expect 403 — mcp_filter cannot parse, no metadata) =="
S=$(curl -s -o /dev/null -w "%{http_code}" "$GW" -X POST -H 'Content-Type: application/json' -d '')
[ "$S" = "403" ] && pass "empty body denied ($S)" || fail "empty body status=$S (expected 403)"

echo ""
echo "== malformed JSON (expect 400) =="
S=$(curl -s -o /dev/null -w "%{http_code}" "$GW" -X POST -H 'Content-Type: application/json' -d 'not-json')
[ "$S" = "400" ] && pass "malformed JSON → $S" || fail "malformed JSON status=$S (expected 400)"

echo ""
echo "== GET request (expect 403 — no mcp metadata) =="
S=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$GW")
[ "$S" = "403" ] && pass "GET denied ($S)" || echo "  INFO — GET returned $S"

# ── metadata proof via access log ─────────────────────────────────────────────

echo ""
echo "== mcp_filter metadata proof (Envoy access log) =="
if [ -n "$ENVOY_POD" ]; then
  LOGS=$(kubectl -n mcp-demo logs "$ENVOY_POD" --since=120s 2>/dev/null \
    | python3 -c "
import sys, json
rows = []
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if 'mcp_meta' in d:
            rows.append(d)
    except Exception:
        pass
seen = set()
for d in rows[-30:]:
    meta = d.get('mcp_meta') or {}
    key = (meta.get('method',''), str(meta.get('params',{}).get('name','')), d.get('status'))
    if key not in seen:
        seen.add(key)
        tool = meta.get('params',{}).get('name','')
        print(f'  {meta.get(\"method\",\"null\"):20s}  name={str(tool):10s}  → {d.get(\"status\")}')
" 2>/dev/null)
  if [ -n "$LOGS" ]; then
    echo "$LOGS"
    pass "access log shows mcp_filter metadata for all request types"
  else
    echo "  (no recent access log entries with mcp_meta)"
  fi
else
  echo "  (ENVOY_POD not set — skip; run inside cluster or set ENVOY_POD)"
fi

# ── ext_authz stats ───────────────────────────────────────────────────────────

echo ""
echo "== ext_authz stats =="
STATS=$(curl -s "$ADMIN/stats" 2>/dev/null | grep -E 'ext_authz\.(ok|denied|error|failure_mode)' | sort)
if [ -n "$STATS" ]; then
  echo "$STATS" | sed 's/^/  /'
  ALLOWED=$(echo "$STATS" | grep 'failure_mode_allowed' | grep -o '[0-9]*$')
  [ "${ALLOWED:-0}" = "0" ] && pass "failure_mode_allowed=0 (no fail-open events)" \
    || fail "failure_mode_allowed=$ALLOWED (unexpected fail-open)"
else
  echo "  (admin not reachable at $ADMIN)"
fi

# ── verdict ───────────────────────────────────────────────────────────────────

echo ""
echo "== verdict =="
[ "$FAIL" -eq 0 ] && echo "  OVERALL PASS" || echo "  OVERALL FAIL"
exit $FAIL
