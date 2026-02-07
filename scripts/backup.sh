#!/bin/bash
# OpenClaw Sentinel Backup
# Creates, lists, restores, and manages backups of OpenClaw state

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
BACKUP_ENABLED=true
BACKUP_DIR="$SENTINEL_DIR/backups"
BACKUP_TIER_WORKSPACE=true
BACKUP_TIER_EXTENDED=false
MAX_BACKUPS=14
MAX_LOCK_AGE=1800

# Load user configuration if exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

LOG_DIR="$SENTINEL_DIR/logs"
mkdir -p "$LOG_DIR"
BACKUP_LOG="$LOG_DIR/backup.log"
LOCKFILE="$SENTINEL_DIR/backup.lock"

# Detect which CLI to use (openclaw preferred, clawdbot as fallback)
if command -v openclaw &> /dev/null; then
    OPENCLAW_CMD="openclaw"
elif command -v clawdbot &> /dev/null; then
    OPENCLAW_CMD="clawdbot"
else
    OPENCLAW_CMD=""
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
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$BACKUP_LOG"
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
            log "Removing stale backup lock file (age: ${LOCK_AGE}s)"
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
        error "Another backup operation is in progress"
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

get_openclaw_version() {
    if [ -n "$OPENCLAW_CMD" ]; then
        $OPENCLAW_CMD --version 2>/dev/null | head -1 || echo "unknown"
    else
        echo "unknown"
    fi
}

get_config_checksum() {
    local config_file="$OPENCLAW_DIR/openclaw.json"
    if [ -f "$config_file" ]; then
        shasum -a 256 "$config_file" 2>/dev/null | cut -d' ' -f1 || echo "unknown"
    else
        echo "no-config"
    fi
}

human_readable_size() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024))K"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576))M"
    else
        echo "$((bytes / 1073741824))G"
    fi
}

# =============================================================================
# BACKUP CREATE
# =============================================================================

