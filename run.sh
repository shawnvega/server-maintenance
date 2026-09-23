#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

# Ensure venv exists
if [ ! -d "${VENV_DIR}" ]; then
  echo "Virtual environment not found at ${VENV_DIR}."
  echo "Creating virtual environment and installing dependencies..."
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
  echo "  upgrade              Run full upgrade pipeline (backup, OS, and Docker)"
  echo "  playbook <file.yml>  Run a custom playbook"
  echo "  raw <command>        Run an ad-hoc shell command on all servers"
  echo ""
  echo "Examples:"
  echo "  $0 ping"
  echo "  $0 backup -K                       # Run backup only"
  echo "  $0 upgrade -K                      # Full pipeline: backup -> OS -> Docker"
  echo "  $0 upgrade --tags os -K            # OS package upgrades only"
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
