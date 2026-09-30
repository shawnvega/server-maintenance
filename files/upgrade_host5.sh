#!/usr/bin/env bash
# =============================================================================
# upgrade_host5.sh - Native Host Maintenance for Raspberry Pi 5 (192.168.4.5)
# =============================================================================
# Executes complete standalone maintenance cycle outside Docker:
#   1. Pre-flight Btrfs scrub safety check
#   2. System load verification
#   3. rpi-clone SD backup (/dev/mmcblk0)
#   4. Systemd journal vacuum & cap
#   5. APT package updates (Debian/Pi OS)
#   6. Docker stacks pull, recreate, & prune (glances, immich-ml, semaphore)
#   7. Caddy reverse proxy validation & reload
#   8. Structured status record (/home/shawn/logs/upgrade_host5.status)
# =============================================================================

set -Eeuo pipefail

# Ensure script is executed as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or via sudo). Re-executing with sudo..."
    exec sudo bash "$0" "$@"
fi

# Concurrency lock to prevent overlapping runs (cron, CLI, Semaphore)
LOCK_FILE="/var/run/upgrade_host5.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Another instance of upgrade_host5.sh is already running. Exiting."
    exit 1
fi

# Configuration
USER_NAME="shawn"
USER_HOME="/home/${USER_NAME}"
LOG_DIR="${USER_HOME}/logs"
LOG_FILE="${LOG_DIR}/upgrade_host5.log"
STATUS_FILE="${LOG_DIR}/upgrade_host5.status"
BACKUP_DEVICE="/dev/mmcblk0"
LOAD_THRESHOLD=6.0
DOCKER_STACKS=("docker/glances" "docker/immich-ml" "docker/semaphore")

# Ensure logs directory exists
mkdir -p "${LOG_DIR}"
chown "${USER_NAME}:${USER_NAME}" "${LOG_DIR}"

# Redirect all stdout & stderr to log file while also echoing to console
exec > >(tee -a "${LOG_FILE}") 2>&1

START_TIME=$(date +%s)
CURRENT_STEP="Initialization"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Failure handler
on_error() {
    local exit_code=$1
    local failed_line=$2
    log "ERROR: Step failed at line ${failed_line}: ${CURRENT_STEP} (Exit Code: ${exit_code})"
    
    cat << EOF > "${STATUS_FILE}"
Last Run:       $(date '+%Y-%m-%d %H:%M:%S %Z')
Status:         FAILED
Failed Step:    ${CURRENT_STEP} (Line ${failed_line}, Exit code ${exit_code})
Log File:       ${LOG_FILE}
EOF
    chown "${USER_NAME}:${USER_NAME}" "${STATUS_FILE}" || true
    exit "${exit_code}"
}

trap 'on_error $? ${LINENO}' ERR

log "===================================================================="
log "Starting standalone maintenance on $(hostname) (192.168.4.5)"
log "===================================================================="

# -----------------------------------------------------------------------------
# Step 1: Pre-flight Btrfs Scrub Safety Check
# -----------------------------------------------------------------------------
CURRENT_STEP="Btrfs scrub safety check"
log "Checking for active Btrfs scrubs..."
btrfs_scrub_running=0
if command -v btrfs >/dev/null 2>&1; then
    while IFS= read -r mountpoint; do
        if [[ -n "$mountpoint" ]]; then
            if btrfs scrub status "$mountpoint" 2>&1 | grep -iq "is running"; then
                log "Active Btrfs scrub detected on mountpoint: ${mountpoint}"
                btrfs_scrub_running=1
            fi
        fi
    done < <(findmnt -t btrfs -n -o TARGET 2>/dev/null || true)
fi

if [[ $btrfs_scrub_running -eq 1 ]]; then
    log "WARNING: Btrfs scrub is currently in progress. Aborting upgrade to protect active scrub."
    cat << EOF > "${STATUS_FILE}"
Last Run:       $(date '+%Y-%m-%d %H:%M:%S %Z')
Status:         SKIPPED (Btrfs scrub active)
Details:        Maintenance deferred to protect background storage checksum scrub.
Log File:       ${LOG_FILE}
EOF
    chown "${USER_NAME}:${USER_NAME}" "${STATUS_FILE}" || true
    exit 0
fi
log "No active Btrfs scrubs found. Proceeding."

