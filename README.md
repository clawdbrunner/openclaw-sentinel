# Clawdbot Sentinel

Automated health monitoring and self-healing for [Clawdbot](https://docs.clawd.bot/) using [Claude Code](https://claude.ai/claude-code).

Sentinel watches your Clawdbot gateway and automatically triggers Claude Code to diagnose and repair issues when they occur.

## How It Works

1. **Monitor**: Sentinel checks gateway health every 5 minutes (configurable)
2. **Detect**: If the gateway doesn't respond, runs `clawdbot doctor` for diagnostics
3. **Repair**: Triggers Claude Code in headless mode with full context about the failure
4. **Verify**: Confirms the gateway is back online after repair
5. **Log**: Records all activity for debugging and audit

## Requirements

- macOS (uses launchd for scheduling)
- [Clawdbot](https://docs.clawd.bot/) installed and configured
- [Claude Code](https://claude.ai/claude-code) installed and authenticated
- Active Claude subscription (Pro, Max, Teams, or Enterprise)

## Quick Start

```bash
git clone https://github.com/anthropics/clawdbot-sentinel.git
cd clawdbot-sentinel
./install.sh
```

The installer will:
- Detect your Clawdbot installation
- Create configuration files
- Install and start the launchd service

## Configuration

After installation, edit `~/.clawdbot/sentinel.conf`:

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
```

## Usage

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

These commands are installed as aliases. You can also run the scripts directly:

```bash
# Trigger health check manually
~/.clawdbot/sentinel/health-check.sh

# View health log
tail -f ~/.clawdbot/sentinel/logs/health.log

# View repair log
tail -f ~/.clawdbot/sentinel/logs/repairs.log
```

### Service Management

```bash
# Stop monitoring
launchctl unload ~/Library/LaunchAgents/com.clawdbot.sentinel.plist

# Start monitoring
launchctl load ~/Library/LaunchAgents/com.clawdbot.sentinel.plist

# Restart monitoring
launchctl unload ~/Library/LaunchAgents/com.clawdbot.sentinel.plist
launchctl load ~/Library/LaunchAgents/com.clawdbot.sentinel.plist
```

## Logs

All logs are stored in `~/.clawdbot/sentinel/logs/`:

| File | Contents |
|------|----------|
| `health.log` | Health check results and status changes |
| `repairs.log` | Detailed Claude Code repair session outputs |
| `launchd-stdout.log` | Standard output from launchd |
| `launchd-stderr.log` | Standard error from launchd |

## How Claude Code Repairs Work

When Sentinel detects an unhealthy gateway:

1. Gathers diagnostic information:
   - Output from `clawdbot doctor`
   - Running processes related to clawdbot/node
   - Port 18789 status

2. Invokes Claude Code with:
   - Full diagnostic context
   - Access to `CLAUDE.md` with troubleshooting guides
   - Reference to official docs at https://docs.clawd.bot/
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

Typical repair costs: $0.15 - $0.30 USD

## Uninstall

```bash
cd clawdbot-sentinel
./uninstall.sh
```

Or manually:

```bash
launchctl unload ~/Library/LaunchAgents/com.clawdbot.sentinel.plist
rm ~/Library/LaunchAgents/com.clawdbot.sentinel.plist
rm -rf ~/.clawdbot/sentinel
```

## Troubleshooting

### Sentinel not running

```bash
# Check if loaded
launchctl list | grep sentinel

# Check for errors
cat ~/.clawdbot/sentinel/logs/launchd-stderr.log
```

### Claude Code not authenticating

Ensure Claude Code is authenticated:

```bash
claude --version  # Should work without auth prompts
```

### Repairs not working

Check the repair log for Claude Code output:

```bash
cat ~/.clawdbot/sentinel/logs/repairs.log
```

### High costs

Reduce `MAX_BUDGET_USD` and `MAX_TURNS` in `sentinel.conf`, or increase `CHECK_INTERVAL` to reduce frequency.

## Contributing

Contributions welcome! Please open an issue or PR on GitHub.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [Clawdbot](https://github.com/anthropics/clawdbot) - The gateway being monitored
- [Claude Code](https://github.com/anthropics/claude-code) - AI coding assistant powering repairs
