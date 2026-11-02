#!/usr/bin/env bash
#
# verify_hermes.sh - Comprehensive health and end-to-end connectivity verification
# for the Hermes Desktop & Gateway stack on Fedora (192.168.4.19).
#

set -uo pipefail

TARGET_HOST="${TARGET_HOST:-192.168.4.19}"
SSH_USER="${SSH_USER:-shawn}"
MAC_IP="${MAC_IP:-192.168.4.8}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_KEY:-sk-hermes-mac-secret}"
DEFAULT_MODEL="${DEFAULT_MODEL:-coding-26b}"
QUICK_MODE=false

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --host <ip>          Target host running Hermes (default: 192.168.4.19)
  --user <user>        SSH user on target host (default: shawn)
  --mac-ip <ip>        Host Mac running LiteLLM (default: 192.168.4.8)
  --port <port>        LiteLLM proxy port (default: 4000)
  --key <key>          LiteLLM Bearer API key (default: sk-hermes-mac-secret)
  --model <model>      Default model name (default: coding-26b)
  --quick              Skip LLM completion inference test
  -h, --help           Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) TARGET_HOST="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;
    --mac-ip) MAC_IP="$2"; shift 2 ;;
    --port) LITELLM_PORT="$2"; shift 2 ;;
    --key) LITELLM_KEY="$2"; shift 2 ;;
    --model) DEFAULT_MODEL="$2"; shift 2 ;;
    --quick) QUICK_MODE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

pass() {
  echo -e "  [${GREEN}PASS${NC}] $1"
  ((PASSED++))
}

fail() {
  echo -e "  [${RED}FAIL${NC}] $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "         ${YELLOW}↳ Remediation: $2${NC}"
  fi
  ((FAILED++))
}

warn() {
  echo -e "  [${YELLOW}WARN${NC}] $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "         ${YELLOW}↳ Note: $2${NC}"
  fi
  ((WARNINGS++))
}

info() {
  echo -e "${CYAN}==>${NC} $1"
}

echo "========================================================"
echo " Hermes Desktop & Gateway Stack Verification Suite"
echo " Target Host: ${TARGET_HOST} (User: ${SSH_USER})"
echo " LiteLLM Mac: ${MAC_IP}:${LITELLM_PORT}"
echo "========================================================"
echo ""

# 1. Local LiteLLM Proxy Status (if run from Mac host)
info "1. Checking LiteLLM Proxy on Host Mac..."
if command -v curl >/dev/null 2>&1; then
  LOCAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 3 -H "Authorization: Bearer ${LITELLM_KEY}" "http://127.0.0.1:${LITELLM_PORT}/v1/models" 2>/dev/null || echo "000")
  if [[ "${LOCAL_CODE}" == "200" ]]; then
    pass "LiteLLM is listening locally on 127.0.0.1:${LITELLM_PORT} (HTTP 200)"
  else
    LAN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 3 -H "Authorization: Bearer ${LITELLM_KEY}" "http://${MAC_IP}:${LITELLM_PORT}/v1/models" 2>/dev/null || echo "000")
    if [[ "${LAN_CODE}" == "200" ]]; then
      pass "LiteLLM is reachable over LAN at ${MAC_IP}:${LITELLM_PORT} (HTTP 200)"
    else
      warn "LiteLLM not reachable directly on local test (HTTP local=${LOCAL_CODE}, lan=${LAN_CODE})" \
           "If running inside a VM or non-Mac node, verify LiteLLM on the Mac: launchctl print gui/\$(id -u)/com.litellm.proxy"
    fi
  fi
fi

# 2. SSH Reachability to Remote Host
info "2. Checking SSH Connectivity to ${TARGET_HOST}..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${TARGET_HOST}" "true" 2>/dev/null; then
  pass "SSH connectivity to ${SSH_USER}@${TARGET_HOST} successful"
