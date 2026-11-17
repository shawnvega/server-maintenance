#!/usr/bin/env bash
#
# setup_hermes_pat.sh - Configure and verify GitHub Personal Access Token (PAT)
# for Hermes Agent on Fedora (192.168.4.19).
#
# Supports both Fine-grained PATs (recommended) and Classic PATs.
# Configures persistent gh credentials, git credential helper, and container environment.
#

set -euo pipefail

TARGET_HOST="${HERMES_HOST:-192.168.4.19}"
SSH_USER="${HERMES_SSH_USER:-shawn}"
CONTAINER="${HERMES_CONTAINER:-hermes-gateway}"
TOKEN="${GITHUB_PAT:-${GITHUB_TOKEN:-}}"
GIT_USER=""
GIT_EMAIL=""
CHECK_STATUS_ONLY=false
LOGOUT_MODE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Configure and verify GitHub Personal Access Token (PAT) for Hermes on ${TARGET_HOST}.

Options:
  --token <token>      GitHub PAT (fine-grained 'github_pat_...' or classic 'ghp_...')
  --host <ip>          Target host running Hermes (default: ${TARGET_HOST})
  --user <user>        SSH user on target host (default: ${SSH_USER})
  --container <name>   Hermes container name (default: ${CONTAINER})
  --git-user <name>    Git author name (default: GitHub profile name)
  --git-email <email>  Git author email (default: <username>@users.noreply.github.com)
  --status             Check current GitHub authentication status on Hermes without modifying
  --logout             Log out and clear GitHub credentials from Hermes
  -h, --help           Show this help message

If --token is omitted, you will be prompted securely without terminal echo.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --host)
      TARGET_HOST="$2"
      shift 2
      ;;
    --user)
      SSH_USER="$2"
      shift 2
      ;;
    --container)
      CONTAINER="$2"
      shift 2
      ;;
    --git-user)
      GIT_USER="$2"
      shift 2
      ;;
    --git-email)
      GIT_EMAIL="$2"
      shift 2
      ;;
    --status)
      CHECK_STATUS_ONLY=true
      shift
      ;;
    --logout)
      LOGOUT_MODE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# Ensure curl and jq / python3 are available locally
has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# --- Status Only Mode ---
if [[ "${CHECK_STATUS_ONLY}" == true ]]; then
  echo "Checking GitHub authentication status for Hermes on ${TARGET_HOST} (${CONTAINER})..."
  ssh "${SSH_USER}@${TARGET_HOST}" \
    "docker exec -u hermes ${CONTAINER} gh auth status" || true
  exit 0
fi

# --- Logout Mode ---
if [[ "${LOGOUT_MODE}" == true ]]; then
  echo "Logging out of GitHub on Hermes (${TARGET_HOST})..."
  ssh "${SSH_USER}@${TARGET_HOST}" "
    docker exec -u hermes ${CONTAINER} gh auth logout --hostname github.com || true
    if [ -f /home/shawn/docker/hermes/.env ]; then
      sed -i '/^GITHUB_TOKEN=/d' /home/shawn/docker/hermes/.env
      sed -i '/^GH_TOKEN=/d' /home/shawn/docker/hermes/.env
    fi
  "
  echo "✓ GitHub credentials cleared from Hermes."
  exit 0
fi

# --- Prompt for Token if not provided ---
if [[ -z "${TOKEN}" ]]; then
  echo "Configuring GitHub PAT for Hermes on ${TARGET_HOST}"
  echo "Tip: A Fine-grained Personal Access Token with repository 'Contents' & 'Pull requests'"
  echo "     read/write permissions is strongly recommended."
  echo ""
  read -r -s -p "Enter GitHub Personal Access Token: " TOKEN
  echo ""
fi

# Trim whitespace
TOKEN="$(echo -e "${TOKEN}" | tr -d '[:space:]')"

if [[ -z "${TOKEN}" ]]; then
  echo "Error: Token cannot be empty." >&2
  exit 1
fi

# Determine token type
TOKEN_TYPE="Unknown PAT"
if [[ "${TOKEN}" =~ ^github_pat_ ]]; then
  TOKEN_TYPE="Fine-grained Personal Access Token"
elif [[ "${TOKEN}" =~ ^ghp_ ]]; then
  TOKEN_TYPE="Classic Personal Access Token"
fi

