#!/usr/bin/env bash
#
# hermes_shell.sh - Open an interactive terminal inside the Hermes Docker container on 192.168.4.19.
#

set -euo pipefail

HOST="${HERMES_HOST:-192.168.4.19}"
SSH_USER="${HERMES_SSH_USER:-shawn}"
CONTAINER="${HERMES_CONTAINER:-hermes-gateway}"
CONTAINER_USER="${HERMES_CONTAINER_USER:-hermes}"
SHELL_BIN="${HERMES_SHELL:-bash}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- command...]

Open an interactive terminal inside the Hermes Docker container on ${HOST}.

Options:
  --desktop        Attach to hermes-desktop instead of hermes-gateway
  --root           Run inside the container as root instead of ${CONTAINER_USER}
  -h, --help       Show this help message

Environment overrides:
  HERMES_HOST            Target host (default: ${HOST})
  HERMES_SSH_USER        SSH user (default: ${SSH_USER})
  HERMES_CONTAINER       Container name (default: ${CONTAINER})
  HERMES_CONTAINER_USER  Container user (default: ${CONTAINER_USER})
  HERMES_SHELL           Shell to launch (default: ${SHELL_BIN})
EOF
}

CMD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --desktop)
      CONTAINER="hermes-desktop"
      shift
      ;;
    --root)
      CONTAINER_USER="root"
      shift
      ;;
    --)
      shift
      CMD_ARGS=("$@")
      break
      ;;
    *)
      CMD_ARGS=("$@")
      break
      ;;
  esac
done

if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
  CMD_ARGS=("${SHELL_BIN}")
fi

REMOTE_CMD="docker exec -it -u $(printf '%q' "${CONTAINER_USER}") $(printf '%q' "${CONTAINER}")"
for arg in "${CMD_ARGS[@]}"; do
  REMOTE_CMD+=" $(printf '%q' "${arg}")"
done

exec ssh -t "${SSH_USER}@${HOST}" "${REMOTE_CMD}"
