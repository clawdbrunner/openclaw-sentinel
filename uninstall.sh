#!/bin/bash
# Clawdbot Sentinel Uninstaller
# Removes Sentinel and all associated files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SENTINEL_DIR="$HOME/.clawdbot/sentinel"
CONFIG_FILE="$HOME/.clawdbot/sentinel.conf"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.clawdbot.sentinel.plist"
CLAUDE_MD="$HOME/.clawdbot/CLAUDE.md"

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                  Clawdbot Sentinel Uninstaller                ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Confirm uninstall
echo "This will remove:"
echo "  - Sentinel service (launchd)"
echo "  - Health check scripts"
echo "  - Configuration file"
echo "  - Log files"
echo ""
read -p "Are you sure you want to uninstall Sentinel? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}Uninstalling Sentinel...${NC}"

# Stop and unload launchd service
if [ -f "$LAUNCHD_PLIST" ]; then
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST"
    echo -e "${GREEN}✓${NC} Removed launchd service"
else
    echo -e "${YELLOW}!${NC} launchd service not found"
fi

# Remove sentinel directory
if [ -d "$SENTINEL_DIR" ]; then
    rm -rf "$SENTINEL_DIR"
    echo -e "${GREEN}✓${NC} Removed sentinel directory"
else
    echo -e "${YELLOW}!${NC} Sentinel directory not found"
fi

# Remove config file
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}✓${NC} Removed configuration file"
else
    echo -e "${YELLOW}!${NC} Configuration file not found"
fi

# Ask about CLAUDE.md
if [ -f "$CLAUDE_MD" ]; then
    read -p "Remove CLAUDE.md context file? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$CLAUDE_MD"
        echo -e "${GREEN}✓${NC} Removed CLAUDE.md"
    else
        echo -e "${YELLOW}!${NC} Kept CLAUDE.md"
    fi
fi

# Remove shell aliases
echo ""
read -p "Remove 'sentinel' aliases from shell config? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    for rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$rc_file" ]; then
            # Create backup
            cp "$rc_file" "${rc_file}.bak"
            # Remove sentinel section (between marker and closing brace)
            sed -i '' '/# Clawdbot Sentinel aliases/,/^}/d' "$rc_file" 2>/dev/null || true
            echo -e "${GREEN}✓${NC} Cleaned $rc_file (backup: ${rc_file}.bak)"
        fi
    done
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║             Sentinel uninstalled successfully!                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Note: Your Clawdbot installation is unchanged."
echo "To reinstall Sentinel later, run: ./install.sh"
echo ""