else
  fail "Cannot reach ${SSH_USER}@${TARGET_HOST} via SSH" \
       "Check network, host power, or SSH key authorization (ssh ${SSH_USER}@${TARGET_HOST})"
  echo ""
  echo "Aborting remaining remote checks due to SSH failure."
  exit 1
fi

# 3. Host System Resources & Co-existence with Frigate
info "3. Inspecting Host Hardware & Resource Headroom..."
SYS_METRICS=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  LOAD=$(awk "{print \$1}" /proc/loadavg)
  MEM_TOTAL=$(free -m | awk "/Mem:/ {print \$2}")
  MEM_AVAIL=$(free -m | awk "/Mem:/ {print \$7}")
  echo "${LOAD} ${MEM_TOTAL} ${MEM_AVAIL}"
' 2>/dev/null)

read -r H_LOAD H_TOTAL H_AVAIL <<< "${SYS_METRICS}"
if [[ -n "${H_LOAD}" ]]; then
  echo "     LoadAvg: ${H_LOAD} | Total RAM: ${H_TOTAL}MB | Available RAM: ${H_AVAIL}MB"
  if (( $(echo "${H_LOAD} < 4.0" | bc -l 2>/dev/null || [ "${H_LOAD%.*}" -lt 4 ]) )); then
    pass "Host load average (${H_LOAD}) is within safe threshold (< 4.0)"
  else
    warn "Host load average is high (${H_LOAD})" "Check Frigate NVR or active container tasks"
  fi

  if [[ "${H_AVAIL}" -gt 1024 ]]; then
    pass "Available memory (${H_AVAIL}MB) is adequate for Hermes + Frigate"
  else
    warn "Available memory is low (${H_AVAIL}MB)" "Monitor for OOM events: dmesg -T | grep -i oom"
  fi
fi

# 4. Workspace Directory Permissions
info "4. Checking Workspace Directory Permissions (/home/${SSH_USER}/docker/hermes/data)..."
PERM_CHECK=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  DIR="/home/'"${SSH_USER}"'/docker/hermes/data"
  if [ ! -d "$DIR" ]; then
    echo "MISSING"
  else
    # Check octal permissions and owner
    stat -c "%a %u %g" "$DIR" 2>/dev/null || stat -f "%OLp %u %g" "$DIR" 2>/dev/null
  fi
' 2>/dev/null)

if [[ "${PERM_CHECK}" == "MISSING" ]]; then
  fail "Workspace directory /home/${SSH_USER}/docker/hermes/data does not exist" \
       "Run: ./run.sh upgrade --tags docker --limit ${TARGET_HOST}"
else
  read -r DIR_MODE DIR_UID DIR_GID <<< "${PERM_CHECK}"
  if [[ "${DIR_MODE}" == "777" ]]; then
    fail "Workspace has unsafe permissions: mode ${DIR_MODE} (world-writable)" \
         "Hermes trips unsafe_control_permissions! Fix with: ssh ${SSH_USER}@${TARGET_HOST} 'chmod 755 ~/docker/hermes/data'"
  elif [[ "${DIR_MODE}" == "755" || "${DIR_MODE}" == "750" || "${DIR_MODE}" == "700" ]]; then
    pass "Workspace permissions safe: mode ${DIR_MODE} (UID: ${DIR_UID}, GID: ${DIR_GID})"
  else
    warn "Workspace permissions are ${DIR_MODE}" "Recommended mode is 0755"
  fi
fi

# 5. Docker Container Status
info "5. Checking Docker Container Lifecycle..."
CONTAINERS_STATUS=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  docker ps -a --filter "name=hermes" --format "{{.Names}}: {{.Status}}"
' 2>/dev/null)

if echo "${CONTAINERS_STATUS}" | grep -q "hermes-gateway: Up"; then
  pass "Container 'hermes-gateway' is running"
else
  fail "Container 'hermes-gateway' is not running" \
       "Check logs: ssh ${SSH_USER}@${TARGET_HOST} 'docker logs hermes-gateway --tail 50'"
fi