echo "==> Verifying token with GitHub API..."
API_RESPONSE=$(curl -sS -w "\n%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/user)

HTTP_CODE=$(echo "${API_RESPONSE}" | tail -n1)
JSON_BODY=$(echo "${API_RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Error: GitHub rejected the token (HTTP ${HTTP_CODE})." >&2
  if echo "${JSON_BODY}" | grep -q "message"; then
    echo "GitHub message: $(echo "${JSON_BODY}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('message', ''))" 2>/dev/null || true)" >&2
  fi
  exit 1
fi

GH_LOGIN=$(echo "${JSON_BODY}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('login', ''))")
GH_NAME=$(echo "${JSON_BODY}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name') or '')")

echo "✓ GitHub API authentication successful!"
echo "  Account:   ${GH_LOGIN} $([[ -n "${GH_NAME}" ]] && echo "(${GH_NAME})")"
echo "  Token Type: ${TOKEN_TYPE}"
echo ""

# Default Git committer metadata
if [[ -z "${GIT_USER}" ]]; then
  GIT_USER="${GH_NAME:-${GH_LOGIN}} (Hermes Agent)"
fi
if [[ -z "${GIT_EMAIL}" ]]; then
  GIT_EMAIL="${GH_LOGIN}@users.noreply.github.com"
fi

echo "==> Checking Hermes container status on ${TARGET_HOST}..."
CONTAINER_STATE=$(ssh "${SSH_USER}@${TARGET_HOST}" "docker inspect -f '{{.State.Status}}' ${CONTAINER}" 2>/dev/null || echo "not_found")

if [[ "${CONTAINER_STATE}" != "running" ]]; then
  echo "Error: Container '${CONTAINER}' is not running on ${TARGET_HOST} (state: ${CONTAINER_STATE})." >&2
  echo "Please start the Hermes stack first with: ./run.sh hermes" >&2
  exit 1
fi

echo "==> Configuring gh CLI & credentials inside ${CONTAINER}..."
# 1. Login to gh CLI via stdin
printf "%s\n" "${TOKEN}" | ssh "${SSH_USER}@${TARGET_HOST}" \
  "docker exec -i -u hermes ${CONTAINER} gh auth login --with-token --git-protocol https"

# 2. Configure git protocol to https
ssh "${SSH_USER}@${TARGET_HOST}" \
  "docker exec -u hermes ${CONTAINER} gh config set git_protocol https"

# 3. Setup git credential helper so `git` commands use the gh token
ssh "${SSH_USER}@${TARGET_HOST}" \
  "docker exec -u hermes ${CONTAINER} gh auth setup-git"

# 4. Configure git identity if not already configured
ssh "${SSH_USER}@${TARGET_HOST}" "
  docker exec -u hermes ${CONTAINER} bash -c '
    if [ -z \"\$(git config --global user.name)\" ]; then
      git config --global user.name \"${GIT_USER}\"
    fi
    if [ -z \"\$(git config --global user.email)\" ]; then
      git config --global user.email \"${GIT_EMAIL}\"
    fi
  '
"

# 5. Persist GITHUB_TOKEN & GH_TOKEN in /home/shawn/docker/hermes/.env for subshells / processes
echo "==> Updating environment variables in /home/shawn/docker/hermes/.env..."
ssh "${SSH_USER}@${TARGET_HOST}" "
  ENV_FILE=\"/home/shawn/docker/hermes/.env\"
  if [ -f \"\${ENV_FILE}\" ]; then
    grep -v '^GITHUB_TOKEN=' \"\${ENV_FILE}\" | grep -v '^GH_TOKEN=' > \"\${ENV_FILE}.tmp\" || true
    echo \"GITHUB_TOKEN=${TOKEN}\" >> \"\${ENV_FILE}.tmp\"
    echo \"GH_TOKEN=${TOKEN}\" >> \"\${ENV_FILE}.tmp\"
    mv \"\${ENV_FILE}.tmp\" \"\${ENV_FILE}\"
    chmod 0600 \"\${ENV_FILE}\"
  fi
"

echo ""
echo "==> Verifying authentication status from within Hermes..."
ssh "${SSH_USER}@${TARGET_HOST}" "docker exec -u hermes ${CONTAINER} gh auth status"

echo ""
echo "======================================================================"
echo "✓ GitHub PAT successfully installed and verified for Hermes on ${TARGET_HOST}!"
echo "  - gh CLI: Authenticated as ${GH_LOGIN}"
echo "  - Git Protocol: HTTPS with gh credential helper"
echo "  - Git Author:   ${GIT_USER} <${GIT_EMAIL}>"
echo "  - Persistence:  Credentials saved to /home/shawn/docker/hermes/data"
echo "======================================================================"
