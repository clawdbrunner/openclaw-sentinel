#!/bin/bash
# OpenClaw Sentinel Installer
# Installs and configures the Sentinel health monitoring system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTINEL_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
SENTINEL_DIR="$HOME/.openclaw/sentinel"
CONFIG_FILE="$HOME/.openclaw/sentinel.conf"
LOG_DIR="$SENTINEL_DIR/logs"
BACKUP_DIR="$SENTINEL_DIR/backups"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.sentinel.plist"
LAUNCHD_BACKUP_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.sentinel.backup.plist"
LAUNCHD_UPGRADE_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.sentinel.upgrade.plist"

# Legacy paths (for migration)
LEGACY_SENTINEL_DIR="$HOME/.clawdbot/sentinel"
LEGACY_CONFIG_FILE="$HOME/.clawdbot/sentinel.conf"
LEGACY_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.clawdbot.sentinel.plist"

# Default settings
DEFAULT_CHECK_INTERVAL=300
DEFAULT_MAX_BUDGET=2.00
DEFAULT_MAX_TURNS=20
DEFAULT_BACKUP_HOUR=3

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                   OpenClaw Sentinel Installer                 ║"
echo "║         Automated health monitoring with Claude Code          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
# CHECKS
# =============================================================================

echo -e "${BLUE}Checking requirements...${NC}"

# Check for macOS
if [ "$(uname)" != "Darwin" ]; then
    echo -e "${RED}Error: Sentinel currently only supports macOS${NC}"
    echo "Linux support (systemd) coming soon."
    exit 1
fi

# Check for openclaw (or clawdbot as fallback)
OPENCLAW_CMD=""
if command -v openclaw &> /dev/null; then
    OPENCLAW_CMD="openclaw"
    echo -e "${GREEN}✓${NC} OpenClaw found: $(which openclaw)"
elif command -v clawdbot &> /dev/null; then
    OPENCLAW_CMD="clawdbot"
    echo -e "${YELLOW}!${NC} Using legacy clawdbot CLI: $(which clawdbot)"
    echo "  Consider updating: npm install -g openclaw"
else
    echo -e "${RED}Error: openclaw not found${NC}"
    echo "Please install OpenClaw first: https://docs.openclaw.ai/"
    exit 1
fi

# Check for claude
if ! command -v claude &> /dev/null; then
    echo -e "${RED}Error: claude (Claude Code) not found${NC}"
    echo "Please install Claude Code first: https://claude.ai/claude-code"
    exit 1
fi
echo -e "${GREEN}✓${NC} Claude Code found: $(which claude)"

# Check for existing installation (both new and legacy)
NEED_REINSTALL=false
if [ -f "$LAUNCHD_PLIST" ]; then
    echo -e "${YELLOW}Warning: Sentinel is already installed${NC}"
    NEED_REINSTALL=true
elif [ -f "$LEGACY_LAUNCHD_PLIST" ]; then
    echo -e "${YELLOW}Warning: Legacy clawdbot-sentinel found, will migrate${NC}"
    NEED_REINSTALL=true
fi

if [ "$NEED_REINSTALL" = true ]; then
    read -p "Do you want to reinstall/migrate? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
    # Unload existing services
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCHD_BACKUP_PLIST" 2>/dev/null || true
    launchctl unload "$LAUNCHD_UPGRADE_PLIST" 2>/dev/null || true
    launchctl unload "$LEGACY_LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_LAUNCHD_PLIST"
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

echo ""
echo -e "${BLUE}Configuration${NC}"
echo "Press Enter to accept defaults shown in brackets."
echo ""

# Migrate existing config if present
if [ -f "$LEGACY_CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}Migrating config from legacy location...${NC}"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cp "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
fi

# Load existing values if config exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE" 2>/dev/null || true
fi

# Check interval
CURRENT_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
read -p "Health check interval in seconds [$CURRENT_INTERVAL]: " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-$CURRENT_INTERVAL}

# Max budget
CURRENT_BUDGET="${MAX_BUDGET_USD:-$DEFAULT_MAX_BUDGET}"
read -p "Maximum USD per repair attempt [$CURRENT_BUDGET]: " MAX_BUDGET
MAX_BUDGET=${MAX_BUDGET:-$CURRENT_BUDGET}

