#!/usr/bin/env bash
# =====================================================================================
# run-v6.sh — V6: per-backend auth (distinct credentials per backend)
# =====================================================================================
#
# Proves the broker presents a DIFFERENT credential to each backend on its own
# upstream connection (tool listing + session). The client's auth header is not
# involved — this is purely broker→upstream auth.
#
# Setup: config.yaml gives server1 "Bearer cred-server1-AAA" and server2
# "Bearer cred-server2-BBB". Each mock backend records the Authorization header
# it received from whoever connected to it (GET /__stats -> seen_auth).
#
# Native negative: mcp_router forwards the client's headers uniformly to every
# backend. There is no per-backend broker credential — it is a broker residual.
#
# CONNLINK-1026: Craig Brookes concern #5 (per-backend auth)
#
# PREREQUISITE: docker compose up -d   (from this directory)
# HOW TO RUN:   ./run-v6.sh            (PASS/FAIL, exits non-zero on fail)
# TEARDOWN:     docker compose down
#
# GOTCHA: broker may start before the mocks accept connections. The script
# restarts the broker after mocks are ready so it connects cleanly and presents
# the credential on initialize/tools/list.
# =====================================================================================
set -uo pipefail
cd "$(dirname "$0")"

BROKER=http://localhost:8080/mcp
BACKEND_A=v6-backend-a-1
BACKEND_B=v6-backend-b-1
fail=0

hdr=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
seen() { docker exec "$1" python3 -c "import urllib.request,json; d=json.load(urllib.request.urlopen('http://localhost:$2/__stats')); print(d.get('seen_auth'))"; }

echo "Waiting for mocks to be ready..."
for _ in $(seq 1 30); do
  docker exec "$BACKEND_A" python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:9001/__stats')" >/dev/null 2>&1 && break || sleep 1
done

echo "Restarting broker so it connects to already-running mocks..."
docker compose restart broker >/dev/null 2>&1
sleep 6   # give broker time to initialize + connect to both backends

echo "Opening a client session to ensure broker connects to upstreams..."
curl -s -D /tmp/v6-hdrs.txt "${hdr[@]}" "$BROKER" \
  -X POST -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"v6-test","version":"1"}}}' \
  -o /dev/null
SESSION=$(grep -i 'mcp-session-id' /tmp/v6-hdrs.txt | awk '{print $2}' | tr -d '\r'); rm -f /tmp/v6-hdrs.txt
curl -s "${hdr[@]}" -H "Mcp-Session-Id: $SESSION" "$BROKER" \
  -X POST -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
curl -s "${hdr[@]}" -H "Mcp-Session-Id: $SESSION" "$BROKER" \
  -X POST -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' >/dev/null
sleep 2

echo
echo "########  V6 — per-backend auth: broker presents distinct creds  ########"
AUTH_A=$(seen "$BACKEND_A" 9001)
AUTH_B=$(seen "$BACKEND_B" 9002)
echo "  backend-a (server1) received from broker: $AUTH_A"
echo "  backend-b (server2) received from broker: $AUTH_B"

echo
if [ "$AUTH_A" = "Bearer cred-server1-AAA" ] && [ "$AUTH_B" = "Bearer cred-server2-BBB" ]; then
  echo "  V6 PASS — each backend received its OWN distinct credential from the broker."
  echo "            server1 <- cred-server1-AAA  |  server2 <- cred-server2-BBB"
  echo "            Native mcp_router has no equivalent — it forwards the client's"
  echo "            headers uniformly to all backends (no per-backend broker credential)."
else
  echo "  V6 FAIL — expected server1=AAA / server2=BBB, got a=[$AUTH_A] b=[$AUTH_B]"
  fail=1
fi

echo
echo "============================================================"
[ "$fail" -eq 0 ] && { echo "V6 PASS"; exit 0; } || { echo "V6 FAIL"; exit 1; }
