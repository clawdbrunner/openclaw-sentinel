#!/bin/bash
# OpenClaw Sentinel Uninstaller
# Removes the Sentinel health monitoring system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration (both new and legacy paths)
SENTINEL_DIR="$HOME/.openclaw/sentinel"
CONFIG_FILE="$HOME/.openclaw/sentinel.conf"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/ai.openclaw.sentinel.plist"
CLAUDE_MD="$HOME/.openclaw/CLAUDE.md"

# Legacy paths
LEGACY_SENTINEL_DIR="$HOME/.clawdbot/sentinel"
LEGACY_CONFIG_FILE="$HOME/.clawdbot/sentinel.conf"
LEGACY_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.clawdbot.sentinel.plist"
LEGACY_CLAUDE_MD="$HOME/.clawdbot/CLAUDE.md"

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                  OpenClaw Sentinel Uninstaller                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if installed
FOUND_INSTALLATION=false
if [ -f "$LAUNCHD_PLIST" ] || [ -d "$SENTINEL_DIR" ]; then
    FOUND_INSTALLATION=true
fi
if [ -f "$LEGACY_LAUNCHD_PLIST" ] || [ -d "$LEGACY_SENTINEL_DIR" ]; then
    FOUND_INSTALLATION=true
fi

if [ "$FOUND_INSTALLATION" = false ]; then
    echo -e "${YELLOW}Sentinel does not appear to be installed.${NC}"
    exit 0
fi

# Confirm
echo "This will remove:"
[ -f "$LAUNCHD_PLIST" ] && echo "  - LaunchAgent: $LAUNCHD_PLIST"
[ -f "$LEGACY_LAUNCHD_PLIST" ] && echo "  - Legacy LaunchAgent: $LEGACY_LAUNCHD_PLIST"
[ -d "$SENTINEL_DIR" ] && echo "  - Sentinel directory: $SENTINEL_DIR"
[ -d "$LEGACY_SENTINEL_DIR" ] && echo "  - Legacy directory: $LEGACY_SENTINEL_DIR"
[ -f "$CONFIG_FILE" ] && echo "  - Config file: $CONFIG_FILE"
[ -f "$LEGACY_CONFIG_FILE" ] && echo "  - Legacy config: $LEGACY_CONFIG_FILE"
[ -f "$CLAUDE_MD" ] && echo "  - CLAUDE.md: $CLAUDE_MD"
[ -f "$LEGACY_CLAUDE_MD" ] && echo "  - Legacy CLAUDE.md: $LEGACY_CLAUDE_MD"
echo ""

read -p "Are you sure you want to uninstall? (y/N) " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Uninstalling Sentinel...${NC}"

# Stop and remove launchd services
if [ -f "$LAUNCHD_PLIST" ]; then
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST"
    echo -e "${GREEN}✓${NC} Removed LaunchAgent"
fi

if [ -f "$LEGACY_LAUNCHD_PLIST" ]; then
    launchctl unload "$LEGACY_LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_LAUNCHD_PLIST"
    echo -e "${GREEN}✓${NC} Removed legacy LaunchAgent"
fi

# Remove directories
if [ -d "$SENTINEL_DIR" ]; then
    rm -rf "$SENTINEL_DIR"
    echo -e "${GREEN}✓${NC} Removed sentinel directory"
fi

if [ -d "$LEGACY_SENTINEL_DIR" ]; then
    rm -rf "$LEGACY_SENTINEL_DIR"
    echo -e "${GREEN}✓${NC} Removed legacy sentinel directory"
fi

# Remove config files
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Removed config file"
fi

if [ -f "$LEGACY_CONFIG_FILE" ]; then
    rm -f "$LEGACY_CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Removed legacy config file"
fi

# Remove CLAUDE.md files
if [ -f "$CLAUDE_MD" ]; then
    rm -f "$CLAUDE_MD"
    echo -e "${GREEN}✓${NC} Removed CLAUDE.md"
fi

if [ -f "$LEGACY_CLAUDE_MD" ]; then
    rm -f "$LEGACY_CLAUDE_MD"
    echo -e "${GREEN}✓${NC} Removed legacy CLAUDE.md"
fi

# Remove shell aliases
for SHELL_RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$SHELL_RC" ]; then
        # Remove OpenClaw aliases
        if grep -q "# OpenClaw Sentinel aliases" "$SHELL_RC" 2>/dev/null; then
            sed -i.bak '/# OpenClaw Sentinel aliases/,/^$/d' "$SHELL_RC"
            echo -e "${GREEN}✓${NC} Removed aliases from $SHELL_RC"
        fi
        # Remove legacy Clawdbot aliases
        if grep -q "# Clawdbot Sentinel aliases" "$SHELL_RC" 2>/dev/null; then
            sed -i.bak '/# Clawdbot Sentinel aliases/,/^$/d' "$SHELL_RC"
            echo -e "${GREEN}✓${NC} Removed legacy aliases from $SHELL_RC"
        fi
    fi
done

echo ""
echo -e "${GREEN}Sentinel has been uninstalled.${NC}"
echo ""
echo "To reinstall, run: ./install.sh"
echo ""