# Max turns
CURRENT_TURNS="${MAX_TURNS:-$DEFAULT_MAX_TURNS}"
read -p "Maximum Claude Code turns per repair [$CURRENT_TURNS]: " MAX_TURNS
MAX_TURNS=${MAX_TURNS:-$CURRENT_TURNS}

# Backup schedule hour
CURRENT_BACKUP_HOUR="${BACKUP_SCHEDULE_HOUR:-$DEFAULT_BACKUP_HOUR}"
read -p "Daily backup hour (0-23, 24h format) [$CURRENT_BACKUP_HOUR]: " BACKUP_HOUR
BACKUP_HOUR=${BACKUP_HOUR:-$CURRENT_BACKUP_HOUR}

# =============================================================================
# INSTALLATION
# =============================================================================

echo ""
echo -e "${BLUE}Installing Sentinel...${NC}"

# Create directories
mkdir -p "$SENTINEL_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"
mkdir -p "$HOME/Library/LaunchAgents"
echo -e "${GREEN}✓${NC} Created directories"

# Copy health check script
cp "$SCRIPT_DIR/scripts/health-check.sh" "$SENTINEL_DIR/health-check.sh"
chmod +x "$SENTINEL_DIR/health-check.sh"
echo -e "${GREEN}✓${NC} Installed health check script"

# Copy backup script
cp "$SCRIPT_DIR/scripts/backup.sh" "$SENTINEL_DIR/backup.sh"
chmod +x "$SENTINEL_DIR/backup.sh"
echo -e "${GREEN}✓${NC} Installed backup script"

# Copy upgrade script
cp "$SCRIPT_DIR/scripts/upgrade.sh" "$SENTINEL_DIR/upgrade.sh"
chmod +x "$SENTINEL_DIR/upgrade.sh"
echo -e "${GREEN}✓${NC} Installed upgrade script"

# Copy CLAUDE.md context file
cp "$SCRIPT_DIR/config/CLAUDE.md" "$HOME/.openclaw/CLAUDE.md"
echo -e "${GREEN}✓${NC} Installed CLAUDE.md context file"

# Record installed sentinel version
echo "$SENTINEL_VERSION" > "$SENTINEL_DIR/VERSION"
echo -e "${GREEN}✓${NC} Recorded sentinel version ($SENTINEL_VERSION)"

# Create configuration file
cat > "$CONFIG_FILE" << EOF
# OpenClaw Sentinel Configuration
# Generated by installer on $(date)

# Health check interval in seconds
CHECK_INTERVAL=$CHECK_INTERVAL

# Maximum USD to spend per repair attempt
MAX_BUDGET_USD=$MAX_BUDGET

# Maximum Claude Code turns per repair
MAX_TURNS=$MAX_TURNS

# Gateway URL to monitor
GATEWAY_URL="http://127.0.0.1:18789"

# Tools Claude Code can use for repairs
ALLOWED_TOOLS="Bash,Read,Edit,Glob,Grep,WebFetch"

# Seconds to wait before confirming gateway is down
CONFIRMATION_DELAY=5

# Maximum age of lock file before considering it stale (seconds)
MAX_LOCK_AGE=1800

# Keep logs for this many days (0 = keep forever)
LOG_RETENTION_DAYS=30

# --- Backup ---
BACKUP_ENABLED=true
BACKUP_DIR="$BACKUP_DIR"
BACKUP_SCHEDULE_HOUR=$BACKUP_HOUR
BACKUP_TIER_WORKSPACE=true
BACKUP_TIER_EXTENDED=false
MAX_BACKUPS=14
BACKUP_BEFORE_UPGRADE=true

# --- Upgrade ---
# Enable scheduled upgrade checks (disabled by default)
UPGRADE_ENABLED=false
# Schedule: runs weekly on Sunday at 04:00
UPGRADE_SCHEDULE="weekly"
# Automatically apply updates (if false, only notifies)
UPGRADE_AUTO_APPLY=false
EOF
echo -e "${GREEN}✓${NC} Created configuration file"

