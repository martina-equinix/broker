#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Broker integration test
#
# Starts the full docker compose stack, waits for all containers to be healthy,
# runs a set of tests against Harbor and ArgoCD through the broker, then prints
# a summary.
#
# Usage:
#   ./test.sh            # start stack, run tests, leave stack running
#   ./test.sh --down     # tear down stack after tests
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENV_FILE=".env.harbor"
COMPOSE_FILE="docker-compose.harbor.yml"
TEARDOWN=false
if [[ "${1:-}" == "--down" ]]; then TEARDOWN=true; fi

# ── colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
BOLD='\033[1m'

pass() { echo -e "  ${GREEN}✔${RESET}  $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "  ${RED}✗${RESET}  $1"; FAILED=$((FAILED+1)); }
info() { echo -e "  ${YELLOW}→${RESET}  $1"; }
PASSED=0; FAILED=0

# ── load env ──────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}Error:${RESET} $ENV_FILE not found. Copy .env.harbor.example and fill in credentials."
  exit 1
fi
# shellcheck disable=SC2046
export $(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | \
  sed 's/\$\$/\$/g' | xargs)   # unescape $$ → $ for shell use

SERVER_PORT="${SERVER_PORT:-7341}"
HARBOR_PORT="${HARBOR_PORT:-8001}"
ARGOCD_PORT="${ARGOCD_PORT:-8002}"
BROKER_SERVER="http://localhost:${SERVER_PORT}"
HARBOR_BROKER_URL="${BROKER_SERVER}/broker/${HARBOR_BROKER_TOKEN}"
ARGOCD_BROKER_URL="${BROKER_SERVER}/broker/${ARGOCD_BROKER_TOKEN}"

# ── start stack ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}▶  Starting broker stack…${RESET}"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up --build -d 2>&1 \
  | grep -E "Container|Built|error" || true

# ── wait for health ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}▶  Waiting for containers to be healthy…${RESET}"
wait_healthy() {
  local name=$1 port=$2
  local deadline=$((SECONDS+60))
  while [[ $SECONDS -lt $deadline ]]; do
    if curl -sf "http://localhost:${port}/healthcheck" | grep -q '"ok":true'; then
      pass "$name is healthy"
      return 0
    fi
    sleep 2
  done
  fail "$name did not become healthy within 60s"
  return 1
}
wait_healthy "broker-server        (port ${SERVER_PORT})" "$SERVER_PORT"
wait_healthy "broker-harbor-client (port ${HARBOR_PORT})" "$HARBOR_PORT"
wait_healthy "broker-argocd-client (port ${ARGOCD_PORT})" "$ARGOCD_PORT"

# ── helper ────────────────────────────────────────────────────────────────────
# check_http <label> <url> <expected_jq_expression> <expected_value>
check_http() {
  local label=$1 url=$2 jq_expr=$3 expected=$4
  local response actual
  response=$(curl -sf "$url" 2>/dev/null || true)
  if [[ -z "$response" ]]; then
    fail "$label — no response from $url"
    return
  fi
  actual=$(echo "$response" | jq -r "$jq_expr" 2>/dev/null || echo "__jq_error__")
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label — expected '${expected}', got '${actual}'"
    info "url: $url"
    info "raw: $(echo "$response" | head -c 200)"
  fi
}

# ── harbor tests ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}▶  Harbor tests (via broker)${RESET}"

check_http \
  "Harbor systeminfo reachable" \
  "${HARBOR_BROKER_URL}/api/v2.0/systeminfo" \
  '.harbor_version | startswith("v")' \
  "true"

check_http \
  "Harbor projects list returns results" \
  "${HARBOR_BROKER_URL}/api/v2.0/projects" \
  'length > 0' \
  "true"

check_http \
  "Harbor search for 'equinixmetal' returns results" \
  "${HARBOR_BROKER_URL}/api/v2.0/search?q=equinixmetal" \
  '.repository | length > 0' \
  "true"

check_http \
  "Harbor artifacts for equinixmetal/backstage returns results" \
  "${HARBOR_BROKER_URL}/api/v2.0/projects/equinixmetal-proxy/repositories/equinixmetal%252Fbackstage/artifacts?page=1&page_size=10&with_tag=true&with_label=false&with_scan_overview=true&with_signature=false&with_immutable_status=false" \
  'length > 0' \
  "true"

# ── argocd tests ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}▶  ArgoCD tests (via broker)${RESET}"

check_http \
  "ArgoCD applications list reachable" \
  "${ARGOCD_BROKER_URL}/api/v1/applications" \
  '.items | length > 0' \
  "true"

check_http \
  "ArgoCD app 'backstage-stage-dc13-sec' is Healthy" \
  "${ARGOCD_BROKER_URL}/api/v1/applications/backstage-stage-dc13-sec?appNamespace=argocd" \
  '.status.health.status' \
  "Healthy"

check_http \
  "ArgoCD app 'backstage-stage-dc13-sec' is Synced" \
  "${ARGOCD_BROKER_URL}/api/v1/applications/backstage-stage-dc13-sec?appNamespace=argocd" \
  '.status.sync.status' \
  "Synced"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Results ─────────────────────────────────────────────────${RESET}"
echo -e "  ${GREEN}Passed: ${PASSED}${RESET}   ${RED}Failed: ${FAILED}${RESET}"
echo ""

if [[ "$TEARDOWN" == true ]]; then
  echo -e "${BOLD}▶  Tearing down stack…${RESET}"
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
fi

[[ $FAILED -eq 0 ]] && exit 0 || exit 1