if echo "${CONTAINERS_STATUS}" | grep -q "hermes-desktop: Up"; then
  pass "Container 'hermes-desktop' is running"
else
  fail "Container 'hermes-desktop' is not running" \
       "Check logs: ssh ${SSH_USER}@${TARGET_HOST} 'docker logs hermes-desktop --tail 50'"
fi

# 6. Desktop noVNC Port (6080)
info "6. Checking Virtual Desktop Port 6080..."
DESKTOP_PORT_STATUS=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  docker exec hermes-desktop supervisorctl status novnc 2>/dev/null || echo "UNKNOWN"
' 2>/dev/null)

if echo "${DESKTOP_PORT_STATUS}" | grep -q "RUNNING"; then
  pass "Desktop supervisor process 'novnc' is RUNNING"
else
  warn "Desktop supervisor process status: ${DESKTOP_PORT_STATUS}" \
       "Verify supervisor logs: ssh ${SSH_USER}@${TARGET_HOST} 'docker logs hermes-desktop --tail 30'"
fi

# 7. Internal TUI Gateway WebSocket Grant & Ticket Check
info "7. Checking Gateway TUI Bootstrap & Ephemeral Ticket..."
BOOTSTRAP_OUT=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  docker exec -u hermes hermes-gateway /opt/hermes/.venv/bin/python /opt/hermes/ui-tui/scripts/gateway_bootstrap.py 2>&1
' 2>/dev/null || echo "ERROR")

if echo "${BOOTSTRAP_OUT}" | grep -q "hermes-gateway-ticket"; then
  pass "TUI Gateway bootstrap successfully returned WebSocket grant and auth ticket"
elif echo "${BOOTSTRAP_OUT}" | grep -q "unsafe_control_permissions"; then
  fail "TUI Gateway rejected grant due to unsafe_control_permissions" \
       "Directory /opt/data is world-writable (0777). Run: ssh ${SSH_USER}@${TARGET_HOST} 'chmod 755 ~/docker/hermes/data'"
else
  warn "TUI Gateway bootstrap returned unexpected output: ${BOOTSTRAP_OUT}" \
       "If the gateway container just started, wait ~10s for cold-boot init to complete"
fi

# 8. Cross-Host Container to LiteLLM Connectivity
info "8. Checking Container-to-Mac LiteLLM Reachability (${MAC_IP}:${LITELLM_PORT})..."
CONTAINER_LITELLM_CODE=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" "
  docker exec hermes-gateway curl -s -o /dev/null -w '%{http_code}' -m 5 -H 'Authorization: Bearer ${LITELLM_KEY}' 'http://${MAC_IP}:${LITELLM_PORT}/v1/models' 2>/dev/null || echo '000'
" 2>/dev/null)

if [[ "${CONTAINER_LITELLM_CODE}" == "200" ]]; then
  pass "hermes-gateway reached LiteLLM proxy at http://${MAC_IP}:${LITELLM_PORT}/v1/models (HTTP 200)"
elif [[ "${CONTAINER_LITELLM_CODE}" == "401" || "${CONTAINER_LITELLM_CODE}" == "403" ]]; then
  fail "LiteLLM authentication failed (HTTP ${CONTAINER_LITELLM_CODE})" \
       "Verify Bearer token in files/litellm_mac_config.yaml matches LITELLM_KEY ('${LITELLM_KEY}')"
else
  fail "hermes-gateway cannot reach LiteLLM proxy (HTTP ${CONTAINER_LITELLM_CODE})" \
       "Check Mac firewall (PF), host IP binding (0.0.0.0:4000), or LAN routing"
fi

# 9. Active Profile Model Configuration
info "9. Checking Active Model Profile (/opt/data/config.yaml)..."
HERMES_MODEL_OUT=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get model 2>/dev/null || echo "ERROR"
' 2>/dev/null)

if echo "${HERMES_MODEL_OUT}" | grep -q "${DEFAULT_MODEL}"; then
  pass "Hermes profile model is correctly configured (${DEFAULT_MODEL})"
