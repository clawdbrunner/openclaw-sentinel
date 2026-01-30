#!/bin/bash
# Clawdbot Sentinel Health Check
# Monitors gateway health and triggers Claude Code for automated repair when issues are detected

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

SENTINEL_DIR="${SENTINEL_DIR:-$HOME/.clawdbot/sentinel}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.clawdbot/sentinel.conf}"

# Default values (can be overridden in sentinel.conf)
CHECK_INTERVAL=300
GATEWAY_URL="http://127.0.0.1:18789"
CONFIRMATION_DELAY=5
CURL_TIMEOUT=10
MAX_BUDGET_USD=2.00
MAX_TURNS=20
ALLOWED_TOOLS="Bash,Read,Edit,Glob,Grep,WebFetch"
MAX_LOCK_AGE=1800
LOG_DIR="$SENTINEL_DIR/logs"
LOG_RETENTION_DAYS=30

# Load user configuration if exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Ensure log directory exists
mkdir -p "$LOG_DIR"

LOCKFILE="$LOG_DIR/repair.lock"
HEALTH_LOG="$LOG_DIR/health.log"
REPAIR_LOG="$LOG_DIR/repairs.log"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$HEALTH_LOG"
}

log_repair() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$REPAIR_LOG"
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
            log "Removing stale lock file (age: ${LOCK_AGE}s)"
            rm -f "$LOCKFILE"
            return 1
        else
            log "Repair already in progress (lock age: ${LOCK_AGE}s), skipping"
            return 0
        fi
    fi
    return 1
}

acquire_lock() {
    touch "$LOCKFILE"
}

release_lock() {
    rm -f "$LOCKFILE"
}

# =============================================================================
# HEALTH CHECK
# =============================================================================