cmd_create() {
    local force_full=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)
                force_full=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [ "$BACKUP_ENABLED" != "true" ]; then
        warn "Backups are disabled in configuration"
        warn "Set BACKUP_ENABLED=true in $CONFIG_FILE to enable"
        exit 0
    fi

    acquire_lock
    trap release_lock EXIT

    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local backup_name="openclaw-backup-${timestamp}.tar.gz"
    local backup_path="$BACKUP_DIR/$backup_name"
    local temp_dir
    temp_dir=$(mktemp -d)
    local manifest_file="$temp_dir/manifest.json"

    info "Creating backup: $backup_name"
    log "Starting backup creation: $backup_name"

    # Determine which tiers to include
    local include_workspace=$BACKUP_TIER_WORKSPACE
    local include_extended=$BACKUP_TIER_EXTENDED

    if [ "$force_full" = true ]; then
        include_workspace=true
        include_extended=true
        info "Full backup mode: including all tiers"
    fi

    # Build file list
    local files_to_backup=()
    local files_found=()

    # Core tier (always included)
    info "Including Core tier..."
    [ -f "$OPENCLAW_DIR/openclaw.json" ] && files_to_backup+=("openclaw.json") && files_found+=("openclaw.json")
    [ -d "$OPENCLAW_DIR/credentials" ] && files_to_backup+=("credentials") && files_found+=("credentials/")
    [ -f "$CONFIG_FILE" ] && {
        # Copy sentinel.conf to temp dir for inclusion
        cp "$CONFIG_FILE" "$temp_dir/sentinel.conf"
        files_found+=("sentinel.conf")
    }

    # Workspace tier
    if [ "$include_workspace" = true ]; then
        info "Including Workspace tier..."
        [ -d "$OPENCLAW_DIR/workspace" ] && files_to_backup+=("workspace") && files_found+=("workspace/")
    fi

    # Extended tier
    if [ "$include_extended" = true ]; then
        info "Including Extended tier..."
        [ -d "$OPENCLAW_DIR/agents" ] && files_to_backup+=("agents") && files_found+=("agents/")
        [ -d "$OPENCLAW_DIR/skills" ] && files_to_backup+=("skills") && files_found+=("skills/")
        [ -d "$OPENCLAW_DIR/scripts" ] && files_to_backup+=("scripts") && files_found+=("scripts/")
    fi

    # Get OpenClaw version
    local oc_version
    oc_version=$(get_openclaw_version)

    # Get config checksum
    local config_checksum
    config_checksum=$(get_config_checksum)

    # Create manifest
    cat > "$manifest_file" << EOF
{
  "version": "1.0",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "timestamp_local": "$(date '+%Y-%m-%d %H:%M:%S %Z')",
  "openclaw_version": "$oc_version",
  "tier_workspace": $include_workspace,
  "tier_extended": $include_extended,
  "config_checksum_sha256": "$config_checksum",
  "files": [
$(printf '    "%s"' "${files_found[0]:-}")
$(for f in "${files_found[@]:1}"; do printf ',\n    "%s"' "$f"; done)
  ],
  "hostname": "$(hostname)",
  "created_by": "openclaw-sentinel-backup"
}
EOF

    # Create tarball
    info "Creating archive..."

    # Build tar command with exclusions
    local tar_excludes=(
        --exclude='*.log'
        --exclude='node_modules'
        --exclude='.git'
        --exclude='*.lock'
        --exclude='launchd-*.log'
        --exclude='*.sock'
        --exclude='*.pid'
    )

    # Create a staging directory
    local staging_dir
    staging_dir=$(mktemp -d)

    # Copy files to staging
    for item in "${files_to_backup[@]}"; do
        if [ -e "$OPENCLAW_DIR/$item" ]; then
            cp -R "$OPENCLAW_DIR/$item" "$staging_dir/" 2>/dev/null || true
        fi
    done

    # Copy sentinel.conf if it exists
    [ -f "$temp_dir/sentinel.conf" ] && cp "$temp_dir/sentinel.conf" "$staging_dir/"

    # Copy manifest
    cp "$manifest_file" "$staging_dir/"

    # Create the tarball
    if tar "${tar_excludes[@]}" -czf "$backup_path" -C "$staging_dir" . 2>/dev/null; then
        # Set restrictive permissions (contains credentials)
        chmod 600 "$backup_path"

        local backup_size
        if [ "$(uname)" = "Darwin" ]; then
            backup_size=$(stat -f %z "$backup_path")
        else
            backup_size=$(stat -c %s "$backup_path")
        fi
        local human_size
        human_size=$(human_readable_size "$backup_size")

        success "Backup created successfully!"
        echo "  Location: $backup_path"
        echo "  Size: $human_size"
        echo "  OpenClaw version: $oc_version"
        echo "  Files: ${#files_found[@]} items"

        log "Backup created: $backup_name (size: $human_size, files: ${#files_found[@]})"
    else
        error "Failed to create backup archive"
        log "ERROR: Failed to create backup archive"
        rm -f "$backup_path"
        rm -rf "$staging_dir" "$temp_dir"
        exit 1
    fi

    # Cleanup
    rm -rf "$staging_dir" "$temp_dir"

    success "Backup complete!"
}

# =============================================================================
# BACKUP LIST
# =============================================================================

