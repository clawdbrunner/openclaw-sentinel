# Clawdbot Repair Context

This file provides context for Claude Code when performing automated repairs on the Clawdbot gateway.

## Documentation

For the latest troubleshooting guides, commands, and configuration options:
- Official docs: https://docs.clawd.bot/

When diagnosing issues, fetch the relevant documentation pages if needed.

## System Overview

This is a Clawdbot installation monitored by Sentinel.

| Component | Location |
|-----------|----------|
| Gateway WebSocket | ws://127.0.0.1:18789 |
| Dashboard | http://127.0.0.1:18789/ |
| Config file | ~/.clawdbot/clawdbot.json |
| State directory | ~/.clawdbot/ |
| Sentinel logs | ~/.clawdbot/sentinel/logs/ |

## Architecture

Clawdbot uses a Gateway-centric model:
- **Gateway**: Single long-running process that owns channel connections and WebSocket control plane
- **Nodes**: iOS/Android devices connect via WebSocket pairing
- **Canvas host**: HTTP file server on port 18793
- **Agents**: Pi via RPC, CLI, Chat UI

## CLI Commands

| Command | Description |
|---------|-------------|
| `clawdbot gateway` | Start the Gateway process |
| `clawdbot doctor` | Diagnose issues and update service entrypoint |
| `clawdbot onboard --install-daemon` | Install/reinstall launchd service |
| `clawdbot channels login` | Pair WhatsApp Web |
| `clawdbot message send --target [number] --message "[text]"` | Send test message |

## Common Issues & Fixes

### 1. Gateway Process Crashed
**Symptoms**: Dashboard unreachable, WebSocket connections fail
**Fix**:
```bash
# Check if process exists
pgrep -f clawdbot

# If not running, restart
clawdbot gateway
```

### 2. Port 18789 Already in Use
**Symptoms**: Gateway fails to start with EADDRINUSE
**Fix**:
```bash
# Find what's using the port
lsof -i :18789

# Kill the process if it's a zombie clawdbot
pkill -f clawdbot
sleep 2
clawdbot gateway
```

### 3. Configuration Corruption
**Symptoms**: Gateway crashes on startup, JSON parse errors
**Fix**:
- Check `~/.clawdbot/clawdbot.json` for valid JSON syntax
- Look for truncated files, missing braces, invalid characters
- If unrecoverable, check if there's a backup or reset to defaults

### 4. Node.js Issues
**Symptoms**: Clawdbot commands fail with Node errors
**Requirements**: Node >= 22
**Fix**:
```bash
node --version  # Should be >= 22
# If wrong version, may need nvm or reinstall
```

### 5. Service Not Starting on Boot
**Fix**:
```bash
clawdbot onboard --install-daemon
```

### 6. launchd Service Unloaded
**Symptoms**: Gateway doesn't auto-restart after crash
**Fix**:
```bash
# Check if service exists
launchctl list | grep clawdbot.gateway

# If not listed, reinstall
clawdbot onboard --install-daemon

# Or manually load if plist exists
launchctl load ~/Library/LaunchAgents/com.clawdbot.gateway.plist
```

## Logs & Debugging

```bash
# System logs for clawdbot
log show --predicate 'process == "clawdbot"' --last 1h

# Sentinel logs
tail -f ~/.clawdbot/sentinel/logs/health.log
tail -f ~/.clawdbot/sentinel/logs/repairs.log

# Check launchd service status
launchctl list | grep clawdbot
```

## Environment Variables

For multi-instance setups:
- `CLAWDBOT_CONFIG_PATH` - Custom config file location
- `CLAWDBOT_STATE_DIR` - Custom state directory

## Post-Repair Verification

After any repair, verify:
1. Gateway responds: `curl -s http://127.0.0.1:18789`
2. Dashboard accessible in browser: http://127.0.0.1:18789/
3. Run diagnostics: `clawdbot doctor`

## Repair Guidelines

When repairing:
1. **Prefer restarting over reinstalling** - Most issues are solved by restarting the gateway
2. **Check logs first** - System logs often reveal the root cause
3. **Avoid destructive actions** - Don't delete config files unless clearly corrupted
4. **Verify after fixing** - Always confirm the gateway responds after repair
5. **Document unusual issues** - If you encounter something not listed here, note it in the repair log