check_gateway() {
    if curl -s --max-time "$CURL_TIMEOUT" "$GATEWAY_URL" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# =============================================================================
# AUTO-FIX: COMMON ISSUES
# =============================================================================

# Attempt to fix common issues without invoking Claude Code
# Returns 0 if issue was fixed, 1 if Claude Code is needed
try_auto_fix() {
    local doctor_output="$1"

    # Check for missing env var in config
    if echo "$doctor_output" | grep -q "MissingEnvVarError"; then
        local var_name
        var_name=$(echo "$doctor_output" | grep -o 'Missing env var "[^"]*"' | head -1 | sed 's/Missing env var "\([^"]*\)"/\1/')
        local config_path
        config_path=$(echo "$doctor_output" | grep -o 'config path: [^ ]*' | head -1 | sed 's/config path: //')

        if [ -n "$var_name" ] && [ -n "$config_path" ]; then
            log "Auto-fix: Detected missing env var '$var_name' at '$config_path'"

            # Check if the value exists in env.vars section of config
            local config_file="$HOME/.clawdbot/clawdbot.json"
            if [ -f "$config_file" ]; then
                local stored_value
                stored_value=$(jq -r --arg var "$var_name" '.env.vars[$var] // empty' "$config_file" 2>/dev/null)

                if [ -n "$stored_value" ]; then
                    log "Auto-fix: Found value in env.vars, replacing \${$var_name} reference with actual value"

                    # Create backup
                    cp "$config_file" "$config_file.bak.$(date +%s)"

                    # Replace the ${VAR_NAME} reference with the actual value
                    # Use jq to safely handle the replacement
                    local tmp_file
                    tmp_file=$(mktemp)

                    # Build jq path from config_path (e.g., "models.providers.moonshot.apiKey")
                    # Convert dot notation to jq path
                    local jq_path
                    jq_path=$(echo "$config_path" | sed 's/\./]["/g' | sed 's/^/["/;s/$/"]/')

                    if jq --arg val "$stored_value" "setpath($jq_path; \$val)" "$config_file" > "$tmp_file" 2>/dev/null; then
                        mv "$tmp_file" "$config_file"
                        log "Auto-fix: Successfully replaced env var reference with actual value"
                        log_repair "Auto-fix applied: Replaced \${$var_name} at $config_path with stored value from env.vars"

                        # Restart gateway
                        log "Auto-fix: Restarting gateway..."
                        if launchctl kickstart -k "gui/$(id -u)/com.clawdbot.gateway" 2>/dev/null; then
                            log "Auto-fix: Gateway restart triggered via launchctl"
                        else
                            # Fallback: try starting gateway directly
                            pkill -f "clawdbot gateway" 2>/dev/null || true
                            sleep 1
                            nohup clawdbot gateway > /dev/null 2>&1 &
                            log "Auto-fix: Gateway started directly"
                        fi

                        sleep 3
                        return 0
                    else
                        rm -f "$tmp_file"
                        log "Auto-fix: jq replacement failed, falling back to Claude Code"
                    fi
                else
                    log "Auto-fix: Env var '$var_name' not found in env.vars, need Claude Code"
                fi
            fi
        fi
    fi

    # Check for simple "gateway not running" case
    if echo "$doctor_output" | grep -qi "gateway.*stopped\|gateway.*not running\|ECONNREFUSED"; then
        if ! echo "$doctor_output" | grep -qi "config invalid\|error\|MissingEnvVar"; then
            log "Auto-fix: Gateway appears to just need a restart"

            if launchctl kickstart -k "gui/$(id -u)/com.clawdbot.gateway" 2>/dev/null; then
                log "Auto-fix: Gateway restart triggered via launchctl"
                sleep 3
                return 0
            fi
        fi
    fi

    return 1
}

# =============================================================================
# REPAIR
# =============================================================================

trigger_repair() {
    local doctor_output="$1"
    local doctor_exit="$2"

    # First, try auto-fix for common issues
    if try_auto_fix "$doctor_output"; then
        log "Auto-fix succeeded, verifying gateway..."
        if check_gateway; then
            log "Gateway is responsive after auto-fix"
            return 0
        fi
        log "Auto-fix applied but gateway still not responsive, invoking Claude Code"
    fi

    log "Triggering Claude Code repair..."
    log_repair "=== Repair attempt started ==="

    # Gather additional diagnostic information
    local process_state
    process_state=$(ps aux | grep -E "(clawdbot|node)" | grep -v grep | head -20 || echo "No clawdbot/node processes found")

    local port_state
    port_state=$(lsof -i :18789 2>/dev/null | head -10 || echo "No process on port 18789")

    # Truncate doctor output to avoid "argument list too long" errors
    # Keep first 100 lines and last 50 lines if too long
    local doctor_lines
    doctor_lines=$(echo "$doctor_output" | wc -l)
    if [ "$doctor_lines" -gt 200 ]; then
        local doctor_head
        local doctor_tail
        doctor_head=$(echo "$doctor_output" | head -100)
        doctor_tail=$(echo "$doctor_output" | tail -50)
        doctor_output="$doctor_head

... [truncated ${doctor_lines} lines total] ...

$doctor_tail"
    fi

    # Change to clawdbot directory for context
    cd "$HOME/.clawdbot"

    # Build Claude Code command
    local claude_cmd="claude"
    if [ -n "${CLAUDE_BIN:-}" ]; then
        claude_cmd="$CLAUDE_BIN"
    fi

    # Build optional arguments
    local model_arg=""
    if [ -n "${MODEL:-}" ]; then
        model_arg="--model $MODEL"
    fi

    # Write prompt to temp file to avoid "argument list too long" error
    local prompt_file
    prompt_file=$(mktemp)

    cat > "$prompt_file" << PROMPT_EOF
The Clawdbot gateway is not responding and needs repair.

## Diagnostic Information

### clawdbot doctor output (exit code: $doctor_exit):
\`\`\`
$doctor_output
\`\`\`

### Related processes:
\`\`\`
$process_state
\`\`\`

### Port 18789 status:
\`\`\`
$port_state
\`\`\`

## Your Task
1. Diagnose the root cause of the gateway failure
2. Fix the issue (restart gateway, fix config, clear port conflict, etc.)
3. Verify the gateway is running and responsive
4. If the fix doesn't work, try alternative approaches

Common fixes:
- Restart: \`clawdbot gateway\` (may need to run in background or via launchd)
- Kill stuck process: \`pkill -f clawdbot\` then restart
- Check config: \`~/.clawdbot/clawdbot.json\`
- Reinstall service: \`clawdbot onboard --install-daemon\`
- If env var missing: check if value exists in config env.vars and inline it

Consult https://docs.clawd.bot/ for additional troubleshooting guidance if needed.
PROMPT_EOF

    # Invoke Claude Code using stdin for the prompt
    local repair_output
    repair_output=$($claude_cmd -p "$(cat "$prompt_file")" \
        --allowedTools "$ALLOWED_TOOLS" \
        --max-turns "$MAX_TURNS" \
        --max-budget-usd "$MAX_BUDGET_USD" \
        --output-format json \
        $model_arg \
        2>&1) || true

    local repair_exit=$?

    # Clean up temp file
    rm -f "$prompt_file"

    # Log the repair attempt
    log_repair "Exit code: $repair_exit"
    log_repair "$repair_output"
    log_repair "=== Repair attempt ended ==="
    log_repair ""

    return $repair_exit
}

# =============================================================================
# LOG ROTATION
# =============================================================================

rotate_logs() {
    if [ "$LOG_RETENTION_DAYS" -gt 0 ]; then
        find "$LOG_DIR" -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Rotate old logs periodically
    rotate_logs

    # Check for existing repair in progress
    if check_lock; then
        exit 0
    fi

    # Initial health check
    if check_gateway; then
        log "Gateway healthy"
        exit 0
    fi

    # Gateway didn't respond - run deeper diagnostics
    log "Gateway not responding, running diagnostics..."

    local doctor_output
    doctor_output=$(clawdbot doctor 2>&1) || true
    local doctor_exit=$?

    # Wait and recheck to avoid false positives
    sleep "$CONFIRMATION_DELAY"

    if check_gateway; then
        log "Gateway recovered after brief delay"
        exit 0
    fi

    # Gateway is confirmed down - trigger repair
    log "Gateway confirmed unhealthy (doctor exit: $doctor_exit). Triggering Claude Code repair..."

    # Acquire lock
    acquire_lock

    # Attempt repair
    trigger_repair "$doctor_output" "$doctor_exit"

    # Release lock
    release_lock

    # Verify repair success
    sleep "$CONFIRMATION_DELAY"

    if check_gateway; then
        log "Repair successful - gateway is now responding"
    else
        log "Repair attempt completed but gateway still not responding"
    fi
}

# Run main function
main "$@"