elif echo "${HERMES_MODEL_OUT}" | grep -q "opus"; then
  fail "Hermes profile defaulted to unconfigured model (e.g. opus)" \
       "Run: docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set model.default ${DEFAULT_MODEL} && docker restart hermes-gateway"
else
  warn "Hermes profile model output: ${HERMES_MODEL_OUT}" \
       "Ensure model.default matches your LiteLLM alias: ${DEFAULT_MODEL}"
fi

# 10. End-to-End Chat Completion Inference (optional)
if [[ "${QUICK_MODE}" == false ]]; then
  info "10. Testing End-to-End Inference Completion (ping test)..."
  LLM_RESPONSE=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" "
    docker exec hermes-gateway curl -s -m 20 -X POST 'http://${MAC_IP}:${LITELLM_PORT}/v1/chat/completions' \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer ${LITELLM_KEY}' \
      -d '{\"model\": \"${DEFAULT_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Respond with PONG only\"}], \"max_tokens\": 30}' 2>/dev/null || echo 'ERROR'
  " 2>/dev/null)

  if echo "${LLM_RESPONSE}" | grep -qi "pong"; then
    pass "End-to-end LLM inference test passed: received 'PONG' response"
  elif echo "${LLM_RESPONSE}" | grep -q "choices"; then
    pass "End-to-end LLM inference test passed: received valid JSON completion payload"
  else
    warn "Inference response unexpected or timed out" \
         "Response: ${LLM_RESPONSE}. Verify Ollama model status on the Mac (ollama ps)"
  fi
else
  info "10. Skipping End-to-End Inference Completion (--quick flag specified)"
fi

# 11. Speech-to-Text (STT) / MLX Whisper Integration
info "11. Checking Speech-to-Text (STT) & MLX Whisper Pipeline..."
if curl -s -m 2 "http://127.0.0.1:8080/health" 2>/dev/null | grep -q "ok"; then
  pass "MLX Whisper service is running locally on 127.0.0.1:8080"
elif curl -s -m 2 "http://${MAC_IP}:8080/health" 2>/dev/null | grep -q "ok"; then
  pass "MLX Whisper service is reachable on ${MAC_IP}:8080"
else
  warn "MLX Whisper service not responding on port 8080" \
       "Start or setup MLX Whisper on Mac: ./run.sh setup-whisper"
fi

CONTAINER_WHISPER_CHECK=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" "
  docker exec hermes-gateway curl -s -m 5 -H 'Authorization: Bearer ${LITELLM_KEY}' 'http://${MAC_IP}:${LITELLM_PORT}/v1/models' 2>/dev/null | grep -o '\"id\":\"whisper\"' || true
" 2>/dev/null)
if [[ -n "${CONTAINER_WHISPER_CHECK}" ]]; then
  pass "LiteLLM exposes 'whisper' audio_transcription model to hermes-gateway"
else
  warn "LiteLLM reachable but 'whisper' model missing from catalog" \
       "Ensure files/litellm_mac_config.yaml has whisper declared and reload LiteLLM"
fi

HERMES_STT_PROVIDER=$(ssh -o BatchMode=yes "${SSH_USER}@${TARGET_HOST}" '
  docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config get stt.provider 2>/dev/null || echo "UNSET"
' 2>/dev/null)
if echo "${HERMES_STT_PROVIDER}" | grep -q "openai"; then
  pass "Hermes STT provider configured: openai (routed to LiteLLM)"
else
  warn "Hermes STT provider is '${HERMES_STT_PROVIDER}'" \
       "Expected 'openai'. Set with: docker exec hermes-gateway /opt/hermes/.venv/bin/hermes config set stt.provider openai"
fi

echo ""
echo "========================================================"
echo -e " Verification Summary: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}, ${YELLOW}${WARNINGS} warnings${NC}"
echo "========================================================"

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
else
  exit 0
fi
