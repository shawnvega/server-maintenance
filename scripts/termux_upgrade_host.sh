#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

export PREFIX="/data/data/com.termux/files/usr"
export PATH="$PREFIX/bin:$PATH"
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log/sv"

log() {
  echo -e "\n\033[1;34m[UPGRADE]\033[0m \033[1m$1\033[0m"
}

# 1. Termux Native Packages
log "Step 1: Updating Termux native packages..."
pkg update -y
pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
pkg clean

# 2. PRoot Debian OS Packages
log "Step 2: Updating PRoot Debian system packages..."
proot-distro login debian -- bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get dist-upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'
  apt-get autoremove -y
  apt-get clean
"

# 3. Workload Python Virtual Environments
log "Step 3: Upgrading Python workloads (ESPHome, Device Builder, Hermes, faster-whisper)..."
proot-distro login debian -- bash -c "
  echo '--> Upgrading ESPHome & ESPHome Device Builder...'
  if [ -d /opt/esphome ]; then
    /opt/esphome/bin/pip install -U esphome esphome-device-builder
  else
    echo '/opt/esphome does not exist, skipping'
  fi

  echo '--> Upgrading Hermes Agent...'
  if [ -d /opt/hermes-agent ]; then
    /opt/hermes-agent/bin/pip install -U hermes-agent
  else
    echo '/opt/hermes-agent does not exist, skipping'
  fi

  echo '--> Upgrading faster-whisper (maintaining av>=13,<16 pin)...'
  if [ -d /opt/faster-whisper ]; then
    /opt/faster-whisper/bin/pip install -U 'faster-whisper' 'av>=13,<16'
  else
    echo '/opt/faster-whisper does not exist, skipping'
  fi
"

# 4. Service Restarts
log "Step 4: Restarting supervised services..."
if [ -d "$SVDIR/hermes-dashboard" ]; then
  echo "Restarting hermes-dashboard..."
  sv force-restart hermes-dashboard || sv restart hermes-dashboard || true
fi

if [ -d "$SVDIR/faster-whisper" ]; then
  echo "Restarting faster-whisper..."
  sv force-restart faster-whisper || sv restart faster-whisper || true
fi

if [ -d "$SVDIR/esphome-builder" ]; then
  echo "Restarting esphome-builder..."
  sv force-restart esphome-builder || sv restart esphome-builder || true
fi

# Allow services 4 seconds to re-bind
sleep 4

# 5. Verification
log "Step 5: Verifying workloads and services..."
echo "--- ESPHome & Device Builder Version ---"
if command -v esphome >/dev/null 2>&1; then
  esphome version || true
else
  echo "esphome command not found"
fi
if command -v esphome-device-builder >/dev/null 2>&1; then
  esphome-device-builder --version || true
else
  echo "esphome-device-builder command not found"
fi

echo -e "\n--- Hermes Agent Version ---"
if [ -x /data/data/com.termux/files/usr/bin/hermes ]; then
  hermes version || true
else
  proot-distro login debian -- /opt/hermes-agent/bin/hermes version || true
fi

echo -e "\n--- faster-whisper Health ---"
curl -fsS http://127.0.0.1:8081/health && echo " [OK]" || echo " [FAIL]"

echo -e "\n--- hermes-dashboard Status ---"
curl -s -o /dev/null -w "Dashboard HTTP Code: %{http_code}\n" http://127.0.0.1:9119/ || echo " [FAIL]"

echo -e "\n--- esphome-builder Port 6055 Check ---"
nc -z 127.0.0.1 6055 && echo "Port 6055 listening [OK]" || echo "Port 6055 unreachable [FAIL]"

echo -e "\n--- Termux Services Status ---"
sv status "$SVDIR"/*

log "Upgrade completed successfully!"