# -----------------------------------------------------------------------------
# Step 2: System Load Check
# -----------------------------------------------------------------------------
CURRENT_STEP="System load verification"
log "Checking system load average (threshold: ${LOAD_THRESHOLD})..."
retries=0
max_retries=30
while true; do
    one_min_load=$(awk '{print $1}' /proc/loadavg)
    if awk -v load="${one_min_load}" -v thresh="${LOAD_THRESHOLD}" 'BEGIN {exit !(load <= thresh)}'; then
        log "System load is ${one_min_load} (<= ${LOAD_THRESHOLD}). Proceeding."
        break
    fi
    retries=$((retries + 1))
    if [[ $retries -ge $max_retries ]]; then
        log "Load remains elevated (${one_min_load} > ${LOAD_THRESHOLD}) after $((max_retries * 20))s. Proceeding anyway."
        break
    fi
    log "Current load is ${one_min_load} (waiting 20s for drop... attempt ${retries}/${max_retries})"
    sleep 20
done

# -----------------------------------------------------------------------------
# Step 3: Backup (rpi-clone)
# -----------------------------------------------------------------------------
CURRENT_STEP="Pre-upgrade backup (rpi-clone)"
log "Running pre-upgrade SD clone backup to ${BACKUP_DEVICE}..."
if command -v rpi-clone >/dev/null 2>&1; then
    rpi-clone -u -v "${BACKUP_DEVICE}"
    log "rpi-clone backup completed successfully."
    backup_status="rpi-clone completed successfully"
else
    log "WARNING: rpi-clone command not found. Skipping backup step."
    backup_status="Skipped (rpi-clone not found)"
fi

# -----------------------------------------------------------------------------
# Step 4: Systemd Journal Management
# -----------------------------------------------------------------------------
CURRENT_STEP="Systemd journal vacuum"
log "Configuring journald max size and vacuuming old logs..."
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/maxsize.conf
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald || true
journalctl --vacuum-size=100M || true

# -----------------------------------------------------------------------------
# Step 5: OS Package Upgrades (APT)
# -----------------------------------------------------------------------------
CURRENT_STEP="OS package upgrades (APT)"
log "Updating package lists and upgrading Debian packages..."
dpkg --configure -a || true
apt-get clean
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update

# Count packages to be upgraded
upgradable_count=$(apt-get -s dist-upgrade | awk '/^[0-9]+ upgraded,/ {print $1}' || echo "0")
log "Upgrading ${upgradable_count} packages..."

apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get autoremove --purge -y
apt-get autoclean

# -----------------------------------------------------------------------------
# Step 6: Docker Stacks Maintenance
# -----------------------------------------------------------------------------
CURRENT_STEP="Docker compose stacks update"
log "Updating Docker compose stacks..."
for stack in "${DOCKER_STACKS[@]}"; do
    stack_dir="${USER_HOME}/${stack}"
    if [[ -d "${stack_dir}" ]] && ( [[ -f "${stack_dir}/docker-compose.yml" || -f "${stack_dir}/docker-compose.yaml" || -f "${stack_dir}/compose.yml" || -f "${stack_dir}/compose.yaml" ]] ); then
        log "Processing Docker stack: ${stack}"
        pushd "${stack_dir}" >/dev/null
        
        # Pull images with retry
        pull_success=0
        for attempt in 1 2 3; do
            if sudo -H -u "${USER_NAME}" docker compose pull; then
                pull_success=1
                break
            fi
            log "docker compose pull failed for ${stack} (attempt ${attempt}/3). Retrying in 5s..."
            sleep 5
        done
        
        if [[ $pull_success -eq 0 ]]; then
            log "WARNING: docker compose pull failed after 3 attempts. Proceeding with existing images."
        fi
        
        # Recreate stack
        sudo -H -u "${USER_NAME}" docker compose up -d --remove-orphans
        popd >/dev/null
    else
        log "Notice: Stack directory ${stack_dir} not found or contains no compose file. Skipping."
    fi
done

log "Pruning dangling and unused Docker images..."
docker image prune -a -f || true

# -----------------------------------------------------------------------------
# Step 7: Caddy Reverse Proxy
# -----------------------------------------------------------------------------
CURRENT_STEP="Caddy reverse proxy validation and reload"
log "Validating and reloading Caddy reverse proxy..."
if [[ -f /etc/caddy/Caddyfile ]] && command -v caddy >/dev/null 2>&1; then
    caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
    systemctl reload-or-restart caddy
    caddy_status="Reloaded (active)"
    log "Caddy reloaded successfully."
else
    caddy_status="Skipped (not configured)"
    log "Caddy not configured or not installed."
fi

