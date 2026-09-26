#!/usr/bin/env bash
# ==============================================================================
# upgrade_mac.sh - Automated Local macOS Maintenance & Upgrade Pipeline
# ==============================================================================
# Manages system, package manager, and application updates for macOS:
#   - Homebrew formulae & casks (with greedy auto-update support)
#   - Global Node.js / npm packages
#   - GitHub CLI extensions
#   - Mac App Store applications (via `mas` CLI)
#   - Developer tooling (pipx, rustup if installed)
#   - macOS software updates (via `softwareupdate`)
#   - Homebrew cache cleanup & orphaned dependency removal
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Color & Formatting Setup
# ------------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[0;32m'
  BLUE=$'\033[0;34m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  CYAN=$'\033[0;36m'
  MAGENTA=$'\033[0;35m'
  RESET=$'\033[0m'
else
  BOLD=""
  DIM=""
  GREEN=""
  BLUE=""
  YELLOW=""
  RED=""
  CYAN=""
  MAGENTA=""
  RESET=""
fi

log_info() {
  printf "${BLUE}${BOLD}[INFO]${RESET} %s\n" "$*"
}

log_step() {
  printf "\n${CYAN}${BOLD}==>${RESET} ${BOLD}%s${RESET}\n" "$*"
}

log_success() {
  printf "${GREEN}${BOLD}[OK]${RESET} %s\n" "$*"
}

log_warn() {
  printf "${YELLOW}${BOLD}[WARN]${RESET} %s\n" "$*"
}

log_error() {
  printf "${RED}${BOLD}[ERROR]${RESET} %s\n" "$*"
}

# ------------------------------------------------------------------------------
# Prevent Running Directly as Root
# ------------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  log_error "Do not run this script with sudo or as root."
  log_error "Homebrew disallows root execution. Run as your standard user."
  log_error "The script will request sudo authorization only when required (e.g., macOS system updates)."
  exit 1
fi

# ------------------------------------------------------------------------------
# Script Configuration & Defaults
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_START_TIME=$(date +%s)
UPGRADE_ALL=false
DRY_RUN=false
GREEDY_CASK=true
SKIP_BREW=false
SKIP_CASKS=false
SKIP_NPM=false
SKIP_GH=false
SKIP_MAS=false
SKIP_MACOS=false
SKIP_CLEANUP=false
MACOS_INSTALL=false

# Track status of stages for final summary
STATUS_BREW_FORMULAE="Skipped"
STATUS_BREW_CASKS="Skipped"
STATUS_NPM="Skipped"
STATUS_GH="Skipped"
STATUS_MAS="Skipped"
STATUS_MACOS="Skipped"
STATUS_CLEANUP="Skipped"

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}Usage:${RESET} $0 [OPTIONS]

Automated maintenance and upgrade script for macOS development machines.

${BOLD}Options:${RESET}
  -a, --all             Run full upgrade pipeline (including installing macOS system updates)
  -n, --dry-run         Check for outdated packages without downloading or applying updates
  --no-greedy           Do not use --greedy when upgrading Homebrew casks
  --macos-install       Automatically install recommended macOS system updates (requires sudo)
  --skip-brew           Skip all Homebrew operations (formulae and casks)
  --skip-casks          Skip Homebrew casks (formulae will still be updated)
  --skip-npm            Skip global npm packages update
  --skip-gh             Skip GitHub CLI extensions update
  --skip-mas            Skip Mac App Store (mas) update
  --skip-macos          Skip macOS softwareupdate check
  --skip-cleanup        Skip Homebrew cache cleanup and autoremove
  -h, --help            Show this help message

${BOLD}Examples:${RESET}
  $0                    # Standard upgrade (Brew formulae + casks, npm, gh, check macOS)
  $0 -n                 # Dry-run: view pending updates across all package managers
  $0 --all              # Full upgrade including unattended macOS system updates
  $0 --no-greedy        # Upgrade casks without greedy flag (skip auto-updating apps)
  $0 --skip-macos       # Upgrade package managers only, skipping Apple system update check
