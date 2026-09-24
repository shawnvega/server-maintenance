#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

# Ensure venv exists and is functional
if [ ! -d "${VENV_DIR}" ] || ! "${VENV_DIR}/bin/python3" --version >/dev/null 2>&1; then
  echo "Virtual environment missing or invalid at ${VENV_DIR}."
  echo "Creating virtual environment and installing dependencies..."
  rm -rf "${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"
fi

ANSIBLE_PLAYBOOK="${VENV_DIR}/bin/ansible-playbook"
ANSIBLE="${VENV_DIR}/bin/ansible"

usage() {
  local exit_code="${1:-0}"
  echo "Usage: $0 [command] [options...]"
  echo ""
  echo "Commands:"
  echo "  ping                 Test SSH connectivity to all servers"
  echo "  backup               Run backup (rpi-clone) on configured servers"
  echo "  upgrade              Run full upgrade pipeline on standard servers"
  echo "  upgrade-ro           Run upgrade on read-only Pi (192.168.4.11 OverlayFS cycle)"
  echo "  upgrade-pikvm        Run upgrade on PiKVM (192.168.4.66 pikvm-update & RO restore)"
  echo "  upgrade-all          Run concurrent upgrades across ALL servers (standard + read-only Pi + PiKVM)"
  echo "  cleanup              Reclaim disk space (journal vacuum, apt cache, docker prune)"
  echo "  restart-vlc          Restart persistent VLC video stream (192.168.4.18)"
  echo "  playbook <file.yml>  Run a custom playbook"
  echo "  raw <command>        Run an ad-hoc shell command on all servers"
  echo ""
  echo "Examples:"
  echo "  $0 ping"
  echo "  $0 backup -K                       # Run backup only"
  echo "  $0 cleanup -K                      # Clean disk space across standard servers"
  echo "  $0 cleanup --limit 192.168.4.18 -K # Clean disk space on specific host"
  echo "  $0 restart-vlc                     # Restart VLC stream on 192.168.4.18"
  echo "  $0 upgrade -K                      # Standard servers: backup -> OS/Snap -> Docker -> VLC"
  echo "  $0 upgrade-ro -K                   # Read-only Pi (192.168.4.11) upgrade cycle"
  echo "  $0 upgrade-pikvm                   # PiKVM (192.168.4.66) upgrade cycle"
  echo "  $0 upgrade-all -K                  # All servers simultaneously (strategy: free)"
  echo "  $0 upgrade --tags os -K            # OS package upgrades only"
  echo "  $0 upgrade --tags snap -K          # Snap package upgrades only"
  echo "  $0 upgrade --tags vlc              # Restart VLC stream only"
  echo "  $0 upgrade --tags docker           # Docker containers only (minimal downtime)"
  echo "  $0 upgrade --skip-tags backup -K   # Skip backup and run OS + Docker upgrades"
  echo "  $0 upgrade --limit 192.168.4.4 -K  # Run on a single server only"
  echo "  $0 raw 'uptime'"
  exit "${exit_code}"
}

if [ $# -eq 0 ]; then
  usage 1
fi

CMD="$1"
shift || true

case "${CMD}" in
  ping)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/ping.yml" "$@"
    ;;
  backup)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/backup.yml" "$@"
    ;;
  upgrade)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/upgrade.yml" "$@"
    ;;
  upgrade-ro)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/readonly_upgrade.yml" "$@"
    ;;
  upgrade-pikvm)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/pikvm_upgrade.yml" "$@"
    ;;
  upgrade-all)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/upgrade_all.yml" "$@"
    ;;
  cleanup)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/cleanup.yml" "$@"
    ;;
  restart-vlc)
    exec "${ANSIBLE_PLAYBOOK}" "${SCRIPT_DIR}/upgrade.yml" --tags vlc --limit 192.168.4.18 -e "force_vlc_restart=true" "$@"
    ;;
  playbook)
    exec "${ANSIBLE_PLAYBOOK}" "$@"
    ;;
  raw)
    exec "${ANSIBLE}" servers -m command -a "$*"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    # If the user passed a playbook file or arbitrary ansible arguments
    if [ -f "${CMD}" ]; then
      exec "${ANSIBLE_PLAYBOOK}" "${CMD}" "$@"
    else
      echo "Unknown command: ${CMD}"
      usage
    fi
    ;;
esac
