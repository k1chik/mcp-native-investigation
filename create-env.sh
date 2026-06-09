#!/usr/bin/env bash
#
# create-env.sh: set up everything needed for the Envoy-MCP side-by-side test setup.
#
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ SINGLE SOURCE OF TRUTH for the environment (tools + pinned versions).         │
# │ RULE: whenever you add a tool/software or bump a pinned version, update THIS   │
# │ file FIRST, then the docker-compose files that reference it.                   │
# │ If it's not in here, it's not part of the reproducible environment.           │
# └─────────────────────────────────────────────────────────────────────────────┘
#
# Run it cold on a fresh machine and it should "just work":
#   - checks the tools you need (and installs the easy ones on macOS via Homebrew)
#   - clones Envoy and mcp-gateway and pins them to the exact versions we cite
#   - pulls the Envoy Docker image
#   - runs cheap smoke checks so you know it's ready
#
# Usage:
#   ./create-env.sh                 # set up in ./mcp-investigation-env
#   ./create-env.sh /path/to/dir    # set up somewhere else
#   ./create-env.sh --smoke         # also build+test mcp-gateway (slower, proves the Go toolchain)
#
# Safe to run more than once — it updates existing clones instead of failing.

set -euo pipefail

# ---- pinned versions ----
ENVOY_TAG="v1.38.0"
MCPGW_TAG="v0.7.0"          # latest stable release (commit 5d96c6f); native MCP work targets the unreleased v0.8
ENVOY_IMAGE="envoyproxy/envoy:${ENVOY_TAG}"
MOCK_IMAGE="python:3.12-slim"          # runs the mock MCP backends (mocks/ + native-lane/)
OPA_IMAGE="openpolicyagent/opa:1.17.1-envoy"   # ext_authz authorizer (native-lane-authz/); amd64-only
BROKER_IMAGE="ghcr.io/kuadrant/mcp-gateway:v0.7.0"   # the mcp-gateway broker (broker-lane/), the comparison lane
TEST_SERVER1_IMAGE="ghcr.io/kuadrant/mcp-gateway/test-server1:latest"   # broker-compatible backends for the fair latency comparison (v4-fair/)
TEST_SERVER2_IMAGE="ghcr.io/kuadrant/mcp-gateway/test-server2:latest"
USERSPEC_IMAGE="ghcr.io/kuadrant/mcp-gateway/test-user-specific-server:latest"   # per-user tool lists (c4b/)

# ---- args ----
RUN_SMOKE=0
WORKDIR=""
for arg in "$@"; do
  case "$arg" in
    --smoke) RUN_SMOKE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) WORKDIR="$arg" ;;
  esac
done
WORKDIR="${WORKDIR:-$(pwd)/mcp-investigation-env}"