EOF
  exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -a|--all)
      UPGRADE_ALL=true
      MACOS_INSTALL=true
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --greedy)
      GREEDY_CASK=true
      shift
      ;;
    --no-greedy)
      GREEDY_CASK=false
      shift
      ;;
    --macos-install)
      MACOS_INSTALL=true
      shift
      ;;
    --skip-brew)
      SKIP_BREW=true
      shift
      ;;
    --skip-cask|--skip-casks)
      SKIP_CASKS=true
      shift
      ;;
    --skip-npm)
      SKIP_NPM=true
      shift
      ;;
    --skip-gh)
      SKIP_GH=true
      shift
      ;;
    --skip-mas)
      SKIP_MAS=true
      shift
      ;;
    --skip-macos)
      SKIP_MACOS=true
      shift
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=true
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
log_step "Pre-flight Environment Check"

# Verify OS is macOS
if [ "$(uname -s)" != "Darwin" ]; then
  log_error "This script is designed for macOS (Darwin). Detected: $(uname -s)"
  exit 1
fi

SW_VERS=$(sw_vers -productVersion 2>/dev/null || echo "Unknown")
SW_NAME=$(sw_vers -productName 2>/dev/null || echo "macOS")
SW_BUILD=$(sw_vers -buildVersion 2>/dev/null || echo "")
log_info "Host Operating System: ${SW_NAME} ${SW_VERS} (${SW_BUILD})"