# Generate launchd plist from template
sed -e "s|{{SENTINEL_DIR}}|$SENTINEL_DIR|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    -e "s|{{HOME}}|$HOME|g" \
    -e "s|{{CHECK_INTERVAL}}|$CHECK_INTERVAL|g" \
    -e "s|{{CONFIG_FILE}}|$CONFIG_FILE|g" \
    "$SCRIPT_DIR/launchd/ai.openclaw.sentinel.plist.template" > "$LAUNCHD_PLIST"
echo -e "${GREEN}✓${NC} Created launchd health service"

# Generate backup launchd plist from template
sed -e "s|{{SENTINEL_DIR}}|$SENTINEL_DIR|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    -e "s|{{HOME}}|$HOME|g" \
    -e "s|{{BACKUP_SCHEDULE_HOUR}}|$BACKUP_HOUR|g" \
    -e "s|{{CONFIG_FILE}}|$CONFIG_FILE|g" \
    "$SCRIPT_DIR/launchd/ai.openclaw.sentinel.backup.plist.template" > "$LAUNCHD_BACKUP_PLIST"
echo -e "${GREEN}✓${NC} Created launchd backup service"

# Generate upgrade launchd plist from template (disabled by default)
sed -e "s|{{SENTINEL_DIR}}|$SENTINEL_DIR|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    -e "s|{{HOME}}|$HOME|g" \
    -e "s|{{CONFIG_FILE}}|$CONFIG_FILE|g" \
    "$SCRIPT_DIR/launchd/ai.openclaw.sentinel.upgrade.plist.template" > "$LAUNCHD_UPGRADE_PLIST"
echo -e "${GREEN}✓${NC} Created launchd upgrade service (disabled by default)"

# Load the services
launchctl load "$LAUNCHD_PLIST"
echo -e "${GREEN}✓${NC} Started Sentinel health service"

launchctl load "$LAUNCHD_BACKUP_PLIST"
echo -e "${GREEN}✓${NC} Started Sentinel backup service"

# =============================================================================
# SHELL ALIASES (optional)
# =============================================================================

echo ""
read -p "Add 'sentinel' command aliases to your shell? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    # Detect shell
    SHELL_RC=""
    if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
        SHELL_RC="$HOME/.zshrc"
    elif [ -n "${BASH_VERSION:-}" ] || [ -f "$HOME/.bashrc" ]; then
        SHELL_RC="$HOME/.bashrc"
    fi

    if [ -n "$SHELL_RC" ]; then
        # Remove old aliases if present
        if grep -q "# Clawdbot Sentinel aliases" "$SHELL_RC" 2>/dev/null; then
            # Remove the old block
            sed -i.bak '/# Clawdbot Sentinel aliases/,/^$/d' "$SHELL_RC"
            echo -e "${YELLOW}!${NC} Removed legacy Clawdbot Sentinel aliases"
        fi

        # Check if new aliases already added
        if ! grep -q "# OpenClaw Sentinel aliases" "$SHELL_RC" 2>/dev/null; then
            cat >> "$SHELL_RC" << 'EOF'