cmd_list() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        info "No backups found in $BACKUP_DIR"
        exit 0
    fi

    echo ""
    printf "%-40s %10s %15s %s\n" "BACKUP" "SIZE" "OPENCLAW VER" "DATE"
    printf "%s\n" "$(printf '=%.0s' {1..85})"

    local count=0
    for backup in "$BACKUP_DIR"/openclaw-backup-*.tar.gz; do
        [ -f "$backup" ] || continue
        count=$((count + 1))

        local filename
        filename=$(basename "$backup")

        local size
        if [ "$(uname)" = "Darwin" ]; then
            size=$(stat -f %z "$backup")
        else
            size=$(stat -c %s "$backup")
        fi
        local human_size
        human_size=$(human_readable_size "$size")

        # Extract version from manifest if possible
        local version="unknown"
        local manifest
        manifest=$(tar -xzf "$backup" -O manifest.json 2>/dev/null || echo "")
        if [ -n "$manifest" ] && command -v jq &> /dev/null; then
            version=$(echo "$manifest" | jq -r '.openclaw_version // "unknown"' 2>/dev/null || echo "unknown")
        fi

        # Extract date from filename (openclaw-backup-YYYYMMDD-HHMMSS.tar.gz)
        local date_str
        date_str=$(echo "$filename" | sed -E 's/openclaw-backup-([0-9]{8})-([0-9]{6})\.tar\.gz/\1 \2/')
        local formatted_date
        if [[ "$date_str" =~ ^[0-9]{8}\ [0-9]{6}$ ]]; then
            # Format: YYYYMMDD HHMMSS -> YYYY-MM-DD HH:MM
            formatted_date=$(echo "$date_str" | sed -E 's/([0-9]{4})([0-9]{2})([0-9]{2}) ([0-9]{2})([0-9]{2})([0-9]{2})/\1-\2-\3 \4:\5/')
        else
            formatted_date="unknown"
        fi

        printf "%-40s %10s %15s %s\n" "$filename" "$human_size" "$version" "$formatted_date"
    done

    echo ""
    echo "Total: $count backup(s)"
    echo "Location: $BACKUP_DIR"
}

# =============================================================================
# BACKUP RESTORE
# =============================================================================