# -----------------------------------------------------------------------------
# Step 8: Safe Automated Reboot Evaluation
# -----------------------------------------------------------------------------
CURRENT_STEP="Safe automated reboot evaluation"
reboot_required=0
reboot_blockers=()

if [[ -f /var/run/reboot-required ]]; then
    reboot_required=1
    log "Reboot is required by OS packages. Evaluating safety conditions..."

    # 1. Check for active Btrfs operations (scrub, balance, replace)
    if command -v btrfs >/dev/null 2>&1; then
        while IFS= read -r mountpoint; do
            if [[ -n "$mountpoint" ]]; then
                # Scrub
                if btrfs scrub status "$mountpoint" 2>&1 | grep -iqE "is running|status: running"; then
                    reboot_blockers+=("Active Btrfs scrub on ${mountpoint}")
                fi
                # Balance
                balance_out=$(btrfs balance status "$mountpoint" 2>&1 || true)
                if echo "$balance_out" | grep -iqE "is running|balance on" && ! echo "$balance_out" | grep -iqE "not in progress|no balance running|abort"; then
                    reboot_blockers+=("Active Btrfs balance on ${mountpoint}")
                fi
                # Replace
                replace_out=$(btrfs replace status "$mountpoint" 2>&1 || true)
                if echo "$replace_out" | grep -iqE "started|running" && ! echo "$replace_out" | grep -iqE "never started|finished|canceled"; then
                    reboot_blockers+=("Active Btrfs replace on ${mountpoint}")
                fi
            fi
        done < <(findmnt -t btrfs -n -o TARGET 2>/dev/null || true)
    fi

    # 2. Check for active backup or file synchronization processes
    for proc in rpi-clone rsync restic; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            pids=$(pgrep -x "$proc" | tr '\n' ' ')
            reboot_blockers+=("Active backup process '${proc}' (PID: ${pids})")
        fi
    done

    # 3. Check for active interactive SSH user sessions
    if who 2>/dev/null | grep -q 'pts/'; then
        pts_session=$(who | grep 'pts/' | head -n 1)
        reboot_blockers+=("Active interactive user session: ${pts_session}")
    fi

    # 4. Check system load (< 4.0)
    current_reboot_load=$(awk '{print $1}' /proc/loadavg)
    if ! awk -v load="${current_reboot_load}" -v thresh="4.0" 'BEGIN {exit !(load < thresh)}'; then
        reboot_blockers+=("System load ${current_reboot_load} >= 4.0")
    fi
fi

if [[ $reboot_required -eq 1 ]]; then
    if [[ ${#reboot_blockers[@]} -gt 0 ]]; then
        blockers_str=$(IFS='; '; echo "${reboot_blockers[*]}")
        reboot_summary="DEFERRED (Blocked by: ${blockers_str})"
        reboot_action="defer"
        log "WARNING: System reboot is required but DEFERRED due to active operations:"
        for b in "${reboot_blockers[@]}"; do
            log "  - ${b}"
        done
    else
        reboot_summary="REBOOTING NOW (Safety checks passed: Btrfs clean, backups clean, load ${current_reboot_load} < 4.0)"
        reboot_action="reboot"
        log "NOTICE: Reboot is required and all safety checks passed. System will reboot in 10s."
    fi
else
    reboot_summary="No (System is up to date)"
    reboot_action="none"
fi

# -----------------------------------------------------------------------------
# Step 9: Status Record & Metrics Generation
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
DURATION_FMT="$(( DURATION / 60 ))m $(( DURATION % 60 ))s"

log "Writing status record to ${STATUS_FILE}..."
cat << EOF > "${STATUS_FILE}"
Last Run:       $(date '+%Y-%m-%d %H:%M:%S %Z')
Status:         SUCCESS
Duration:       ${DURATION_FMT}
Backup:         ${backup_status}
OS Packages:    ${upgradable_count} packages upgraded
Docker Stacks:  glances, immich-ml, semaphore updated
Caddy:          ${caddy_status}
Reboot Needed:  ${reboot_summary}
Log File:       ${LOG_FILE}
EOF

chown "${USER_NAME}:${USER_NAME}" "${STATUS_FILE}"

log "===================================================================="
log "Maintenance completed successfully in ${DURATION_FMT}!"
log "Status summary written to: ${STATUS_FILE}"
log "===================================================================="

if [[ "${reboot_action}" == "reboot" ]]; then
    log "Scheduling system reboot in 10 seconds..."
    # Detach reboot so script exits cleanly, releases lock, and flushes output
    ( sleep 10 && systemctl reboot ) >/dev/null 2>&1 &
fi