# OpenClaw Sentinel aliases
sentinel() {
    case "${1:---help}" in
        version|--version|-v)
            local sv="unknown"
            [ -f ~/.openclaw/sentinel/VERSION ] && sv=$(cat ~/.openclaw/sentinel/VERSION)
            echo "OpenClaw Sentinel v${sv}"
            if command -v openclaw &>/dev/null; then
                echo "OpenClaw $(openclaw --version 2>/dev/null | head -1 || echo 'unknown')"
            elif command -v clawdbot &>/dev/null; then
                echo "Clawdbot $(clawdbot --version 2>/dev/null | head -1 || echo 'unknown')"
            fi
            ;;
        status)
            launchctl list | grep sentinel && echo "" && tail -5 ~/.openclaw/sentinel/logs/health.log
            ;;
        check)
            ~/.openclaw/sentinel/health-check.sh
            ;;
        logs)
            tail -f ~/.openclaw/sentinel/logs/health.log
            ;;
        repairs)
            tail -f ~/.openclaw/sentinel/logs/repairs.log
            ;;
        backup)
            shift
            ~/.openclaw/sentinel/backup.sh "$@"
            ;;
        upgrade)
            shift
            case "${1:-}" in
                check)
                    ~/.openclaw/sentinel/upgrade.sh check
                    ;;
                rollback)
                    ~/.openclaw/sentinel/upgrade.sh rollback
                    ;;
                --force|-f)
                    ~/.openclaw/sentinel/upgrade.sh upgrade --force
                    ;;
                ""|--help|-h)
                    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
                        ~/.openclaw/sentinel/upgrade.sh --help
                    else
                        ~/.openclaw/sentinel/upgrade.sh upgrade
                    fi
                    ;;
                *)
                    echo "Unknown upgrade option: $1"
                    ~/.openclaw/sentinel/upgrade.sh --help
                    ;;
            esac
            ;;
        *)
            echo "Usage: sentinel {version|status|check|logs|repairs|backup|upgrade}"
            echo ""
            echo "  sentinel version             Show sentinel and OpenClaw versions"
            echo ""
            echo "Backup commands:"
            echo "  sentinel backup              Create a backup"
            echo "  sentinel backup --full       Create a full backup (all tiers)"
            echo "  sentinel backup list         List available backups"
            echo "  sentinel backup restore ...  Restore from a backup"
            echo "  sentinel backup prune        Remove old backups"
            echo ""
            echo "Upgrade commands:"
            echo "  sentinel upgrade check       Check for available updates"
            echo "  sentinel upgrade             Upgrade with backup and verification"
            echo "  sentinel upgrade --force     Force upgrade even if current"
            echo "  sentinel upgrade rollback    Restore pre-upgrade backup"
            ;;
    esac
}
EOF
            echo -e "${GREEN}✓${NC} Added aliases to $SHELL_RC"
            echo "  Run 'source $SHELL_RC' or start a new terminal to use them."
        else
            echo -e "${YELLOW}!${NC} Aliases already exist in $SHELL_RC"
        fi
    else
        echo -e "${YELLOW}!${NC} Could not detect shell config file"
    fi
fi

# =============================================================================
# CLEANUP LEGACY
# =============================================================================

# Remove legacy config if we migrated it
if [ -f "$LEGACY_CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    rm -f "$LEGACY_CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Cleaned up legacy config"
fi

# =============================================================================
# COMPLETE
# =============================================================================

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Sentinel installed successfully!                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Version:        $SENTINEL_VERSION"
echo "Configuration:  $CONFIG_FILE"
echo "Logs:           $LOG_DIR/"
echo "Backups:        $BACKUP_DIR/"
echo "Check interval: Every $CHECK_INTERVAL seconds"
echo "Backup time:    Daily at ${BACKUP_HOUR}:00"
echo ""
echo "Commands:"
echo "  sentinel version  - Show installed version"
echo "  sentinel status   - Check service status"
echo "  sentinel check    - Manually trigger health check"
echo "  sentinel logs     - View health logs"
echo "  sentinel repairs  - View repair logs"
echo ""
echo "Backup commands:"
echo "  sentinel backup             - Create a backup now"
echo "  sentinel backup --full      - Create a full backup (all tiers)"
echo "  sentinel backup list        - List available backups"
echo "  sentinel backup restore ... - Restore from a backup"
echo "  sentinel backup prune       - Remove old backups"
echo ""
echo "Upgrade commands:"
echo "  sentinel upgrade check      - Check for available updates"
echo "  sentinel upgrade            - Upgrade with backup and verification"
echo "  sentinel upgrade --force    - Force upgrade even if current"
echo "  sentinel upgrade rollback   - Restore pre-upgrade backup"
echo ""
echo "To modify settings, edit: $CONFIG_FILE"
echo "Then restart services:"
echo "  launchctl unload $LAUNCHD_PLIST && launchctl load $LAUNCHD_PLIST"
echo "  launchctl unload $LAUNCHD_BACKUP_PLIST && launchctl load $LAUNCHD_BACKUP_PLIST"
echo ""
