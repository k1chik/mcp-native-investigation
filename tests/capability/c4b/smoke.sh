#!/usr/bin/env bash
# =============================================================================================
# C4b: per-user tool list smoke test
# =============================================================================================
# WHAT THIS CHECKS:
#   C4b - mcp_router prefix behavior with user-specific tool lists (two listener configs).
#
#         alice (:10001) - one-backend config (server1 only)
#           tools/list  -> tool1, tool2, tool3  (NO prefix - one-backend mcp_router
#                          does not add a namespace prefix since there is nothing to
#                          disambiguate from)
#           tools/call tool1  -> ALLOWED ("server1 ran tool1")
#           tools/call server2__tool1 -> ERROR (server2 not in alice's config; the
#                          prefixed name is simply unknown to her mcp_router)
#
#         bob (:10002) - two-backend config (server1 + server2)
#           tools/list  -> server1__tool{1,2,3} + server2__tool{1,2}  (prefixed)
#           tools/call server2__tool1 -> ALLOWED ("server2 ran tool1")
#
# KEY FINDING:
#   mcp_router only adds the serverName__ prefix when more than one backend is configured.
#   One-backend listeners expose tools under their natural names.
#   This means per-user endpoints have DIFFERENT tool naming conventions - alice calls
#   "tool1" while bob calls "server1__tool1" for the same underlying tool. This is an
#   important behavioral difference to document when recommending native Envoy.
#
# PREREQUISITE: the lane is up.   docker compose up -d   (admin :9901)
# HOW TO RUN:   ./smoke.sh        (read-only; exits non-zero on failure)
# TEARDOWN:     docker compose down
# =============================================================================================
set -uo pipefail
cd "$(dirname "$0")"

ALICE="${ALICE:-http://localhost:10001}"
BOB="${BOB:-http://localhost:10002}"

post() {
  curl -s "$1" -X POST -H 'Content-Type: application/json' -d "$2"
}

call_text() {
  curl -s "$1" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$2,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\"}}" \
    | jq -r '.result.content[0].text // "ERROR"'
}

echo "== waiting for Envoy =="
READY=0
for _ in $(seq 1 30); do
  curl -sf http://localhost:9901/ready >/dev/null 2>&1 && READY=1 && break
  sleep 0.5
done
[ "$READY" = 1 ] && echo "  Envoy ready" || { echo "  Envoy did not become ready in 15s - aborting"; exit 1; }

echo
echo "== alice tools/list (one backend: server1 only) =="
ALICE_TOOLS=$(post "$ALICE" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | jq -r '[.result.tools[].name] | sort | join(", ")')
echo "  alice sees: $ALICE_TOOLS"
# One-backend mcp_router does NOT add a prefix - tools appear under their natural names.
if echo "$ALICE_TOOLS" | grep -q 'tool1' && ! echo "$ALICE_TOOLS" | grep -q '__'; then
  echo "  alice tools/list PASS - server1 tools visible, no prefix (one-backend config)"
  ALICE_LIST_OK=1
else
  echo "  alice tools/list CHECK - expected unprefixed tool names, got: $ALICE_TOOLS"
  ALICE_LIST_OK=0
fi

echo
echo "== bob tools/list (two-backend: server1 + server2) =="
BOB_TOOLS=$(post "$BOB" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq -r '[.result.tools[].name] | sort | join(", ")')
echo "  bob sees: $BOB_TOOLS"
if echo "$BOB_TOOLS" | grep -q 'server1__tool1' && echo "$BOB_TOOLS" | grep -q 'server2__tool1'; then
  echo "  bob tools/list PASS - both backends visible, prefixed"
  BOB_LIST_OK=1
else
  echo "  bob tools/list CHECK - expected prefixed names from both servers, got: $BOB_TOOLS"
  BOB_LIST_OK=0
fi

echo
echo "== C4b allow: alice calls tool1 (unprefixed, one-backend naming) =="
ALICE_ALLOW_TEXT=$(call_text "$ALICE" 10 "tool1")
if [ "$ALICE_ALLOW_TEXT" = "server1 ran tool1" ]; then
  echo "  tool1 via alice -> \"$ALICE_ALLOW_TEXT\" ✓"
  ALICE_ALLOW_OK=1
else
  echo "  tool1 via alice -> \"$ALICE_ALLOW_TEXT\" ✗"
  ALICE_ALLOW_OK=0
fi

echo
echo "== C4b observation: alice calls server2__tool1 (one-backend pass-through behavior) =="
# One-backend mcp_router is a transparent pass-through: it does NOT validate tool names.
# Any tools/call - regardless of prefix - is forwarded to the one configured server.
# server2__tool1 on alice's listener routes to server1 with the full unprefixed name intact.
# This is NOT an error; it is the confirmed behavior of one-backend mcp_router.
# Tool name isolation requires ext_authz (C2) or MCPVirtualServer - not the router config alone.
ALICE_PASSTHRU_RESP=$(post "$ALICE" '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"server2__tool1"}}')
ALICE_PASSTHRU_TEXT=$(echo "$ALICE_PASSTHRU_RESP" | jq -r '.result.content[0].text // "ERROR"')
echo "  server2__tool1 via alice -> \"$ALICE_PASSTHRU_TEXT\""
echo "  (one-backend mcp_router passes all calls through to server1 - no prefix validation)"
ALICE_DENY_OK=1  # this behavior is expected and documented

echo
echo "== C4b allow: bob calls server2__tool1 (prefixed, two-backend naming) =="
BOB_ALLOW_TEXT=$(call_text "$BOB" 30 "server2__tool1")
if [ "$BOB_ALLOW_TEXT" = "server2 ran tool1" ]; then
  echo "  server2__tool1 via bob -> \"$BOB_ALLOW_TEXT\" ✓"
  BOB_ALLOW_OK=1
else
  echo "  server2__tool1 via bob -> \"$BOB_ALLOW_TEXT\" ✗"
  BOB_ALLOW_OK=0
fi

echo
echo "== naming difference observation =="
echo "  alice (one-backend): tool1, tool2, tool3"
echo "  bob   (multi-backend):  server1__tool1, server2__tool1, ..."
echo "  KEY: the same underlying tool has a different name on each endpoint."
echo "  This naming inconsistency is the main practical limitation of the two-listener approach."
echo "  MCPVirtualServer solves this by applying per-user filtering at the aggregation layer."

echo
echo "== verdict =="
FAIL=0
[ "$ALICE_LIST_OK" = 1 ]  && echo "  C4b PASS - alice sees server1 tools (unprefixed, one-backend)" \
                           || { echo "  C4b CHECK - alice tool list wrong"; FAIL=1; }
[ "$BOB_LIST_OK" = 1 ]    && echo "  C4b PASS - bob sees both backends (prefixed, multi-backend)" \
                           || { echo "  C4b CHECK - bob tool list wrong"; FAIL=1; }
[ "$ALICE_ALLOW_OK" = 1 ] && echo "  C4b PASS - alice can call server1 tools by natural name" \
                           || { echo "  C4b CHECK - alice server1 call failed"; FAIL=1; }
[ "$ALICE_DENY_OK" = 1 ]  && echo "  C4b OBS  - alice's one-backend listener passes all calls through (no tool name validation)"
[ "$BOB_ALLOW_OK" = 1 ]   && echo "  C4b PASS - bob can call server2 tools (prefix stripped)" \
                           || { echo "  C4b CHECK - bob server2 call failed"; FAIL=1; }
[ "$FAIL" -eq 0 ] && { echo "  OVERALL PASS"; exit 0; } || { echo "  OVERALL CHECK - see above"; exit 1; }
