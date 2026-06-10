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
#   ./run-tests.sh list         # show available lanes
#   ./run-tests.sh --help
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

# ---- dispatch --------------------------------------------------------------------------------
run_all() {
  run_c1_c3_c4a
}

list() {
  cat <<'EOF'
LANE          PROVES
c1-c3-c4a     C1 (MCP parse), C3 (fan-out + prefix-merge), C4a (prefix-strip routing)
EOF
}

usage() {
  cat <<'EOF'
run-tests.sh - run the investigation's test lanes

Usage: ./run-tests.sh [TARGET]

TARGETS:
  all (default)   run every available lane
  c1-c3-c4a       C1, C3, C4a capability checks
  list            show available lanes and what they prove
  --help          this message

Each lane spins up its own Docker environment, runs the smoke check, and tears down.
Pull images once first with ./create-env.sh.
EOF
}

case "$MODE" in
  -h|--help|help) usage; exit 0 ;;
  list)           list;  exit 0 ;;
  all)            run_all ;;
  c1-c3-c4a)     run_c1_c3_c4a ;;
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
