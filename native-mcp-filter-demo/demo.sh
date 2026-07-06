#!/usr/bin/env bash
# demo.sh — Kuadrant community call demo
#
# WHY: mcp-gateway uses a custom ext-proc component just to extract the tool
# name from MCP requests for policy checks. Envoy 1.38 does that natively.
# If it works, we remove a piece of custom code from the critical request
# path entirely.
#
# PREREQUISITES (already done, survives reboots only if kind cluster is still up):
#   - kind cluster "kuadrant-poc" running  →  check with: kind get clusters
#   - Envoy 1.38, server1, Authorino all deployed in the cluster
#
# HOW TO START THE DEMO (every time, two terminals):
#
#   Terminal 1 — keep this running in the background the whole time:
#     kubectl --context kind-kuadrant-poc -n mcp-demo port-forward svc/envoy138 10000:10000 9901:9901
#
#   Terminal 2 — the recording terminal:
#     cd ~/Downloads/000-dev/0-repo/mcp-native-investigation
#     source native-mcp-filter-demo/demo.sh
#
# THEN run these one at a time as you narrate:
#   connect        →  initialize session with the MCP server through Envoy
#   list_tools     →  list available tools (highlights "slow" as blocked)
#   call_allowed   →  call "time" tool  →  200 ALLOWED
#   call_blocked   →  call "slow" tool  →  403 DENIED
#   show_proof     →  Envoy access log proof + fail-closed stat
#   tail_authorino →  (if asked) live tail of Authorino's raw allow/deny log
#             Ctrl+C to stop the tail and return to the prompt.
#             Note while narrating: this raw log shows authorized:true/false
#             per request, but NOT the tool name (that only lives in Envoy's
#             ext_authz metadata — see show_proof's mcp_meta for the tool name proof).

GW="http://localhost:10000/mcp"
ADMIN="http://localhost:9901"
KCTX="kind-kuadrant-poc"

_hdr() {
  echo ""
  echo "══════════════════════════════════════════════════"
  printf "  %s\n" "$*"
  echo "══════════════════════════════════════════════════"
  echo ""
}

_mcp() {
  # POST a JSON-RPC request and return only the SSE data line
  curl -s --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $SESSION_ID" \
    "$GW" --data "$1" \
  | grep "^data:" | sed 's/^data: //'
}

_mcp_status() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $SESSION_ID" \
    "$GW" --data "$1"
}

# ─────────────────────────────────────────────────────────
connect() {
  _hdr "STEP 1 — Connect to the MCP server through Envoy"

  local resp
  resp=$(curl -s --include --max-time 10 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    "$GW" \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"0"}}}')

  export SESSION_ID
  SESSION_ID=$(echo "$resp" | grep -i "mcp-session-id:" | sed 's/mcp-session-id: //I' | tr -d '\r')

  local server_name
  server_name=$(echo "$resp" | grep "^data:" | sed 's/^data: //' \
    | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['result']['serverInfo']['name'])" 2>/dev/null)

  echo "  Server:     $server_name"
  echo "  Session ID: $SESSION_ID"
  echo ""
  echo "  Request path:"
  echo "    curl → Envoy 1.38 (mcp_filter → ext_authz) → Authorino → server1"
}

# ─────────────────────────────────────────────────────────
list_tools() {
  _hdr "STEP 2 — List available tools"

  _mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
tools = d['result']['tools']
print(f'  {len(tools)} tools on this server:')
print()
for t in tools:
    name = t['name']
    desc = t['description']
    flag = '  ← BLOCKED by policy' if name == 'slow' else ''
    print(f'    {name:15s}  {desc}{flag}')
print()
print('  Policy: deny tools/call where name == \"slow\"')
"
}

# ─────────────────────────────────────────────────────────
call_allowed() {
  _hdr "STEP 3 — Call 'time' (allowed)"

  local code result
  code=$(_mcp_status '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"time"}}')
  result=$(_mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"time"}}' \
    | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['result']['content'][0]['text'])" 2>/dev/null)

  echo "  HTTP $code — ALLOWED"
  echo ""
  echo "  Result: $result"
  echo ""
  echo "  What happened:"
  echo "    mcp_filter extracted  →  method=tools/call  name=time"
  echo "    Authorino decided     →  ALLOW  (time ≠ slow)"
  echo "    Request forwarded     →  server1 returned the current time"
}

# ─────────────────────────────────────────────────────────
call_blocked() {
  _hdr "STEP 4 — Call 'slow' (blocked)"

  local code
  code=$(_mcp_status '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow","arguments":{"seconds":3}}}')

  echo "  HTTP $code — DENIED"
  echo ""
  echo "  What happened:"
  echo "    mcp_filter extracted  →  method=tools/call  name=slow"
  echo "    Authorino decided     →  DENY  (slow = blocked tool)"
  echo "    Request stopped       →  never reached the backend server"
}

# ─────────────────────────────────────────────────────────
show_proof() {
  _hdr "STEP 5 — Evidence: what the filter extracted"

  local envoy_pod
  envoy_pod=$(kubectl --context "$KCTX" -n mcp-demo get pod -l app=envoy138 \
    -o jsonpath='{.items[0].metadata.name}')

  echo "  Envoy access log — mcp_filter metadata per request:"
  echo ""
  printf "  %-22s %-14s %s\n" "method" "name" "→ status"
  printf "  %-22s %-14s %s\n" "──────────────────────" "──────────────" "────────"

  kubectl --context "$KCTX" -n mcp-demo logs "$envoy_pod" --since=10m 2>/dev/null \
  | python3 -c "
import sys, json
seen = set()
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        meta = d.get('mcp_meta') or {}
        if not meta:
            continue
        method = meta.get('method', '')
        name   = str((meta.get('params') or {}).get('name', ''))
        status = d.get('status', '')
        key = (method, name, status)
        if key not in seen:
            seen.add(key)
            print(f'  {method:22s} {name:14s} → {status}')
    except Exception:
        pass
"

  echo ""
  echo "  ext_authz counters (Envoy admin):"
  echo ""
  curl -s "$ADMIN/stats" 2>/dev/null \
    | grep -E 'http\.mcp_gw\.ext_authz\.(ok|denied|failure_mode_allowed)' \
    | sort \
    | python3 -c "
import sys
for line in sys.stdin:
    key, val = line.strip().rsplit(': ', 1)
    short = key.split('ext_authz.')[1]
    note = ''
    if 'failure_mode_allowed' in key and val == '0':
        note = '  ← fail-closed: nothing slipped through'
    print(f'    {short:30s} {val}{note}')
"
}

# ─────────────────────────────────────────────────────────
tail_authorino() {
  _hdr "STEP 6 (if asked) — Raw Authorino allow/deny log, live"

  echo "  Caveat: this raw log shows authorized:true/false per request,"
  echo "  but NOT the tool name — that only lives in Envoy's ext_authz"
  echo "  metadata. For the tool-name proof, point back at show_proof's mcp_meta."
  echo ""
  echo "  Tailing live — call call_allowed/call_blocked again in another pane to"
  echo "  generate traffic, or just narrate off what's already in the buffer."
  echo "  Press Ctrl+C to stop and return to the prompt."
  echo ""

  kubectl --context "$KCTX" -n kuadrant-system logs deploy/authorino -f --tail=20 2>/dev/null \
  | python3 -u -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get('msg') != 'outgoing authorization response':
        continue
    rid = d.get('request id', '')[:8]
    ok = d.get('authorized')
    verdict = 'ALLOW' if ok else 'DENY '
    ts = d.get('ts', '')
    print(f'  {ts}  [{rid}]  {verdict}')
"
}
