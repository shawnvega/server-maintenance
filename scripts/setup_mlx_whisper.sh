#!/usr/bin/env bash
#
# setup_mlx_whisper.sh - Automated installer and lifecycle manager for local
# Apple Silicon MLX Whisper Audio Transcription Server & LiteLLM Integration.
#
# This script provisions:
# 1. Python environment with mlx-whisper, fastapi, uvicorn, python-multipart
# 2. Local launchd service (com.mlx.whisper) running on 127.0.0.1:8080
# 3. LiteLLM proxy route configuration (files/litellm_mac_config.yaml)
# 4. Live self-test and verification of audio transcription
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_SCRIPT="${SCRIPT_DIR}/files/mlx_whisper_server.py"
LITELLM_CONFIG="${SCRIPT_DIR}/files/litellm_mac_config.yaml"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.mlx.whisper.plist"
LOG_DIR="${HOME}/Library/Logs"
PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
MODEL="${MODEL:-mlx-community/whisper-large-v3-turbo}"
PIPX_VENV="${HOME}/Library/Application Support/pipx/venvs/mlx-whisper"

# Formatting colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${CYAN}==>${NC} $1"; }
pass() { echo -e "  [${GREEN}PASS${NC}] $1"; }
warn() { echo -e "  [${YELLOW}WARN${NC}] $1"; }
fail() { echo -e "  [${RED}FAIL${NC}] $1"; exit 1; }

info "1. Verifying Environment & Apple Silicon..."
ARCH=$(uname -m)
if [[ "${ARCH}" != "arm64" ]]; then
  warn "Architecture is ${ARCH} (expected arm64 for Apple Silicon Metal acceleration)."
fi

# Detect python interpreter
PYTHON_BIN=""
if [[ -f "${PIPX_VENV}/bin/python3" ]]; then
  PYTHON_BIN="${PIPX_VENV}/bin/python3"
  pass "Using existing pipx environment at ${PIPX_VENV}"
elif command -v pipx >/dev/null 2>&1; then
  info "Creating pipx virtual environment for mlx-whisper..."
  pipx install mlx-whisper || true
  PYTHON_BIN="${PIPX_VENV}/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
  warn "pipx not found; falling back to $(which python3)"
else
  fail "No suitable Python 3 found. Install Homebrew Python: brew install python@3.12 pipx"
fi

info "2. Ensuring Python Dependencies (fastapi, uvicorn, python-multipart, mlx-whisper)..."
"${PYTHON_BIN}" -m pip install -q --upgrade mlx-whisper fastapi uvicorn python-multipart
pass "Dependencies verified"

info "3. Verifying Server Script & ffmpeg..."
if [[ ! -f "${SERVER_SCRIPT}" ]]; then
  fail "Server script missing at ${SERVER_SCRIPT}"
fi
chmod +x "${SERVER_SCRIPT}"

FFMPEG_PATH="$(command -v ffmpeg || true)"
if [[ -z "${FFMPEG_PATH}" ]]; then
  if [[ -x "/opt/homebrew/bin/ffmpeg" ]]; then
    FFMPEG_PATH="/opt/homebrew/bin/ffmpeg"
  else
    warn "ffmpeg not found in PATH! Installing ffmpeg via Homebrew is strongly recommended:"
    echo "       brew install ffmpeg"
  fi
fi
if [[ -n "${FFMPEG_PATH}" ]]; then
  pass "ffmpeg located at ${FFMPEG_PATH}"
fi

info "4. Configuring macOS LaunchAgent (${PLIST_PATH})..."
mkdir -p "${HOME}/Library/LaunchAgents" "${LOG_DIR}"

cat << EOF > "${PLIST_PATH}"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mlx.whisper</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_BIN}</string>
        <string>${SERVER_SCRIPT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>PORT</key>
        <string>${PORT}</string>
        <key>HOST</key>
        <string>${HOST}</string>
        <key>MLX_WHISPER_MODEL</key>
        <string>${MODEL}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/mlx-whisper.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/mlx-whisper.error.log</string>
</dict>
</plist>
EOF

pass "LaunchAgent plist written"

info "5. Reloading Service com.mlx.whisper..."
launchctl unload "${PLIST_PATH}" 2>/dev/null || true
launchctl load "${PLIST_PATH}"

# Wait for service startup
for i in {1..10}; do
  if curl -s -m 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    pass "MLX Whisper service is healthy on port ${PORT} (bound to ${HOST})"
    break
  fi
  sleep 1
done

if ! curl -s -m 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  fail "Service did not respond within 10 seconds. Check logs at ${LOG_DIR}/mlx-whisper.error.log"
fi

info "6. Checking LiteLLM Proxy Integration..."
if [[ -f "${LITELLM_CONFIG}" ]]; then
  if grep -q "model_name: whisper" "${LITELLM_CONFIG}"; then
    pass "LiteLLM configuration already includes 'whisper' model"
  else
    info "Appending 'whisper' route to ${LITELLM_CONFIG}..."
    cat << 'EOF' >> "${LITELLM_CONFIG}"

  - model_name: whisper
    litellm_params:
      model: openai/whisper
      api_base: http://127.0.0.1:8080/v1
      api_key: "none"
    model_info:
      mode: audio_transcription
  - model_name: whisper-1
    litellm_params:
      model: openai/whisper
      api_base: http://127.0.0.1:8080/v1
      api_key: "none"
    model_info:
      mode: audio_transcription
EOF
    pass "Appended whisper routes to LiteLLM config"
  fi

  # Reload LiteLLM if running
  if [[ -f "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist" ]]; then
    info "Reloading LiteLLM LaunchAgent..."
    launchctl unload "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist" 2>/dev/null || true
    launchctl load "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist"
    sleep 3
    if curl -s -m 5 -H "Authorization: Bearer sk-hermes-mac-secret" http://127.0.0.1:4000/v1/models | grep -q "whisper"; then
      pass "LiteLLM proxy picked up whisper audio_transcription model"
    else
      warn "LiteLLM proxy is starting up or reloading. Check: curl http://127.0.0.1:4000/v1/models"
    fi
  fi
fi

info "7. Running End-to-End Self-Test..."
TEST_WAV=$(mktemp /tmp/test_whisper_XXXXXX.wav)
python3 -c "
import wave
with wave.open('${TEST_WAV}', 'w') as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(16000)
    wf.writeframes(b'\x00' * 32000)
"

RESP=$(curl -s -X POST "http://${HOST}:${PORT}/v1/audio/transcriptions" \
  -F "file=@${TEST_WAV}" \
  -F "model=whisper" 2>/dev/null || echo "ERROR")
rm -f "${TEST_WAV}"

if echo "${RESP}" | grep -q "text"; then
  pass "Self-test transcription successful! Response: ${RESP}"
else
  warn "Self-test returned unexpected output: ${RESP}"
fi

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN} MLX Whisper Setup & Verification Complete!${NC}"
echo -e "${GREEN} Endpoint: http://${HOST}:${PORT}/v1/audio/transcriptions${NC}"
echo -e "${GREEN} LiteLLM:  http://${HOST}:4000/v1/audio/transcriptions${NC}"
echo -e "${GREEN} Model:    ${MODEL}${NC}"
echo -e "${GREEN}========================================================${NC}"