cmd_restore() {
    local backup_file=""
    local use_latest=false
    local auto_yes=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --latest)
                use_latest=true
                shift
                ;;
            --yes|-y)
                auto_yes=true
                shift
                ;;
            *)
                if [ -z "$backup_file" ]; then
                    backup_file="$1"
                else
                    error "Unknown option: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Find backup file
    if [ "$use_latest" = true ]; then
        backup_file=$(ls -t "$BACKUP_DIR"/openclaw-backup-*.tar.gz 2>/dev/null | head -1)
        if [ -z "$backup_file" ]; then
            error "No backups found to restore"
            exit 1
        fi
        info "Using latest backup: $(basename "$backup_file")"
    elif [ -n "$backup_file" ]; then
        # Check if it's just a filename or full path
        if [ ! -f "$backup_file" ]; then
            backup_file="$BACKUP_DIR/$backup_file"
        fi
        if [ ! -f "$backup_file" ]; then
            error "Backup file not found: $backup_file"
            exit 1
        fi
    else
        error "Usage: backup restore <filename> or backup restore --latest"
        exit 1
    fi

    acquire_lock
    trap release_lock EXIT

    # Extract and validate manifest
    info "Validating backup..."
    local manifest
    manifest=$(tar -xzf "$backup_file" -O manifest.json 2>/dev/null || echo "")

    if [ -z "$manifest" ]; then
        error "Invalid backup: no manifest found"
        exit 1
    fi

    local backup_version=""
    local backup_date=""
    local backup_files=""

    if command -v jq &> /dev/null; then
        backup_version=$(echo "$manifest" | jq -r '.openclaw_version // "unknown"')
        backup_date=$(echo "$manifest" | jq -r '.timestamp_local // .timestamp // "unknown"')
        backup_files=$(echo "$manifest" | jq -r '.files | length')
    else
        backup_version="unknown"
        backup_date="unknown"
        backup_files="unknown"
    fi

    echo ""
    echo "Backup details:"
    echo "  File: $(basename "$backup_file")"
    echo "  Date: $backup_date"
    echo "  OpenClaw version: $backup_version"
    echo "  Files: $backup_files items"
    echo ""

    # Confirmation
    if [ "$auto_yes" != true ]; then
        warn "WARNING: This will overwrite your current OpenClaw configuration!"
        echo ""
        read -p "Continue with restore? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Restore cancelled."
            exit 0
        fi
    fi

    # Stop gateway before restore
    info "Stopping gateway..."
    log "Stopping gateway before restore"
    if [ -n "$OPENCLAW_CMD" ]; then
        $OPENCLAW_CMD gateway stop 2>/dev/null || true
    fi
    # Also try to kill any running processes
    pkill -f 'openclaw gateway\|clawdbot gateway' 2>/dev/null || true
    sleep 2

    # Create pre-restore backup (safety net)
    info "Creating pre-restore backup..."
    log "Creating pre-restore safety backup"
    local pre_restore_name="openclaw-backup-pre-restore-$(date '+%Y%m%d-%H%M%S').tar.gz"
    local pre_restore_path="$BACKUP_DIR/$pre_restore_name"

    # Quick backup of current state
    local current_staging
    current_staging=$(mktemp -d)
    [ -f "$OPENCLAW_DIR/openclaw.json" ] && cp "$OPENCLAW_DIR/openclaw.json" "$current_staging/" 2>/dev/null || true
    [ -d "$OPENCLAW_DIR/credentials" ] && cp -R "$OPENCLAW_DIR/credentials" "$current_staging/" 2>/dev/null || true
    [ -d "$OPENCLAW_DIR/workspace" ] && cp -R "$OPENCLAW_DIR/workspace" "$current_staging/" 2>/dev/null || true
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$current_staging/sentinel.conf" 2>/dev/null || true

    # Create pre-restore manifest
    cat > "$current_staging/manifest.json" << EOF
{
  "version": "1.0",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "type": "pre-restore-backup",
  "original_backup": "$(basename "$backup_file")"
}
EOF

    tar -czf "$pre_restore_path" -C "$current_staging" . 2>/dev/null || true
    chmod 600 "$pre_restore_path" 2>/dev/null || true
    rm -rf "$current_staging"

    success "Pre-restore backup: $pre_restore_name"

    # Extract to temp directory first
    info "Extracting backup..."
    local restore_temp
    restore_temp=$(mktemp -d)

    if ! tar -xzf "$backup_file" -C "$restore_temp" 2>/dev/null; then
        error "Failed to extract backup"
        rm -rf "$restore_temp"
        exit 1
    fi

    # Restore files
    info "Restoring files..."
    log "Restoring from $(basename "$backup_file")"

    # Restore openclaw.json
    if [ -f "$restore_temp/openclaw.json" ]; then
        cp "$restore_temp/openclaw.json" "$OPENCLAW_DIR/openclaw.json"
        chmod 600 "$OPENCLAW_DIR/openclaw.json"
        success "  Restored: openclaw.json"
    fi

    # Restore credentials
    if [ -d "$restore_temp/credentials" ]; then
        rm -rf "$OPENCLAW_DIR/credentials"
        cp -R "$restore_temp/credentials" "$OPENCLAW_DIR/credentials"
        chmod -R 600 "$OPENCLAW_DIR/credentials" 2>/dev/null || true
        success "  Restored: credentials/"
    fi

    # Restore workspace
    if [ -d "$restore_temp/workspace" ]; then
        rm -rf "$OPENCLAW_DIR/workspace"
        cp -R "$restore_temp/workspace" "$OPENCLAW_DIR/workspace"
        success "  Restored: workspace/"
    fi

    # Restore agents
    if [ -d "$restore_temp/agents" ]; then
        rm -rf "$OPENCLAW_DIR/agents"
        cp -R "$restore_temp/agents" "$OPENCLAW_DIR/agents"
        success "  Restored: agents/"
    fi

    # Restore skills
    if [ -d "$restore_temp/skills" ]; then
        rm -rf "$OPENCLAW_DIR/skills"
        cp -R "$restore_temp/skills" "$OPENCLAW_DIR/skills"
        success "  Restored: skills/"
    fi

    # Restore scripts
    if [ -d "$restore_temp/scripts" ]; then
        rm -rf "$OPENCLAW_DIR/scripts"
        cp -R "$restore_temp/scripts" "$OPENCLAW_DIR/scripts"
        success "  Restored: scripts/"
    fi

    # Restore sentinel.conf
    if [ -f "$restore_temp/sentinel.conf" ]; then
        cp "$restore_temp/sentinel.conf" "$CONFIG_FILE"
        success "  Restored: sentinel.conf"
    fi

    # Cleanup
    rm -rf "$restore_temp"

    # Run doctor
    info "Running diagnostics..."
    if [ -n "$OPENCLAW_CMD" ]; then
        $OPENCLAW_CMD doctor 2>&1 || true
    fi

    # Restart gateway
    info "Restarting gateway..."
    if [ -n "$OPENCLAW_CMD" ]; then
        if launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null; then
            log "Gateway restart triggered via launchctl"
        else
            # Try starting directly
            nohup $OPENCLAW_CMD gateway > /dev/null 2>&1 &
            log "Gateway started directly"
        fi
    fi

    sleep 3
    log "Restore completed from $(basename "$backup_file")"

    echo ""
    success "Restore complete!"
    echo ""
    echo "Pre-restore backup saved as: $pre_restore_name"
    echo "If something went wrong, restore it with:"
    echo "  sentinel backup restore $pre_restore_name"
}

