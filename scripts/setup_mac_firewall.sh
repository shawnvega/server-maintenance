#!/usr/bin/env bash
#
# setup_mac_firewall.sh - Configure macOS Packet Filter (PF) and environment for
# hosting Ollama and MLX Whisper backends securely for Raspberry Pi 5 (192.168.4.5).
#

set -euo pipefail

PI5_IP="192.168.4.5"
ANCHOR_FILE="/etc/pf.anchors/com.homelab.litellm"
PF_CONF="/etc/pf.conf"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${CYAN}==>${NC} $1"; }
pass() { echo -e "  [${GREEN}PASS${NC}] $1"; }
warn() { echo -e "  [${YELLOW}WARN${NC}] $1"; }

info "1. Configuring Ollama environment for network binding (0.0.0.0:11434)..."
launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
export OLLAMA_HOST="0.0.0.0:11434"
pass "OLLAMA_HOST set to 0.0.0.0:11434. (Restart Ollama.app if running as a GUI application)"

info "2. Writing macOS PF anchor rule (${ANCHOR_FILE})..."
cat << 'EOF' | sudo tee "${ANCHOR_FILE}" > /dev/null
# -------------------------------------------------------------
# Homelab Backend Access Rules for Ollama (11434) & MLX Whisper (8080)
# -------------------------------------------------------------
# 1. Unrestricted loopback for local tools, CLI, and apps on the Mac
pass quick on lo0 all

# 2. Allow Raspberry Pi 5 to access inference backends
pass in quick proto tcp from 192.168.4.5 to any port { 11434, 8080 }

# 3. Block all other devices on the LAN/Wi-Fi from accessing these ports
block drop in quick proto tcp from any to any port { 11434, 8080 }
EOF
pass "Wrote PF anchor file ${ANCHOR_FILE}"

info "3. Cleaning and structuring ${PF_CONF} in correct PF order..."
# Clean any previous duplicate lines from pf.conf
sudo tee "${PF_CONF}" > /dev/null << 'EOF'
#
# Default PF configuration file.
#
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"

# Homelab anchor for Ollama and MLX Whisper
anchor "com.homelab.litellm"
load anchor "com.homelab.litellm" from "/etc/pf.anchors/com.homelab.litellm"
EOF
pass "Structured ${PF_CONF} with correct rule ordering"

info "4. Validating and reloading PF rules..."
sudo pfctl -vnf "${PF_CONF}" >/dev/null
sudo pfctl -ef "${PF_CONF}" 2>/dev/null || sudo pfctl -f "${PF_CONF}"
pass "macOS PF firewall reloaded and active"

info "5. Decommissioning Mac LiteLLM LaunchAgent (moved to Pi 5)..."
if [[ -f "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist" ]]; then
  launchctl unload "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist" 2>/dev/null || true
  mv "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist" "${HOME}/Library/LaunchAgents/com.litellm.proxy.plist.bak"
  pass "Disabled com.litellm.proxy LaunchAgent on Mac (backup saved to .bak)"
else
  pass "No active com.litellm.proxy LaunchAgent found on Mac"
fi

echo ""
echo -e "${GREEN}==> Mac Backend & Firewall Configuration Complete!${NC}"
echo "Summary:"
echo " - Localhost (127.0.0.1) has 100% full access to all ports without filtering."
echo " - Raspberry Pi 5 (192.168.4.5) is granted access to ports 11434 (Ollama) and 8080 (MLX Whisper)."
echo " - All other LAN devices are blocked from ports 11434 and 8080."
echo " - LiteLLM LaunchAgent on Mac has been unloaded and disabled."
