#!/usr/bin/env bash
# =============================================================================================
# run-tests.sh - run the investigation's test lanes
# =============================================================================================
# Each lane provisions its own environment (docker compose up -> test -> down) and is
# independent of every other lane. Lanes share host ports so they run sequentially.
#
# PREREQUISITES: docker, jq
#   Pull images first with ./create-env.sh (one-time; pins exact versions).
#
# USAGE:
#   ./run-tests.sh              # run all available lanes
#   ./run-tests.sh c1-c3-c4a   # run one lane by name
#   ./run-tests.sh list         # show available lanes and what they prove
#   ./run-tests.sh ?            # same as list
#   ./run-tests.sh clean        # tear down any stacks left running (e.g. after a crash)
#   ./run-tests.sh --help       # full usage
# =============================================================================================
set -uo pipefail
cd "$(dirname "$0")"

MODE="${1:-all}"

# ---- helpers ---------------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1 (install it and re-run)"; exit 2; }; }
wait_http() { for _ in $(seq 1 40); do curl -sf "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

declare -a IDS STATUSES
record() { IDS+=("$1"); STATUSES+=("$2"); }

# Run a docker-compose lane: up -> wait for readiness -> smoke -> down.
# Records PASS or FAIL by exit code.
lane() {
  local id="$1" dir="$2" ready="$3"; shift 3
  echo
  echo "==================== $id ===================="
  ( cd "$dir" && docker compose up -d >/dev/null 2>&1 )
  wait_http "$ready" || echo "  (readiness check timed out - trying anyway)"
  sleep 1
  ( cd "$dir" && "$@" ); local rc=$?
  ( cd "$dir" && docker compose down >/dev/null 2>&1 )
  [ "$rc" -eq 0 ] && record "$id" PASS || record "$id" FAIL
}

# ---- lane runners ----------------------------------------------------------------------------
# Add one run_* function and one entry in run_all() for each new lane.

run_c1_c3_c4a() {
  need docker; need jq
  lane "C1 / C3 / C4a" \
    tests/capability/c1-c3-c4a \
    http://localhost:9901/ready \
    ./smoke.sh
}

run_c2() {
  need docker; need jq
  lane "C2" \
    tests/capability/c2 \
    http://localhost:9901/ready \
    ./smoke.sh
}

run_c4b() {
  need docker; need jq
  lane "C4b" \
    tests/capability/c4b \
    http://localhost:9901/ready \
    ./smoke.sh
}

run_v1_v3_v4() {
  need docker; need python3
  lane "V1 / V3 / V4" \
    tests/operational/v1-v3-v4 \
    http://localhost:9901/ready \
    ./run-v-tests.sh
}

run_v2() {
  need docker; need python3
  lane "V2" \
    tests/operational/v2 \
    http://localhost:9901/ready \
    ./run-v2.sh
}

run_v6() {
  need docker; need python3
  # V6 uses the broker on :8080, not Envoy — use the broker readiness as the check
  lane "V6" \
    tests/operational/v6 \
    http://localhost:8080/healthz \
    ./run-v6.sh
}

run_c5() {
  need docker; need jq
  lane "C5" \
    tests/capability/c5 \
    http://localhost:9901/ready \
    ./smoke.sh
}

# ---- dispatch --------------------------------------------------------------------------------
run_all() {
  run_c1_c3_c4a
  run_c2
  run_c4b
  run_c5
  run_v1_v3_v4
  run_v2
  run_v6
}

list() {
  cat <<'EOF'
LANE          PROVES
c1-c3-c4a     C1 (MCP parse), C3 (fan-out + prefix-merge), C4a (prefix-strip routing)
c2            C2 (ext_authz reads envoy.filters.http.mcp metadata; allow/deny by tool name)
c4b           C4b (prefix strip with per-user tool list; two listener configs)
c5            C5 (single-server: mcp_filter + ext_authz + router; no mcp-gateway needed)
v1-v3-v4      V1 (no cache: M client lists -> M hits per backend), V3 (eager init blocks on slow backend), V4 (tools/call p50/p95 latency)
v2            V2 (no SSE relay: 405 on client GET; zero backend SSE connections from mcp_router)
v6            V6 (per-backend auth: broker presents distinct credential per upstream; native has no equivalent)
EOF
}

usage() {
  cat <<'EOF'
run-tests.sh - run the investigation's test lanes

Usage: ./run-tests.sh [TARGET]

TARGETS:
  all (default)   run every available lane
  c1-c3-c4a       C1, C3, C4a capability checks
  c2              C2 metadata-based ext_authz check
  c4b             C4b per-user tool list prefix strip
  c5              C5 single-server MCP gateway (mcp_filter + ext_authz + router; no mcp-gateway)
  v1-v3-v4        V1 (no cache), V3 (eager init), V4 (tools/call latency)
  v2              V2 (no SSE relay in either direction)
  v6              V6 (per-backend auth: broker distinct credentials per backend)
  list / ?        show available lanes and what they prove
  clean           tear down any stacks left running (use after a crashed run)
  --help          this message

Each lane spins up its own Docker environment, runs the smoke check, and tears down.
Pull images once first with ./create-env.sh.
EOF
}

clean() {
  echo "Tearing down any running lane stacks..."
  for dir in \
    tests/capability/c1-c3-c4a \
    tests/capability/c2 \
    tests/capability/c4b \
    tests/capability/c5 \
    tests/operational/v1-v3-v4 \
    tests/operational/v2 \
    tests/operational/v6
  do
    ( cd "$dir" && docker compose down --remove-orphans 2>/dev/null ) && echo "  cleaned $dir"
  done
  echo "Done."
}

case "$MODE" in
  -h|--help|help) usage; exit 0 ;;
  list|'?')       list;  exit 0 ;;
  clean)          clean; exit 0 ;;
  all)            run_all ;;
  c1-c3-c4a)     run_c1_c3_c4a ;;
  c2)             run_c2 ;;
  c4b)            run_c4b ;;
  c5)             run_c5 ;;
  v1-v3-v4)       run_v1_v3_v4 ;;
  v2)             run_v2 ;;
  v6)             run_v6 ;;
  *) echo "unknown target: '$MODE'"; echo; usage; exit 2 ;;
esac

# ---- scorecard -------------------------------------------------------------------------------
echo
echo "============================== SCORECARD =============================="
fail=0
for i in "${!IDS[@]}"; do
  printf "  %-30s %s\n" "${IDS[$i]}" "${STATUSES[$i]}"
  [[ "${STATUSES[$i]}" == FAIL* ]] && fail=1
done
echo "======================================================================="
[ "$fail" -eq 0 ] && { echo "ALL PASSED"; exit 0; } || { echo "SOME FAILED"; exit 1; }