# =============================================================================
# BACKUP PRUNE
# =============================================================================

cmd_prune() {
    if [ ! -d "$BACKUP_DIR" ]; then
        info "No backup directory found"
        exit 0
    fi

    local backups
    backups=$(ls -t "$BACKUP_DIR"/openclaw-backup-*.tar.gz 2>/dev/null | grep -v "pre-restore" || true)
    local count
    count=$(echo "$backups" | grep -c "tar.gz" || echo "0")

    if [ "$count" -le "$MAX_BACKUPS" ]; then
        info "No pruning needed ($count backups, limit is $MAX_BACKUPS)"
        exit 0
    fi

    local to_delete=$((count - MAX_BACKUPS))
    info "Pruning $to_delete old backup(s) (keeping $MAX_BACKUPS)..."
    log "Pruning $to_delete backups"

    # Get oldest backups to delete
    local deleted=0
    echo "$backups" | tail -n "$to_delete" | while read -r backup; do
        if [ -f "$backup" ]; then
            rm -f "$backup"
            deleted=$((deleted + 1))
            log "Pruned: $(basename "$backup")"
            echo "  Deleted: $(basename "$backup")"
        fi
    done

    success "Pruned $to_delete backup(s)"
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
OpenClaw Sentinel Backup

Usage: backup.sh <command> [options]

Commands:
  create [--full]         Create a new backup
                          --full: Include all tiers regardless of config

  list                    List all available backups

  restore <file>          Restore from a specific backup file
  restore --latest        Restore from the most recent backup
                          --yes/-y: Skip confirmation prompt

  prune                   Remove old backups exceeding MAX_BACKUPS limit

Options:
  -h, --help              Show this help message

Configuration (in sentinel.conf):
  BACKUP_ENABLED          Enable/disable backups (default: true)
  BACKUP_DIR              Backup storage location
  BACKUP_TIER_WORKSPACE   Include workspace/ in backups (default: true)
  BACKUP_TIER_EXTENDED    Include agents/, skills, scripts (default: false)
  MAX_BACKUPS             Maximum backups to retain (default: 14)

Examples:
  backup.sh create                  # Create backup with configured tiers
  backup.sh create --full           # Create full backup (all tiers)
  backup.sh list                    # Show all backups
  backup.sh restore --latest        # Restore most recent backup
  backup.sh restore backup-20260206-030000.tar.gz  # Restore specific backup
  backup.sh prune                   # Remove old backups

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        create)
            cmd_create "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        restore)
            cmd_restore "$@"
            ;;
        prune)
            cmd_prune "$@"
            ;;
        -h|--help|help)
            show_help
            ;;
        "")
            # Default to create
            cmd_create "$@"
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
