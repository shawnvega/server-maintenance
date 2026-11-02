#!/usr/bin/env bash
# =============================================================================
# verify_homepage.sh - Health and Integration Check for Homepage Dashboard
# =============================================================================
# Verifies:
#   1. Direct container HTTP endpoint (http://192.168.4.5:3001)
#   2. Caddy reverse proxy HTTP endpoint (http://192.168.4.5)
#   3. Docker socket accessibility inside container (no EACCES)
#   4. Host validation (no Next.js 400 Bad Request)
#   5. Glances API endpoints across cluster hosts
# =============================================================================

set -euo pipefail

TARGET_HOST="192.168.4.5"
PASS_COUNT=0
FAIL_COUNT=0

log_pass() {
  echo -e "\033[32m[PASS]\033[0m $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
  echo -e "\033[31m[FAIL]\033[0m $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "=== 1. Checking Direct Container Endpoint (Port 3001) ==="
CODE_3001=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://${TARGET_HOST}:3001/" || echo "000")
if [[ "${CODE_3001}" == "200" ]]; then
  log_pass "Direct container endpoint returned HTTP 200 OK"
else
  log_fail "Direct container endpoint returned HTTP ${CODE_3001} (expected 200)"
fi

echo "=== 2. Checking Caddy Reverse Proxy Endpoint (Port 80) ==="
CODE_80=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://${TARGET_HOST}/" || echo "000")
if [[ "${CODE_80}" == "200" ]]; then
  log_pass "Caddy reverse proxy returned HTTP 200 OK"
else
  log_fail "Caddy reverse proxy returned HTTP ${CODE_80} (expected 200)"
fi

echo "=== 3. Checking Glances API Endpoints across Nodes ==="
for IP in "192.168.4.5" "192.168.4.4" "192.168.4.19"; do
  GLANCES_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "http://${IP}:61208/api/4/quicklook" || echo "000")
  if [[ "${GLANCES_CODE}" == "200" ]]; then
    log_pass "Glances v4 API responsive on ${IP}:61208"
  else
    log_fail "Glances API unreachable or non-200 on ${IP}:61208 (HTTP ${GLANCES_CODE})"
  fi
done

echo "=== 4. Checking Container Log for Permissions & Errors ==="
RECENT_LOGS=$(ssh "shawn@${TARGET_HOST}" "docker logs homepage --tail 50 2>&1" || echo "LOG_FETCH_ERROR")
if echo "${RECENT_LOGS}" | grep -q "EACCES"; then
  log_fail "Detected EACCES in Homepage logs (Docker socket permission issue)"
else
  log_pass "No EACCES permission errors detected in recent logs"
fi

if echo "${RECENT_LOGS}" | grep -q "Host validation failed"; then
  log_fail "Detected Host validation failure in Homepage logs (HOMEPAGE_ALLOWED_HOSTS required)"
else
  log_pass "No Host validation errors detected in recent logs"
fi

echo ""
echo "=== Verification Summary ==="
echo "Passed: ${PASS_COUNT} | Failed: ${FAIL_COUNT}"
if [[ ${FAIL_COUNT} -eq 0 ]]; then
  echo -e "\033[32mAll Homepage integration checks passed successfully!\033[0m"
  exit 0
else
  echo -e "\033[31mSome checks failed. See details above.\033[0m"
  exit 1
fi
