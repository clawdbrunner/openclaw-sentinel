#!/bin/bash
# OpenClaw Sentinel Upgrade
# Manages OpenClaw version updates with backup, verification, and rollback

set -euo pipefail

# Ensure PATH includes Homebrew and user bins
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH"

# =============================================================================
# CONFIGURATION
# =============================================================================

SENTINEL_DIR="${SENTINEL_DIR:-$HOME/.openclaw/sentinel}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.openclaw/sentinel.conf}"
OPENCLAW_DIR="$HOME/.openclaw"

# Default values (can be overridden in sentinel.conf)
BACKUP_BEFORE_UPGRADE=true
MAX_LOCK_AGE=1800
UPGRADE_ENABLED=false
UPGRADE_SCHEDULE="weekly"
UPGRADE_AUTO_APPLY=false

# Load user configuration if exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Ensure directories exist
LOG_DIR="$SENTINEL_DIR/logs"
mkdir -p "$LOG_DIR"
UPGRADE_LOG="$LOG_DIR/upgrade.log"
LOCKFILE="$SENTINEL_DIR/upgrade.lock"
HISTORY_FILE="$SENTINEL_DIR/upgrade-history.json"

# Detect which CLI to use (openclaw preferred, clawdbot as fallback)
if command -v openclaw &> /dev/null; then
    OPENCLAW_CMD="openclaw"
elif command -v clawdbot &> /dev/null; then
    OPENCLAW_CMD="clawdbot"
else
    OPENCLAW_CMD=""
fi

# Detect package manager
PACKAGE_MANAGER=""
if npm list -g openclaw &> /dev/null 2>&1; then
    PACKAGE_MANAGER="npm"
elif brew list openclaw &> /dev/null 2>&1; then
    PACKAGE_MANAGER="brew"
elif npm list -g clawdbot &> /dev/null 2>&1; then
    PACKAGE_MANAGER="npm"
    OPENCLAW_CMD="clawdbot"
fi

# =============================================================================
# COLORS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING
# =============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$UPGRADE_LOG"
}

info() {
    echo -e "${BLUE}$1${NC}"
}

success() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

error() {
    echo -e "${RED}$1${NC}" >&2
}

# =============================================================================
# LOCK MANAGEMENT
# =============================================================================

check_lock() {
    if [ -f "$LOCKFILE" ]; then
        if [ "$(uname)" = "Darwin" ]; then
            LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCKFILE") ))
        else
            LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE") ))
        fi

        if [ $LOCK_AGE -gt $MAX_LOCK_AGE ]; then
            log "Removing stale upgrade lock file (age: ${LOCK_AGE}s)"
            rm -f "$LOCKFILE"
            return 1
        else
            return 0
        fi
    fi
    return 1
}

acquire_lock() {
    if check_lock; then
        error "Another upgrade operation is in progress"
        exit 1
    fi
    touch "$LOCKFILE"
}

