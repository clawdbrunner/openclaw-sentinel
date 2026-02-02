# OpenClaw Repair Context

This file provides context for Claude Code when performing automated repairs on the OpenClaw gateway.

## Documentation

For the latest troubleshooting guides, commands, and configuration options:
- Official docs: https://docs.openclaw.ai/

When diagnosing issues, fetch the relevant documentation pages if needed.

## System Overview

This is an OpenClaw installation monitored by Sentinel.

| Component | Location |
|-----------|----------|
| Gateway WebSocket | ws://127.0.0.1:18789 |
| Dashboard | http://127.0.0.1:18789/ |
| Config file | ~/.openclaw/openclaw.json |
| State directory | ~/.openclaw/ |
| Sentinel logs | ~/.openclaw/sentinel/logs/ |

### Legacy Paths (pre-2026.1.29)

OpenClaw was rebranded from "Clawdbot" in January 2026. Legacy paths may exist:

| Legacy | New |
|--------|-----|
| ~/.clawdbot/ | ~/.openclaw/ (symlinked) |
| ~/.clawdbot/clawdbot.json | ~/.openclaw/openclaw.json |
| com.clawdbot.gateway | ai.openclaw.gateway |

The `clawdbot` CLI still works via compatibility shim.

## Architecture

OpenClaw uses a Gateway-centric model:
- **Gateway**: Single long-running process that owns channel connections and WebSocket control plane
- **Nodes**: iOS/Android devices connect via WebSocket pairing
- **Canvas host**: HTTP file server on port 18793
- **Agents**: Pi via RPC, CLI, Chat UI

## CLI Commands

| Command | Description |
|---------|-------------|
| `openclaw gateway` | Start the Gateway process |
| `openclaw gateway status` | Check gateway status |
| `openclaw gateway install` | Install/reinstall launchd service |
| `openclaw doctor` | Diagnose issues and update service entrypoint |
| `openclaw status` | Full system status |
| `openclaw channels login` | Pair WhatsApp Web |
| `openclaw message send --target [number] --message "[text]"` | Send test message |

Note: `clawdbot` commands also work (compatibility shim).

## Common Issues & Fixes

### 1. Gateway Process Crashed
**Symptoms**: Dashboard unreachable, WebSocket connections fail
**Fix**:
```bash
# Check if process exists
pgrep -f 'openclaw\|clawdbot'

# If not running, restart
openclaw gateway
```

### 2. Port 18789 Already in Use
**Symptoms**: Gateway fails to start with EADDRINUSE
**Fix**:
```bash
# Find what's using the port
lsof -i :18789

# Kill the process if it's a zombie openclaw/clawdbot
pkill -f 'openclaw\|clawdbot'
sleep 2
openclaw gateway
```

### 3. Configuration Corruption
**Symptoms**: Gateway crashes on startup, JSON parse errors
**Fix**:
- Check `~/.openclaw/openclaw.json` for valid JSON syntax
- Also check legacy `~/.clawdbot/clawdbot.json` if symlinked
- Look for truncated files, missing braces, invalid characters
- If unrecoverable, check if there's a backup or reset to defaults

### 4. Node.js Issues
**Symptoms**: OpenClaw commands fail with Node errors
**Requirements**: Node >= 22
**Fix**:
```bash
node --version  # Should be >= 22
# If wrong version, may need nvm or reinstall
```

### 5. Service Not Starting on Boot
**Fix**:
```bash
openclaw gateway install
```

### 6. launchd Service Unloaded
**Symptoms**: Gateway doesn't auto-restart after crash
**Fix**:
```bash
# Check if service exists (try both new and legacy names)
launchctl list | grep -E 'openclaw|clawdbot'

# If not listed, reinstall
openclaw gateway install

# Or manually load if plist exists
launchctl load ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

### 7. Package Migration Issues
**Symptoms**: Commands not found after npm update
**Context**: Package renamed from `clawdbot` to `openclaw` in v2026.1.29
**Fix**:
```bash
# Check which package is installed
npm list -g clawdbot openclaw 2>/dev/null

# If old package, migrate:
npm uninstall -g clawdbot
npm install -g openclaw

# Reinstall service after migration
openclaw gateway install
```

## Logs & Debugging

```bash
# Gateway logs
tail -f ~/.openclaw/logs/gateway.log

# System logs for openclaw
log show --predicate 'process CONTAINS "openclaw" OR process CONTAINS "clawdbot"' --last 1h

# Sentinel logs
tail -f ~/.openclaw/sentinel/logs/health.log
tail -f ~/.openclaw/sentinel/logs/repairs.log

# Check launchd service status
launchctl list | grep -E 'openclaw|clawdbot'
```

## Environment Variables

For multi-instance setups:
- `OPENCLAW_CONFIG_PATH` - Custom config file location
- `OPENCLAW_STATE_DIR` - Custom state directory

Legacy variables also supported:
- `CLAWDBOT_CONFIG_PATH`
- `CLAWDBOT_STATE_DIR`

## Post-Repair Verification

After any repair, verify:
1. Gateway responds: `curl -s http://127.0.0.1:18789`
2. Dashboard accessible in browser: http://127.0.0.1:18789/
3. Run diagnostics: `openclaw doctor`
4. Check status: `openclaw status`

## Repair Guidelines

When repairing:
1. **Prefer restarting over reinstalling** - Most issues are solved by restarting the gateway
2. **Check logs first** - System logs often reveal the root cause
3. **Avoid destructive actions** - Don't delete config files unless clearly corrupted
4. **Verify after fixing** - Always confirm the gateway responds after repair
5. **Document unusual issues** - If you encounter something not listed here, note it in the repair log
6. **Handle the rebrand** - Be aware that paths/commands may use either `openclaw` or `clawdbot` naming