# ---- tiny helpers ----
red() { printf '\033[31m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m\n' "$1"; }
ylw() { printf '\033[33m%s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

IS_MAC=0; [ "$(uname -s)" = "Darwin" ] && IS_MAC=1
MISSING=0

# Check a required tool. On macOS, offer to brew install if a formula is given.
need() {
  local cmd="$1" why="$2" formula="${3:-}"
  if have "$cmd"; then
    grn "  ok    $cmd — $why"
  elif [ "$IS_MAC" = 1 ] && [ -n "$formula" ] && have brew; then
    ylw "  install $cmd via Homebrew ($formula)..."
    brew install "$formula"
    grn "  ok    $cmd (installed)"
  else
    red "  MISSING $cmd — $why"
    [ -n "$formula" ] && red "          install: brew install $formula   (or your package manager)"
    MISSING=1
  fi
}

echo "=============================================="
echo " Envoy-MCP test environment"
echo " target dir : $WORKDIR"
echo " Envoy      : $ENVOY_TAG"
echo " mcp-gateway: $MCPGW_TAG"
echo "=============================================="

# ── What each tool/image is for ──────────────────────────────────────────────
#   git      : clone the Envoy + mcp-gateway source and pin it to exact versions
#   docker   : runs every moving part (Envoy, the mocks, OPA, the broker) as containers
#   go       : compiles mcp-gateway from source (only if you build it locally)
#   make     : drives mcp-gateway's build/test targets
#   jq       : reads/filters the JSON-RPC responses and Envoy /stats in the test scripts
#   k6       : fires many tools/call requests and reports p50/p99 for the latency test
#   gh       : open PRs/issues (optional)
#   python3  : run the mock MCP backends directly without Docker (optional)
# Images (pulled in step 4):
#   envoy:v1.38.0          : the native MCP filter chain under test (mcp_filter + mcp_router)
#   python:3.12-slim       : base image the mock MCP backends run on
#   opa:<ver>-envoy        : Open Policy Agent with Envoy's ext_authz gRPC plugin; a Rego
#                            policy reads the MCP tool name from Envoy's dynamic metadata
#                            and allows/denies the call (stands in for Authorino, needs k8s)
#   mcp-gateway:v0.7.0     : the incumbent broker (the comparison lane)
#   test-server1/2         : broker-compatible MCP backends (official SDK) for the fair latency comparison
# ─────────────────────────────────────────────────────────────────────────────

echo
echo "1) Checking required tools"
need git    "clone the source and pin exact versions"                 git
need docker "runs Envoy, the mocks, OPA, and the broker as containers" ""   # install Docker Desktop / OrbStack manually
need go     "compiles mcp-gateway from source"                        go
need make   "drives mcp-gateway build/test targets"                   make
need jq     "reads JSON-RPC + Envoy /stats in the test scripts"        jq
need k6     "fires many tools/call requests, reports p50/p99" k6
have gh && grn "  ok    gh — open PRs/issues (optional)" || ylw "  note  gh not found (only needed to open PRs)"
have python3 && grn "  ok    python3 — run the mock backends without Docker (optional)" || ylw "  note  python3 not found (only needed to run the mocks without Docker)"

if [ "$MISSING" = 1 ]; then
  echo; red "Some required tools are missing — install them and re-run. Stopping."
  exit 1
fi

# Docker daemon must actually be running.
echo
echo "2) Checking the Docker daemon"
if docker info >/dev/null 2>&1; then
  grn "  ok    docker daemon is up ($(docker context show 2>/dev/null || echo default))"
else
  red "  MISSING docker daemon is not running — start Docker Desktop / OrbStack and re-run."
  exit 1
fi

# Clone + pin a repo to an exact ref. Idempotent.
clone_pin() {
  local url="$1" dir="$2" ref="$3"
  if [ -d "$dir/.git" ]; then
    echo "  updating $dir"
    git -C "$dir" fetch --tags --quiet
  else
    echo "  cloning $dir"
    git clone --quiet "$url" "$dir"
  fi
  git -C "$dir" checkout --quiet "$ref"
  grn "  ok    $dir @ $(git -C "$dir" describe --tags 2>/dev/null || echo "$ref")"
}

echo
echo "3) Cloning + pinning source"
mkdir -p "$WORKDIR"
clone_pin "https://github.com/envoyproxy/envoy.git"    "$WORKDIR/envoy"       "$ENVOY_TAG"
clone_pin "https://github.com/Kuadrant/mcp-gateway.git" "$WORKDIR/mcp-gateway" "$MCPGW_TAG"

echo
echo "4) Pulling container images"
docker pull --quiet "$ENVOY_IMAGE" >/dev/null && grn "  ok    $ENVOY_IMAGE"
docker pull --quiet "$MOCK_IMAGE" >/dev/null && grn "  ok    $MOCK_IMAGE (runs the mock backends)"
docker pull --quiet --platform linux/amd64 "$OPA_IMAGE" >/dev/null && grn "  ok    $OPA_IMAGE (ext_authz authorizer; amd64/emulated)"
docker pull --quiet "$BROKER_IMAGE" >/dev/null && grn "  ok    $BROKER_IMAGE (broker comparison lane)"
docker pull --quiet "$TEST_SERVER1_IMAGE" >/dev/null && grn "  ok    $TEST_SERVER1_IMAGE (latency comparison backend)"
docker pull --quiet "$TEST_SERVER2_IMAGE" >/dev/null && grn "  ok    $TEST_SERVER2_IMAGE (latency comparison backend)"
docker pull --quiet "$USERSPEC_IMAGE" >/dev/null && grn "  ok    $USERSPEC_IMAGE (user-specific tool list backend)"

echo
echo "5) Smoke checks"
docker run --rm "$ENVOY_IMAGE" --version >/dev/null && grn "  ok    Envoy image runs ($ENVOY_TAG)"
if [ "$RUN_SMOKE" = 1 ]; then
  ylw "  building + testing mcp-gateway (this is the slow part)..."
  make -C "$WORKDIR/mcp-gateway" build
  make -C "$WORKDIR/mcp-gateway" test
  grn "  ok    mcp-gateway builds and tests pass"
else
  ylw "  skipped mcp-gateway build/test — re-run with --smoke to include it"
fi

echo
grn "=============================================="
grn " Environment ready."
grn "   clones : $WORKDIR/{envoy,mcp-gateway}"
grn "   Envoy  : $ENVOY_TAG    mcp-gateway: $MCPGW_TAG"
grn " Next:"
grn "   - start the mock backends:  cd mocks && docker compose up   (see mocks/README.md)"
grn "   - run a lane:               cd native-lane && docker compose up"
grn "=============================================="