release_lock() {
    rm -f "$LOCKFILE"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

get_installed_version() {
    if [ -n "$OPENCLAW_CMD" ]; then
        $OPENCLAW_CMD --version 2>/dev/null | head -1 | sed 's/[^0-9.]//g' || echo "unknown"
    else
        echo "unknown"
    fi
}

get_latest_version() {
    local latest=""

    if [ "$PACKAGE_MANAGER" = "npm" ]; then
        # Get latest version from npm registry
        local pkg_name="openclaw"
        if [ "$OPENCLAW_CMD" = "clawdbot" ]; then
            pkg_name="clawdbot"
        fi
        latest=$(npm view "$pkg_name" version 2>/dev/null || echo "")
    elif [ "$PACKAGE_MANAGER" = "brew" ]; then
        # Get latest version from Homebrew
        latest=$(brew info openclaw 2>/dev/null | head -1 | awk '{print $3}' | sed 's/[^0-9.]//g' || echo "")
    fi

    echo "${latest:-unknown}"
}

version_compare() {
    # Returns: 0 if $1 = $2, 1 if $1 > $2, 2 if $1 < $2
    if [ "$1" = "$2" ]; then
        return 0
    fi

    local IFS=.
    local i ver1=($1) ver2=($2)

    # Fill empty positions with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do
        ver2[i]=0
    done

    for ((i=0; i<${#ver1[@]}; i++)); do
        if ((10#${ver1[i]:-0} > 10#${ver2[i]:-0})); then
            return 1
        fi
        if ((10#${ver1[i]:-0} < 10#${ver2[i]:-0})); then
            return 2
        fi
    done
    return 0
}

# =============================================================================
# CHECK FOR UPDATES
# =============================================================================

cmd_check() {
    if [ -z "$OPENCLAW_CMD" ]; then
        error "OpenClaw is not installed"
        exit 1
    fi

    if [ -z "$PACKAGE_MANAGER" ]; then
        error "Could not detect package manager (npm or brew)"
        error "OpenClaw must be installed via npm or Homebrew"
        exit 1
    fi

    info "Checking for OpenClaw updates..."
    log "Checking for updates"

    local installed
    installed=$(get_installed_version)
    local latest
    latest=$(get_latest_version)

    echo ""
    echo "Package manager: $PACKAGE_MANAGER"
    echo "Installed:       $installed"
    echo "Latest:          $latest"
    echo ""

    if [ "$installed" = "unknown" ] || [ "$latest" = "unknown" ]; then
        warn "Unable to determine version information"
        log "Version check failed: installed=$installed, latest=$latest"
        exit 1
    fi

    if version_compare "$installed" "$latest"; then
        success "You are running the latest version!"
        log "Version check: up to date ($installed)"
        return 0
    fi

    version_compare "$installed" "$latest" || true
    local cmp_result=$?

    if [ $cmp_result -eq 2 ]; then
        warn "Update available: $installed -> $latest"
        echo ""
        echo "Run 'sentinel upgrade' to update"
        log "Version check: update available ($installed -> $latest)"
        return 1
    else
        success "You are running version $installed (latest: $latest)"
        log "Version check: current ($installed)"
        return 0
    fi
}

# =============================================================================
# CREATE PRE-UPGRADE BACKUP
# =============================================================================

create_pre_upgrade_backup() {
    if [ "$BACKUP_BEFORE_UPGRADE" != "true" ]; then
        info "Skipping pre-upgrade backup (disabled in config)"
        log "Pre-upgrade backup skipped (disabled)"
        return 0
    fi

    local backup_script="$SENTINEL_DIR/backup.sh"
    if [ ! -x "$backup_script" ]; then
        warn "Backup script not found, skipping pre-upgrade backup"
        log "Pre-upgrade backup skipped (script not found)"
        return 0
    fi

    info "Creating pre-upgrade backup..."
    log "Creating pre-upgrade backup"

    if "$backup_script" create --full 2>&1; then
        success "Pre-upgrade backup created"
        log "Pre-upgrade backup successful"
        return 0
    else
        error "Failed to create pre-upgrade backup"
        log "Pre-upgrade backup failed"
        return 1
    fi
}

# =============================================================================
# PERFORM UPGRADE
# =============================================================================

perform_upgrade() {
    local force="${1:-false}"

    if [ -z "$OPENCLAW_CMD" ]; then
        error "OpenClaw is not installed"
        exit 1
    fi

    if [ -z "$PACKAGE_MANAGER" ]; then
        error "Could not detect package manager (npm or brew)"
        exit 1
    fi

    local installed
    installed=$(get_installed_version)
    local latest
    latest=$(get_latest_version)

    # Check if upgrade is needed
    if [ "$force" != "true" ]; then
        if version_compare "$installed" "$latest"; then
            success "Already running latest version ($installed)"
            log "Upgrade skipped: already up to date"
            return 0
        fi

        version_compare "$installed" "$latest" || true
        local cmp_result=$?
        if [ $cmp_result -ne 2 ]; then
            success "Already running version $installed (latest: $latest)"
            log "Upgrade skipped: version is current or newer"
            return 0
        fi
    fi

    info "Upgrading OpenClaw from $installed to $latest..."
    log "Starting upgrade: $installed -> $latest"

    # Stop gateway before upgrade
    info "Stopping gateway..."
    if [ -n "$OPENCLAW_CMD" ]; then
        $OPENCLAW_CMD gateway stop 2>/dev/null || true
    fi
    pkill -f 'openclaw gateway\|clawdbot gateway' 2>/dev/null || true
    sleep 2

    # Perform the upgrade
    local upgrade_success=false

    if [ "$PACKAGE_MANAGER" = "npm" ]; then
        info "Upgrading via npm..."
        local pkg_name="openclaw"
        if [ "$OPENCLAW_CMD" = "clawdbot" ]; then
            pkg_name="clawdbot"
        fi
        if npm update -g "$pkg_name" 2>&1; then
            upgrade_success=true
        fi
    elif [ "$PACKAGE_MANAGER" = "brew" ]; then
        info "Upgrading via Homebrew..."
        if brew upgrade openclaw 2>&1; then
            upgrade_success=true
        fi
    fi

    if [ "$upgrade_success" = true ]; then
        success "Package upgrade completed"
        log "Package upgrade completed"
        return 0
    else
        error "Package upgrade failed"
        log "Package upgrade failed"
        return 1
    fi
}

# =============================================================================
# VERIFY UPGRADE
# =============================================================================

verify_upgrade() {
    local expected_version="${1:-}"

    info "Verifying upgrade..."
    log "Verifying upgrade"

    local verified=true

    # Check version
    local new_version
    new_version=$(get_installed_version)
    echo "  New version: $new_version"

    if [ -n "$expected_version" ] && [ "$new_version" != "$expected_version" ]; then
        warn "  Expected version $expected_version, got $new_version"
        verified=false
    fi

    # Run openclaw doctor
    info "Running diagnostics..."
    if [ -n "$OPENCLAW_CMD" ]; then
        if $OPENCLAW_CMD doctor 2>&1; then
            success "  Diagnostics passed"
        else
            error "  Diagnostics failed"
            verified=false
        fi
    fi

    # Try to start gateway
    info "Starting gateway..."
    if [ -n "$OPENCLAW_CMD" ]; then
        # Try launchctl first
        if launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null; then
            log "Gateway restart triggered via launchctl"
        else
            # Try starting directly
            nohup $OPENCLAW_CMD gateway > /dev/null 2>&1 &
            log "Gateway started directly"
        fi
    fi

    # Wait and check gateway
    sleep 5
    local gateway_url="${GATEWAY_URL:-http://127.0.0.1:18789}"
    if curl -s --max-time 10 "$gateway_url" > /dev/null 2>&1; then
        success "  Gateway is running"
    else
        warn "  Gateway not responding (may need manual start)"
    fi

    if [ "$verified" = true ]; then
        success "Upgrade verification passed"
        log "Upgrade verification passed"
        return 0
    else
        error "Upgrade verification failed"
        log "Upgrade verification failed"
        return 1
    fi
}

# =============================================================================
# ROLLBACK
# =============================================================================

cmd_rollback() {
    info "Rolling back to pre-upgrade backup..."
    log "Starting rollback"

    local backup_script="$SENTINEL_DIR/backup.sh"
    if [ ! -x "$backup_script" ]; then
        error "Backup script not found"
        exit 1
    fi

    # Find most recent backup (should be pre-upgrade)
    local latest_backup
    latest_backup=$(ls -t "$SENTINEL_DIR/backups"/openclaw-backup-*.tar.gz 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        error "No backup found to restore"
        exit 1
    fi

    info "Restoring from: $(basename "$latest_backup")"

    if "$backup_script" restore --latest --yes 2>&1; then
        success "Rollback completed"
        log "Rollback successful"
        return 0
    else
        error "Rollback failed"
        log "Rollback failed"
        return 1
    fi
}

# =============================================================================
# RECORD UPGRADE HISTORY
# =============================================================================

record_upgrade() {
    local from_version="$1"
    local to_version="$2"
    local status="$3"
    local notes="${4:-}"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local epoch
    epoch=$(date +%s)

    # Initialize history file if needed
    if [ ! -f "$HISTORY_FILE" ]; then
        echo "[]" > "$HISTORY_FILE"
    fi

    # Create new entry
    local entry
    entry=$(cat <<EOF
{
  "id": "${epoch}-upgrade",
  "timestamp": "$timestamp",
  "epoch": $epoch,
  "from_version": "$from_version",
  "to_version": "$to_version",
  "package_manager": "$PACKAGE_MANAGER",
  "status": "$status",
  "notes": "$notes"
}
EOF
)

    # Append to history (using jq if available, otherwise basic approach)
    if command -v jq &> /dev/null; then
        local temp_file
        temp_file=$(mktemp)
        jq --argjson entry "$entry" '. += [$entry]' "$HISTORY_FILE" > "$temp_file" 2>/dev/null && \
            mv "$temp_file" "$HISTORY_FILE" || rm -f "$temp_file"
    fi

    log "Recorded upgrade: $from_version -> $to_version ($status)"
}

# =============================================================================
# UPGRADE COMMAND
# =============================================================================

cmd_upgrade() {
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    acquire_lock
    trap release_lock EXIT

    local installed
    installed=$(get_installed_version)
    local latest
    latest=$(get_latest_version)

    info "OpenClaw Upgrade"
    echo ""
    echo "Installed version: $installed"
    echo "Latest version:    $latest"
    echo "Package manager:   $PACKAGE_MANAGER"
    echo ""

    log "Starting upgrade process: $installed -> $latest (force=$force)"

    # Create pre-upgrade backup
    if ! create_pre_upgrade_backup; then
        error "Pre-upgrade backup failed, aborting"
        record_upgrade "$installed" "$latest" "failed" "Pre-upgrade backup failed"
        exit 1
    fi

    # Perform upgrade
    if ! perform_upgrade "$force"; then
        error "Upgrade failed"
        echo ""
        warn "Rolling back..."
        if cmd_rollback; then
            record_upgrade "$installed" "$latest" "rolled_back" "Upgrade failed, rolled back"
        else
            record_upgrade "$installed" "$latest" "failed" "Upgrade and rollback failed"
        fi
        exit 1
    fi

    # Verify upgrade
    if ! verify_upgrade "$latest"; then
        error "Verification failed"
        echo ""
        warn "Rolling back..."
        if cmd_rollback; then
            record_upgrade "$installed" "$latest" "rolled_back" "Verification failed, rolled back"
        else
            record_upgrade "$installed" "$latest" "failed" "Verification and rollback failed"
        fi
        exit 1
    fi

    # Success
    local new_version
    new_version=$(get_installed_version)
    record_upgrade "$installed" "$new_version" "success" ""

    echo ""
    success "Upgrade completed successfully!"
    echo ""
    echo "Previous version: $installed"
    echo "Current version:  $new_version"
    log "Upgrade completed: $installed -> $new_version"
}

# =============================================================================
# AUTO-UPGRADE (for scheduled runs)
# =============================================================================

cmd_auto() {
    if [ "$UPGRADE_ENABLED" != "true" ]; then
        log "Auto-upgrade skipped (disabled in config)"
        exit 0
    fi

    log "Running scheduled upgrade check"

    # Check for updates
    local installed
    installed=$(get_installed_version)
    local latest
    latest=$(get_latest_version)

    if [ "$installed" = "unknown" ] || [ "$latest" = "unknown" ]; then
        log "Auto-upgrade: could not determine versions"
        exit 0
    fi

    version_compare "$installed" "$latest" || true
    local cmp_result=$?

    if [ $cmp_result -ne 2 ]; then
        log "Auto-upgrade: already up to date ($installed)"
        exit 0
    fi

    log "Auto-upgrade: update available ($installed -> $latest)"

    if [ "$UPGRADE_AUTO_APPLY" = "true" ]; then
        log "Auto-upgrade: applying upgrade"
        cmd_upgrade
    else
        log "Auto-upgrade: update available but auto-apply disabled"
        echo "OpenClaw update available: $installed -> $latest"
        echo "Run 'sentinel upgrade' to apply"
    fi
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
OpenClaw Sentinel Upgrade

Usage: upgrade.sh <command> [options]

Commands:
  check                 Check for available updates
  upgrade [--force]     Perform upgrade with backup and verification
                        --force: Upgrade even if current version
  rollback              Restore from pre-upgrade backup
  auto                  Scheduled auto-upgrade (respects config)

Options:
  -h, --help            Show this help message

Configuration (in sentinel.conf):
  BACKUP_BEFORE_UPGRADE   Create backup before upgrading (default: true)
  UPGRADE_ENABLED         Enable auto-upgrade checks (default: false)
  UPGRADE_SCHEDULE        Schedule: "weekly" or "daily" (default: weekly)
  UPGRADE_AUTO_APPLY      Automatically apply updates (default: false)

Examples:
  upgrade.sh check             # Check for new version
  upgrade.sh upgrade           # Upgrade with backup and verification
  upgrade.sh upgrade --force   # Force upgrade even if current
  upgrade.sh rollback          # Restore pre-upgrade backup

Upgrade Process:
  1. Check for available updates (npm or brew)
  2. Create pre-upgrade backup (if enabled)
  3. Stop gateway
  4. Perform package upgrade
  5. Verify with openclaw doctor
  6. Start gateway
  7. Rollback on any failure

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        check)
            cmd_check "$@"
            ;;
        upgrade)
            cmd_upgrade "$@"
            ;;
        rollback)
            cmd_rollback "$@"
            ;;
        auto)
            cmd_auto "$@"
            ;;
        -h|--help|help)
            show_help
            ;;
        "")
            show_help
            ;;
        *)
            error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
