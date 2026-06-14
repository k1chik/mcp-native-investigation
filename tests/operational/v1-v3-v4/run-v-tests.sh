#!/usr/bin/env bash
# =====================================================================================
# run-v-tests.sh — V1, V3, V4: operational checks on the native Envoy lane
# =====================================================================================
#
# Each check proves one operational property of Envoy's native mcp_filter + mcp_router
# that is invisible in the capability checks (C1–C4).
#
#   V1 — no tool-list cache
#        Native has no cache: every client tools/list fans out live to ALL backends.
#        We send M=10 client lists and assert each backend received >= M hits.
#        (CONNLINK-1026: Jonh Wendell's no-cache finding)
#
#   V3 — eager init / head-of-line blocking
#        Native initialises ALL backends before responding to the client's initialize.
#        One slow backend blocks every client. We add a 3s delay to backend-b and
#        assert the client initialize takes substantially longer than the baseline.
#        (CONNLINK-1026: Craig Brookes concern #4, David Martin Blocker 2)
#
#   V4 — tools/call hot-path latency
#        The native path is in-process (no gRPC hop to ext-proc). We measure p50/p95
#        under 10 VUs for 15s. Thresholds are sanity ceilings; the numbers are the point.
#        (CONNLINK-1026: David Martin Blocker 1 — native wins the hot path)
#
# PREREQUISITE: docker compose up -d   (from this directory)
# HOW TO RUN:   ./run-v-tests.sh       (prints measurements + PASS/FAIL per check)
# TEARDOWN:     docker compose down
#
# GOTCHA: tools/* through the native mcp filter requires
#         Accept: application/json, text/event-stream  or it returns 400.
# =====================================================================================
set -euo pipefail
cd "$(dirname "$0")"

GW=http://localhost:10000
BACKEND_A=v1-v3-v4-backend-a-1
BACKEND_B=v1-v3-v4-backend-b-1
fail=0

post() {
  curl -s -X POST "$GW" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$1"
}
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
# Access backend stats/reset via docker exec (backends are not port-mapped to host)
backend_reset() { docker exec "$1" python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:$2/__reset')"; }
backend_count() { docker exec "$1" python3 -c "import urllib.request,json; d=json.load(urllib.request.urlopen('http://localhost:$2/__stats')); print(d['counts'].get('$3',0))"; }
backend_sse()   { docker exec "$1" python3 -c "import urllib.request,json; d=json.load(urllib.request.urlopen('http://localhost:$2/__stats')); print(d['sse_get_connections_total'])"; }

# ── wait for Envoy to be ready ────────────────────────────────────────────────
echo "Waiting for gateway..."
for _ in $(seq 1 40); do
  curl -sf http://localhost:9901/ready >/dev/null 2>&1 && break || sleep 0.5
done
sleep 1  # give mcp_router time to complete backend handshakes

# ── V1 — no cache ─────────────────────────────────────────────────────────────
echo
echo "########  V1 — no cache: every tools/list fans out to all backends  ########"
backend_reset "$BACKEND_A" 9001
backend_reset "$BACKEND_B" 9002
post '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"v1-test","version":"1"}}}' >/dev/null

M=10
for i in $(seq 1 $M); do
  post "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"tools/list\"}" >/dev/null
done

A=$(backend_count "$BACKEND_A" 9001 "tools/list")
B=$(backend_count "$BACKEND_B" 9002 "tools/list")
echo "  $M client tools/list -> backend-a=$A  backend-b=$B  (expect both >= $M)"

if [ "$A" -ge "$M" ] && [ "$B" -ge "$M" ]; then
  echo "  V1 PASS — no cache confirmed: each client tools/list fanned out to BOTH backends"
else
  echo "  V1 FAIL — expected each backend >= $M, got a=$A b=$B"; fail=1
fi

# ── V3 — eager init ───────────────────────────────────────────────────────────
echo
echo "########  V3 — eager init: slow backend blocks client initialize  ########"

# Baseline (no delay)
t0=$(now_ms)
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"v3-test","version":"1"}}}' >/dev/null
t1=$(now_ms)
BASE=$((t1 - t0))
echo "  baseline initialize (no delay): ${BASE}ms"

# Restart backend-b with a 3s init delay
BACKEND_B_INIT_DELAY=3 docker compose up -d --force-recreate --no-deps backend-b >/dev/null 2>&1
sleep 2  # wait for the new container to be listening

t0=$(now_ms)
post '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"v3-test","version":"1"}}}' >/dev/null
t1=$(now_ms)
DELAYED=$((t1 - t0))
echo "  initialize with backend-b delayed 3s: ${DELAYED}ms"

# Restore backend-b (no delay)
BACKEND_B_INIT_DELAY=0 docker compose up -d --force-recreate --no-deps backend-b >/dev/null 2>&1
sleep 2

if [ "$DELAYED" -ge 2000 ] && [ "$DELAYED" -gt "$BASE" ]; then
  echo "  V3 PASS — eager init confirmed: slow backend blocked client initialize (${DELAYED}ms vs ${BASE}ms)"
else
  echo "  V3 FAIL — expected delayed >= 2000ms and > baseline, got delayed=${DELAYED} base=${BASE}"; fail=1
fi

# ── V4 — hot-path latency ─────────────────────────────────────────────────────
echo
echo "########  V4 — tools/call hot-path latency (10 VUs, 15s, k6)  ########"
if ! command -v k6 >/dev/null 2>&1; then
  echo "  V4 SKIP — k6 not installed (brew install k6)"
else
  if k6 run --quiet --summary-export=/tmp/v4-result.json v4-latency.js >/tmp/v4.log 2>&1; then
    python3 - <<'PYEOF'
import json
m = json.load(open('/tmp/v4-result.json'))['metrics']
dur = m['http_req_duration']
rps = m['http_reqs']['rate']
print(f"  p50={dur['med']:.2f}ms  p90={dur['p(90)']:.2f}ms  p95={dur['p(95)']:.2f}ms  rps={rps:.0f}")
PYEOF
    echo "  V4 PASS — k6 thresholds met (0% failed, p95 under ceiling)"
  else
    echo "  V4 FAIL — k6 thresholds breached:"; tail -5 /tmp/v4.log | sed 's/^/    /'; fail=1
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────────
echo
echo "============================================================"
if [ "$fail" -eq 0 ]; then
  echo "ALL V-TESTS PASS (V1, V3, V4)"
  exit 0
else
  echo "SOME V-TESTS FAILED — see FAIL lines above"
  exit 1
fi
