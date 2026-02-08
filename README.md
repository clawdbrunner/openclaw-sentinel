# OpenClaw Sentinel

![GitHub Release](https://img.shields.io/github/v/release/clawdbrunner/openclaw-sentinel?label=version)

Automated health monitoring and self-healing for [OpenClaw](https://docs.openclaw.ai/) using [Claude Code](https://claude.ai/claude-code).

Sentinel watches your OpenClaw gateway and automatically triggers Claude Code to diagnose and repair issues when they occur.

## How It Works

1. **Monitor**: Sentinel checks gateway health every 5 minutes (configurable)
2. **Detect**: If the gateway doesn't respond, runs `openclaw doctor` for diagnostics
3. **Repair**: Triggers Claude Code in headless mode with full context about the failure
4. **Verify**: Confirms the gateway is back online after repair
5. **Log**: Records all activity for debugging and audit

## Requirements

- macOS (uses launchd for scheduling)
- [OpenClaw](https://docs.openclaw.ai/) installed and configured
- [Claude Code](https://claude.ai/claude-code) installed and authenticated
- Active Claude subscription (Pro, Max, Teams, or Enterprise)

## Quick Start

```bash
git clone https://github.com/clawdbrunner/openclaw-sentinel.git
cd openclaw-sentinel
./install.sh
```

The installer will:
- Detect your OpenClaw installation
- Create configuration files
- Install and start the launchd service

## Configuration

After installation, edit `~/.openclaw/sentinel.conf`:

```bash
# Health check interval in seconds (default: 300 = 5 minutes)
CHECK_INTERVAL=300

# Maximum USD to spend per repair attempt
MAX_BUDGET_USD=2.00

# Maximum Claude Code turns per repair
MAX_TURNS=20

# Gateway URL to monitor
GATEWAY_URL="http://127.0.0.1:18789"

# Tools Claude Code can use for repairs
ALLOWED_TOOLS="Bash,Read,Edit,Glob,Grep,WebFetch"

# Seconds to wait before confirming gateway is down
CONFIRMATION_DELAY=5

# Maximum age of lock file before considering it stale (seconds)
MAX_LOCK_AGE=1800

# --- Backup ---
BACKUP_ENABLED=true
BACKUP_DIR="$HOME/.openclaw/sentinel/backups"
BACKUP_SCHEDULE_HOUR=3          # Daily backup at 03:00
BACKUP_TIER_WORKSPACE=true      # Include workspace/ in backups
BACKUP_TIER_EXTENDED=false      # Include agents/, skills, scripts
MAX_BACKUPS=14                  # Retain this many backups
BACKUP_BEFORE_UPGRADE=true      # Backup before upgrades

# --- Upgrade ---
UPGRADE_ENABLED=false           # Enable scheduled upgrade checks
UPGRADE_SCHEDULE="weekly"       # "weekly" (Sunday 04:00) or "daily"
UPGRADE_AUTO_APPLY=false        # Auto-apply updates (if false, only notifies)
```

## Notifications

Sentinel can call any notification command when repairs start, succeed, or fail.
Set `NOTIFY_CMD` in `~/.openclaw/sentinel.conf` to enable.

```bash
# Direct Telegram script example (message is appended as final arg)
NOTIFY_CMD="/path/to/send_telegram_message.sh"

# OpenClaw CLI example
NOTIFY_CMD="openclaw message send --channel telegram --target 177792366 --message"

# Notification mode: "arg" (default) or "stdin"
NOTIFY_MODE="arg"

# Per-event toggles (1=on, 0=off)
NOTIFY_ON_START=1
NOTIFY_ON_SUCCESS=1
NOTIFY_ON_FAILURE=1
```

## Usage

### Check Installed Version

```bash
# Show sentinel version and detected OpenClaw version
sentinel version
# or
sentinel --version
```

### Manual Commands

```bash
# Check current status
sentinel status

# Manually trigger a health check
sentinel check

# View recent logs
sentinel logs

# View repair history
sentinel repairs
```

### Backup Commands

```bash
# Create a backup with configured tiers
sentinel backup

# Create a full backup (all tiers)
sentinel backup --full

# List all available backups
sentinel backup list

# Restore from the most recent backup
sentinel backup restore --latest

# Restore from a specific backup
sentinel backup restore openclaw-backup-20260206-030000.tar.gz

# Remove old backups (keeps MAX_BACKUPS most recent)
sentinel backup prune
```

### Upgrade Commands

```bash
# Check for available OpenClaw updates
sentinel upgrade check

# Upgrade with automatic backup and verification
sentinel upgrade

# Force upgrade even if running latest version
sentinel upgrade --force

# Rollback to pre-upgrade backup if something went wrong
sentinel upgrade rollback
```

These commands are installed as aliases. You can also run the scripts directly:

```bash
# Trigger health check manually
~/.openclaw/sentinel/health-check.sh

# View health log
tail -f ~/.openclaw/sentinel/logs/health.log

# View repair log
tail -f ~/.openclaw/sentinel/logs/repairs.log
```

### Service Management

```bash
# Stop monitoring
launchctl unload ~/Library/LaunchAgents/ai.openclaw.sentinel.plist

# Start monitoring
launchctl load ~/Library/LaunchAgents/ai.openclaw.sentinel.plist

# Restart monitoring
launchctl unload ~/Library/LaunchAgents/ai.openclaw.sentinel.plist
launchctl load ~/Library/LaunchAgents/ai.openclaw.sentinel.plist

# Enable auto-upgrade service (disabled by default)
launchctl load ~/Library/LaunchAgents/ai.openclaw.sentinel.upgrade.plist

# Disable auto-upgrade service
launchctl unload ~/Library/LaunchAgents/ai.openclaw.sentinel.upgrade.plist
```

## Backup System

Sentinel includes an automated backup system that protects your OpenClaw configuration.

### What Gets Backed Up

Backups are organized into three tiers:

| Tier | Contents | Default |
|------|----------|---------|
| **Core** (always) | `openclaw.json`, `credentials/`, `sentinel.conf` | on |
| **Workspace** | `workspace/` (AGENTS.md, SOUL.md, memory/, etc.) | on |
| **Extended** | `agents/`, `skills/`, custom `scripts/` | off |

These are **never** backed up: `logs/`, `node_modules/`, `.git/`, lock files.

### Backup Format

- Backups are timestamped gzipped tarballs: `openclaw-backup-YYYYMMDD-HHMMSS.tar.gz`
- Stored in `~/.openclaw/sentinel/backups/` by default
- Each backup includes a `manifest.json` with metadata (timestamp, OpenClaw version, file list, config checksum)
- Backups are created with `chmod 600` (contains credentials)

### Scheduled Backups

Backups run automatically via launchd:
- Default: Daily at 03:00 (configurable via `BACKUP_SCHEDULE_HOUR`)
- Automatically prunes old backups beyond `MAX_BACKUPS`

### Restore Behavior

When restoring a backup:
1. Gateway is stopped
2. Current state is saved as a "pre-restore" backup (safety net)
3. Files are extracted and validated
4. `openclaw doctor` runs to verify configuration
5. Gateway is restarted

## Upgrade System

Sentinel provides safe, automated OpenClaw upgrades with backup protection and automatic rollback on failure.

### How Upgrades Work

1. **Check**: Compare installed version against latest (npm or Homebrew)
2. **Backup**: Create a full pre-upgrade backup (if enabled)
3. **Stop**: Gracefully stop the gateway
4. **Upgrade**: Run `npm update -g openclaw` or `brew upgrade openclaw`
5. **Verify**: Run `openclaw doctor` and check gateway starts
6. **Rollback**: Automatically restore backup if verification fails

### Manual Upgrades

```bash
# Check if updates are available
sentinel upgrade check

# Perform upgrade (with backup and verification)
sentinel upgrade

# Force upgrade even if already on latest
sentinel upgrade --force

# Rollback to pre-upgrade state
sentinel upgrade rollback
```

### Scheduled Auto-Upgrade

By default, auto-upgrade is disabled. To enable weekly upgrade checks:

1. Edit `~/.openclaw/sentinel.conf`:
   ```bash
   UPGRADE_ENABLED=true        # Enable scheduled checks
   UPGRADE_AUTO_APPLY=false    # Set to true to auto-apply updates
   ```

2. Load the upgrade service:
   ```bash
   launchctl load ~/Library/LaunchAgents/ai.openclaw.sentinel.upgrade.plist
   ```

With `UPGRADE_AUTO_APPLY=false`, the service will check for updates and log availability without applying them. Set to `true` to automatically upgrade when new versions are found.

### Upgrade Logs

Upgrade activity is logged to:
- `~/.openclaw/sentinel/logs/upgrade.log` - Upgrade operations and results
- `~/.openclaw/sentinel/logs/upgrade-stdout.log` - launchd output
- `~/.openclaw/sentinel/upgrade-history.json` - JSON history of all upgrades

## Logs

All logs are stored in `~/.openclaw/sentinel/logs/`:

| File | Contents |
|------|----------|
| `health.log` | Health check results and status changes |
| `repairs.log` | Detailed Claude Code repair session outputs |
| `backup.log` | Backup creation, restore, and prune operations |
| `upgrade.log` | Upgrade checks, installations, and rollbacks |
| `launchd-stdout.log` | Standard output from launchd (health) |
| `launchd-stderr.log` | Standard error from launchd (health) |
| `backup-stdout.log` | Standard output from launchd (backup) |
| `backup-stderr.log` | Standard error from launchd (backup) |
| `upgrade-stdout.log` | Standard output from launchd (upgrade) |
| `upgrade-stderr.log` | Standard error from launchd (upgrade) |

## How Claude Code Repairs Work

When Sentinel detects an unhealthy gateway:

1. Gathers diagnostic information:
   - Output from `openclaw doctor`
   - Running processes related to openclaw/node
   - Port 18789 status

2. Invokes Claude Code with:
   - Full diagnostic context
   - Access to `CLAUDE.md` with troubleshooting guides
   - Reference to official docs at https://docs.openclaw.ai/
   - Scoped tool permissions (Bash, Read, Edit, Glob, Grep, WebFetch)
   - Budget and turn limits for cost control

3. Claude Code autonomously:
   - Analyzes the failure
   - Identifies root cause
   - Executes repair commands
   - Verifies the fix

## Cost Control

Sentinel includes multiple safeguards:

- **Per-repair budget**: Default $2.00 max per repair attempt
- **Turn limit**: Default 20 turns max per repair
- **Lock file**: Prevents concurrent repair attempts
- **Stale lock detection**: Auto-clears locks older than 30 minutes

Typical repair costs: $0.15 - $0.70 USD

## Uninstall

```bash
cd openclaw-sentinel
./uninstall.sh
```

Or manually:

```bash
launchctl unload ~/Library/LaunchAgents/ai.openclaw.sentinel.plist
launchctl unload ~/Library/LaunchAgents/ai.openclaw.sentinel.backup.plist
launchctl unload ~/Library/LaunchAgents/ai.openclaw.sentinel.upgrade.plist
rm ~/Library/LaunchAgents/ai.openclaw.sentinel.*.plist
rm -rf ~/.openclaw/sentinel
```

## Troubleshooting

### Sentinel not running

```bash
# Check if loaded
launchctl list | grep sentinel

# Check for errors
cat ~/.openclaw/sentinel/logs/launchd-stderr.log
```

### Claude Code not authenticating

Ensure Claude Code is authenticated:

```bash
claude --version  # Should work without auth prompts
```

### Repairs not working

Check the repair log for Claude Code output:

```bash
cat ~/.openclaw/sentinel/logs/repairs.log
```

### High costs

Reduce `MAX_BUDGET_USD` and `MAX_TURNS` in `sentinel.conf`, or increase `CHECK_INTERVAL` to reduce frequency.

## Migration from Clawdbot

If you have the old `clawdbot-sentinel` installed:

```bash
# Unload old service
launchctl unload ~/Library/LaunchAgents/com.clawdbot.sentinel.plist 2>/dev/null

# Remove old plist
rm -f ~/Library/LaunchAgents/com.clawdbot.sentinel.plist

# Re-run installer for new naming
./install.sh
```

The installer will detect existing configs and migrate them.

## Releases

Sentinel uses [semantic versioning](https://semver.org/) with GitHub Releases.

### Checking Your Version

```bash
sentinel version
```

This shows both the installed Sentinel version and the detected OpenClaw version.

### Creating a Release (Maintainers)

```bash
# Bump patch version (1.0.0 -> 1.0.1)
./scripts/release.sh patch

# Bump minor version (1.0.0 -> 1.1.0)
./scripts/release.sh minor

# Bump major version (1.0.0 -> 2.0.0)
./scripts/release.sh major
```

The release script bumps the `VERSION` file, creates a git tag, and pushes to trigger the GitHub Actions release workflow. Release notes are auto-generated from commit history.

### Updating Sentinel

To update to a new release:

```bash
cd openclaw-sentinel
git pull
./install.sh
```

The installer will update all scripts and record the new version.

## Contributing

Contributions welcome! Please open an issue or PR on GitHub.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [OpenClaw](https://github.com/anthropics/openclaw) - The gateway being monitored
- [Claude Code](https://github.com/anthropics/claude-code) - AI coding assistant powering repairs