# Ensure Homebrew path is loaded in environment
if ! command -v brew >/dev/null 2>&1; then
  if [ -x "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x "/usr/local/bin/brew" ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# Battery / Power Warning
if command -v pmset >/dev/null 2>&1; then
  BATT_INFO=$(pmset -g batt 2>/dev/null || true)
  if echo "${BATT_INFO}" | grep -q "Battery Power"; then
    BATT_PCT=$(echo "${BATT_INFO}" | grep -oE '[0-9]+%' | head -n1 || echo "")
    log_warn "System is currently running on Battery Power (${BATT_PCT:-unknown})."
    log_warn "Consider connecting AC power during extensive compiles or large updates."
  else
    log_info "Power: AC connected"
  fi
fi

if [ "${DRY_RUN}" = true ]; then
  log_warn "Running in DRY-RUN mode. No changes will be applied."
fi

# ------------------------------------------------------------------------------
# Stage 1: Homebrew Formulae
# ------------------------------------------------------------------------------
if [ "${SKIP_BREW}" = false ]; then
  if command -v brew >/dev/null 2>&1; then
    log_step "Homebrew Formulae"
    log_info "Updating Homebrew index (brew update)..."
    
    if [ "${DRY_RUN}" = false ]; then
      brew update || log_warn "brew update returned non-zero exit code, continuing..."
    else
      log_info "[DRY-RUN] Skipping brew update"
    fi

    # Suppress redundant automatic updates in subsequent queries
    export HOMEBREW_NO_AUTO_UPDATE=1

    log_info "Checking outdated formulae..."
    OUTDATED_FORMULAE=$(brew outdated --formula 2>/dev/null || true)

    if [ -z "${OUTDATED_FORMULAE//[[:space:]]/}" ]; then
      log_success "All Homebrew formulae are up-to-date."
      STATUS_BREW_FORMULAE="Up-to-date"
    else
      COUNT_FORMULAE=$(echo "${OUTDATED_FORMULAE}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
      log_info "Found ${COUNT_FORMULAE} outdated formula(e):"
      printf "${DIM}%s${RESET}\n" "${OUTDATED_FORMULAE}"
      
      if [ "${DRY_RUN}" = false ]; then
        log_info "Upgrading formulae (brew upgrade --formula)..."
        if brew upgrade --formula; then
          log_success "Homebrew formulae upgraded successfully."
          STATUS_BREW_FORMULAE="Upgraded (${COUNT_FORMULAE})"
        else
          log_warn "Some formulae encountered warnings or errors during upgrade."
          STATUS_BREW_FORMULAE="Warning / Partial"
        fi
      else
        STATUS_BREW_FORMULAE="Outdated (${COUNT_FORMULAE} pending)"
      fi
    fi
  else
    log_warn "Homebrew not found. Install from https://brew.sh"
    STATUS_BREW_FORMULAE="Not Installed"
  fi
fi

# ------------------------------------------------------------------------------
# Stage 2: Homebrew Casks
# ------------------------------------------------------------------------------
if [ "${SKIP_BREW}" = false ] && [ "${SKIP_CASKS}" = false ]; then
  if command -v brew >/dev/null 2>&1; then
    log_step "Homebrew Casks (GUI Applications)"
    CASK_FLAGS=("--cask")
    if [ "${GREEDY_CASK}" = true ]; then
      CASK_FLAGS+=("--greedy")
      log_info "Checking outdated casks (including auto-updating apps with --greedy)..."
    else
      log_info "Checking outdated casks..."
    fi

    OUTDATED_CASKS=$(brew outdated "${CASK_FLAGS[@]}" 2>/dev/null || true)

    if [ -z "${OUTDATED_CASKS//[[:space:]]/}" ]; then
      log_success "All Homebrew casks are up-to-date."
      STATUS_BREW_CASKS="Up-to-date"
    else
      COUNT_CASKS=$(echo "${OUTDATED_CASKS}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
      log_info "Found ${COUNT_CASKS} outdated cask(s):"
      printf "${DIM}%s${RESET}\n" "${OUTDATED_CASKS}"

      if [ "${DRY_RUN}" = false ]; then
        log_info "Upgrading casks (brew upgrade ${CASK_FLAGS[*]})..."
        if brew upgrade "${CASK_FLAGS[@]}"; then
          log_success "Homebrew casks upgraded successfully."
          STATUS_BREW_CASKS="Upgraded (${COUNT_CASKS})"
        else
          log_warn "Some casks encountered errors during upgrade (e.g. running app lock)."
          STATUS_BREW_CASKS="Warning / Partial"
        fi
      else
        STATUS_BREW_CASKS="Outdated (${COUNT_CASKS} pending)"
      fi
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Stage 3: Global Node.js / NPM Packages
# ------------------------------------------------------------------------------
if [ "${SKIP_NPM}" = false ]; then
  if command -v npm >/dev/null 2>&1; then
    log_step "Global Node.js / NPM Packages"
    log_info "Checking outdated global packages..."
    NPM_OUTDATED=$(npm outdated -g 2>/dev/null || true)

    if [ -z "${NPM_OUTDATED//[[:space:]]/}" ]; then
      log_success "All global npm packages are up-to-date."
      STATUS_NPM="Up-to-date"
    else
      log_info "Outdated global npm packages:"
      printf "${DIM}%s${RESET}\n" "${NPM_OUTDATED}"

      if [ "${DRY_RUN}" = false ]; then
        log_info "Updating global npm packages (npm update -g)..."
        if npm update -g; then
          log_success "Global npm packages updated successfully."
          STATUS_NPM="Upgraded"
        else
          log_warn "npm update -g encountered warnings or permissions issue."
          STATUS_NPM="Warning / Partial"
        fi
      else
        STATUS_NPM="Outdated (pending)"
      fi
    fi
  else
    STATUS_NPM="Not Installed"
  fi
fi

# ------------------------------------------------------------------------------
# Stage 4: GitHub CLI Extensions
# ------------------------------------------------------------------------------
if [ "${SKIP_GH}" = false ]; then
  if command -v gh >/dev/null 2>&1; then
    log_step "GitHub CLI Extensions"
    GH_EXTS=$(gh extension list 2>/dev/null || true)

    if [ -z "${GH_EXTS}" ]; then
      log_info "No GitHub CLI extensions installed."
      STATUS_GH="None Installed"
    else
      log_info "Installed GitHub CLI extensions:"
      printf "${DIM}%s${RESET}\n" "${GH_EXTS}"

      if [ "${DRY_RUN}" = false ]; then
        log_info "Upgrading GitHub CLI extensions (gh extension upgrade --all)..."
        if gh extension upgrade --all; then
          log_success "GitHub CLI extensions upgraded successfully."
          STATUS_GH="Upgraded"
        else
          log_warn "Failed to upgrade some GitHub CLI extensions."
          STATUS_GH="Warning"
        fi
      else
        STATUS_GH="Check only"
      fi
    fi
  else
    STATUS_GH="Not Installed"
  fi
fi

# ------------------------------------------------------------------------------
# Stage 5: Mac App Store (mas CLI)
# ------------------------------------------------------------------------------
if [ "${SKIP_MAS}" = false ]; then
  log_step "Mac App Store Applications (mas)"
  if command -v mas >/dev/null 2>&1; then
    log_info "Checking outdated Mac App Store applications..."
    MAS_OUTDATED=$(mas outdated 2>/dev/null || true)

    if [ -z "${MAS_OUTDATED//[[:space:]]/}" ]; then
      log_success "All Mac App Store apps are up-to-date."
      STATUS_MAS="Up-to-date"
    else
      COUNT_MAS=$(echo "${MAS_OUTDATED}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
      log_info "Found ${COUNT_MAS} outdated Mac App Store app(s):"
      printf "${DIM}%s${RESET}\n" "${MAS_OUTDATED}"

      if [ "${DRY_RUN}" = false ]; then
        log_info "Upgrading Mac App Store apps (mas upgrade)..."
        if mas upgrade; then
          log_success "Mac App Store apps upgraded successfully."
          STATUS_MAS="Upgraded (${COUNT_MAS})"
        else
          log_warn "mas upgrade encountered an error."
          STATUS_MAS="Warning / Partial"
        fi
      else
        STATUS_MAS="Outdated (${COUNT_MAS} pending)"
      fi
    fi
  else
    log_info "mas CLI not installed. (Optional: install with 'brew install mas' to manage App Store updates)"
    STATUS_MAS="Not Installed"
  fi
fi

# ------------------------------------------------------------------------------
# Stage 6: Additional Developer Tooling (pipx, rustup)
# ------------------------------------------------------------------------------
if command -v pipx >/dev/null 2>&1; then
  log_step "Python Tools (pipx)"
  if [ "${DRY_RUN}" = false ]; then
    pipx upgrade-all || log_warn "pipx upgrade-all returned non-zero"
  else
    log_info "[DRY-RUN] pipx upgrade-all skipped"
  fi
fi

if command -v rustup >/dev/null 2>&1; then
  log_step "Rust Toolchain (rustup)"
  if [ "${DRY_RUN}" = false ]; then
    rustup update || log_warn "rustup update returned non-zero"
  else
    log_info "[DRY-RUN] rustup update skipped"
  fi
fi

# ------------------------------------------------------------------------------
# Stage 7: macOS System Software Updates
# ------------------------------------------------------------------------------
if [ "${SKIP_MACOS}" = false ]; then
  log_step "macOS System Software Updates"
  log_info "Scanning for Apple system & security updates (softwareupdate -l)..."
  
  # Run softwareupdate scan (capturing stderr and stdout)
  SU_OUTPUT=$(softwareupdate -l 2>&1 || true)

  if echo "${SU_OUTPUT}" | grep -iq "No new software available"; then
    log_success "macOS system software is up-to-date."
    STATUS_MACOS="Up-to-date"
  elif echo "${SU_OUTPUT}" | grep -iqE "Title:|software update found"; then
    log_info "Pending macOS system update(s) detected:"
    printf "${YELLOW}%s${RESET}\n" "$(echo "${SU_OUTPUT}" | grep -E "^\* Label:|Title:|Software Update Found" || true)"

    if echo "${SU_OUTPUT}" | grep -iq "Action: restart"; then
      log_warn "One or more pending updates indicate 'Action: restart' (a system restart will be required)."
    fi

    SHOULD_INSTALL=false
    if [ "${MACOS_INSTALL}" = true ]; then
      SHOULD_INSTALL=true
    elif [ -t 0 ] && [ "${DRY_RUN}" = false ]; then
      # Interactive terminal prompt
      printf "\n${BOLD}Install recommended macOS system updates now? [y/N]: ${RESET}"
      RESPONSE=""
      read -r RESPONSE || true
      case "${RESPONSE}" in
        [yY]|[yY][eE][sS])
          SHOULD_INSTALL=true
          ;;
        *)
          SHOULD_INSTALL=false
          ;;
      esac
    fi

    if [ "${SHOULD_INSTALL}" = true ] && [ "${DRY_RUN}" = false ]; then
      log_info "Installing recommended macOS updates (sudo softwareupdate -ir --verbose)..."
      log_info "Enter your local Mac administrator/sudo password (or use Touch ID if prompted):"
      if sudo /usr/sbin/softwareupdate -ir --verbose; then
        log_success "macOS system updates installed successfully."
        STATUS_MACOS="Installed"
      else
        log_error "softwareupdate installation failed or was cancelled."
        STATUS_MACOS="Failed"
      fi
    else
      STATUS_MACOS="Updates Available (Pending)"
      log_info "To install available system updates manually, run: sudo softwareupdate -ir"
    fi
  else
    log_info "softwareupdate scan completed."
    STATUS_MACOS="Completed"
  fi
fi

# ------------------------------------------------------------------------------
# Stage 8: Homebrew Cleanup & Disk Space Optimization
# ------------------------------------------------------------------------------
if [ "${SKIP_BREW}" = false ] && [ "${SKIP_CLEANUP}" = false ]; then
  if command -v brew >/dev/null 2>&1 && [ "${DRY_RUN}" = false ]; then
    log_step "Homebrew Cleanup & Diagnostics"
    log_info "Pruning stale lockfiles, cache, and outdated downloads (brew cleanup)..."
    brew cleanup --prune=all -s || true

    log_info "Removing unneeded orphaned dependencies (brew autoremove)..."
    brew autoremove || true

    log_info "Running Homebrew diagnostic check (brew doctor)..."
    DOCTOR_OUTPUT=$(brew doctor 2>&1 || true)
    if echo "${DOCTOR_OUTPUT}" | grep -iq "Your system is ready to brew"; then
      log_success "Homebrew doctor: Your system is ready to brew."
      STATUS_CLEANUP="Cleaned & Healthy"
    else
      DOCTOR_WARNINGS=$(echo "${DOCTOR_OUTPUT}" | grep -c "Warning:" || echo "1")
      log_warn "Homebrew doctor reported ${DOCTOR_WARNINGS} advisory warning(s)."
      STATUS_CLEANUP="Cleaned (Doctor Warnings)"
    fi
  elif [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Skipping Homebrew cleanup and doctor diagnostics."
    STATUS_CLEANUP="Skipped (Dry Run)"
  fi
fi

# ------------------------------------------------------------------------------
# Final Execution Summary
# ------------------------------------------------------------------------------
SCRIPT_END_TIME=$(date +%s)
TOTAL_DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
MINUTES=$((TOTAL_DURATION / 60))
SECONDS=$((TOTAL_DURATION % 60))

printf "\n"
printf "${BOLD}================================================================${RESET}\n"
printf "${BOLD}                 macOS Upgrade Pipeline Summary                 ${RESET}\n"
printf "${BOLD}================================================================${RESET}\n"
printf "%-32s : %s\n" "Homebrew Formulae" "${STATUS_BREW_FORMULAE}"
printf "%-32s : %s\n" "Homebrew Casks (GUI)" "${STATUS_BREW_CASKS}"
printf "%-32s : %s\n" "Global NPM Packages" "${STATUS_NPM}"
printf "%-32s : %s\n" "GitHub CLI Extensions" "${STATUS_GH}"
printf "%-32s : %s\n" "Mac App Store (mas)" "${STATUS_MAS}"
printf "%-32s : %s\n" "macOS System Software" "${STATUS_MACOS}"
printf "%-32s : %s\n" "Disk Cleanup & Diagnostics" "${STATUS_CLEANUP}"
printf "${BOLD}----------------------------------------------------------------${RESET}\n"
printf "%-32s : %dm %ds\n" "Total Execution Time" "${MINUTES}" "${SECONDS}"
printf "${BOLD}================================================================${RESET}\n\n"

log_success "Local macOS maintenance pipeline complete!"
