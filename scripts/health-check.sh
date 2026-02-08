#!/bin/bash
# OpenClaw Sentinel Health Check
# Monitors gateway health and triggers Claude Code for automated repair when issues are detected

set -euo pipefail

# Ensure PATH includes Homebrew and user bins (critical for launchd/cron)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.npm/bin:$PATH"


# =============================================================================
# CONFIGURATION
# =============================================================================

SENTINEL_DIR="${SENTINEL_DIR:-$HOME/.openclaw/sentinel}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.openclaw/sentinel.conf}"

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
NOTIFY_CMD=""
NOTIFY_MODE="arg"
NOTIFY_ON_START=1
NOTIFY_ON_SUCCESS=1
NOTIFY_ON_FAILURE=1

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
REPAIR_HISTORY="$LOG_DIR/repair-history.json"

# Notification state
LAST_ISSUE_FP=""
LAST_REPAIR_ID=""
LAST_REPAIR_TYPE=""
LAST_REPAIR_EXIT=""
LAST_REPAIR_SUCCESS=""
LAST_REPAIR_COST=""
LAST_REPAIR_TURNS=""
LAST_REPAIR_RESOLUTION=""

# Detect which CLI to use (openclaw preferred, clawdbot as fallback)
if command -v openclaw &> /dev/null; then
    OPENCLAW_CMD="openclaw"
elif command -v clawdbot &> /dev/null; then
    OPENCLAW_CMD="clawdbot"
else
    echo "Error: Neither openclaw nor clawdbot found in PATH" >&2
    exit 1
fi

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
# NOTIFICATIONS
# =============================================================================

notify_send() {
    local message="$1"
    local mode="${NOTIFY_MODE:-arg}"
    mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]')

    if [ -z "${NOTIFY_CMD:-}" ]; then
        return 0
    fi

    local rc=0
    set +e
    if [ "$mode" = "stdin" ]; then
        printf '%s' "$message" | bash -c "$NOTIFY_CMD"
        rc=$?
    else
        # Default: append message as final argument
        bash -c "$NOTIFY_CMD \"\$1\"" -- "$message"
        rc=$?
    fi
    set -e

    if [ $rc -ne 0 ]; then
        log "Notify failed (rc=$rc, mode=$mode)"
    fi

    return 0
}

is_enabled() {
    case "${1:-1}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        0|false|FALSE|no|NO|off|OFF|"")
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

notify_event() {
    local kind="$1"
    local message="$2"

    case "$kind" in
        start)
            is_enabled "${NOTIFY_ON_START:-1}" || return 0
            ;;
        success)
            is_enabled "${NOTIFY_ON_SUCCESS:-1}" || return 0
            ;;
        failure)
            is_enabled "${NOTIFY_ON_FAILURE:-1}" || return 0
            ;;
        *)
            return 0
            ;;
    esac

    notify_send "$message"
}

# =============================================================================
# REPAIR TRACKING
# =============================================================================

# Generate a fingerprint for an issue based on doctor output
# This helps identify recurring issues even if details differ slightly
generate_issue_fingerprint() {
    local doctor_output="$1"
    local doctor_exit="$2"
    
    # Extract key error patterns to create a fingerprint
    local fingerprint=""
    
    # Check for specific error patterns in order of specificity
    if echo "$doctor_output" | grep -q "MissingEnvVarError"; then
        local var_name
        var_name=$(echo "$doctor_output" | grep -o 'Missing env var "[^"]*"' | head -1 | sed 's/Missing env var "\([^"]*\)"/\1/')
        fingerprint="missing_env_var:${var_name:-unknown}"
    elif echo "$doctor_output" | grep -q "ECONNREFUSED\|Connection refused"; then
        fingerprint="connection_refused"
    elif echo "$doctor_output" | grep -q "gateway.*not running\|gateway.*stopped"; then
        fingerprint="gateway_not_running"
    elif echo "$doctor_output" | grep -q "invalid_auth\|invalid_auth_error"; then
        fingerprint="invalid_auth"
    elif echo "$doctor_output" | grep -q "config invalid\|configuration error"; then
        fingerprint="config_invalid"
    elif echo "$doctor_output" | grep -q "port.*in use\|EADDRINUSE"; then
        fingerprint="port_conflict"
    elif [ "$doctor_exit" -ne 0 ]; then
        fingerprint="doctor_exit_${doctor_exit}"
    else
        fingerprint="gateway_unhealthy"
    fi
    
    echo "$fingerprint"
}

# Record repair attempt start
record_repair_start() {
    local issue_fingerprint="$1"
    local doctor_exit="$2"
    local is_auto_fix="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    local epoch
    epoch=$(date +%s)
    
    # Create repair record
    local record
    record=$(cat << EOF
{
  "id": "${epoch}-${issue_fingerprint}",
  "timestamp": "$timestamp",
  "epoch": $epoch,
  "issue_fingerprint": "$issue_fingerprint",
  "doctor_exit_code": $doctor_exit,
  "repair_type": "$is_auto_fix",
  "status": "started"
}
EOF
)
    
    # Append to history file (create if doesn't exist)
    if [ ! -f "$REPAIR_HISTORY" ]; then
        echo "[$record]" > "$REPAIR_HISTORY"
    else
        # Use jq to append if available, otherwise simple append
        if command -v jq &> /dev/null; then
            jq ". + [$record]" "$REPAIR_HISTORY" > "$REPAIR_HISTORY.tmp" && mv "$REPAIR_HISTORY.tmp" "$REPAIR_HISTORY"
        else
            # Fallback: append with manual JSON manipulation
            local temp_file
            temp_file=$(mktemp)
            # Remove trailing ] and add comma + new record + ]
            sed '$ s/\]$/,/' "$REPAIR_HISTORY" > "$temp_file"
            echo "$record]" >> "$temp_file"
            mv "$temp_file" "$REPAIR_HISTORY"
        fi
    fi
    
    log "Repair tracking: recorded start for issue '$issue_fingerprint'"
    echo "$epoch-$issue_fingerprint"
}

# Record repair completion
record_repair_complete() {
    local repair_id="$1"
    local success="$2"
    local cost_usd="$3"
    local resolution="$4"
    local num_turns="$5"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    local epoch
    epoch=$(date +%s)
    
    # Calculate duration if we can find the start time
    local start_epoch
    start_epoch=$(echo "$repair_id" | cut -d'-' -f1)
    local duration=$((epoch - start_epoch))
    
    if [ -f "$REPAIR_HISTORY" ] && command -v jq &> /dev/null; then
        # Update the existing record
        jq --arg id "$repair_id" \
           --arg status "$success" \
           --arg cost "$cost_usd" \
           --arg resolution "$resolution" \
           --argjson turns "${num_turns:-null}" \
           --argjson duration "$duration" \
           --arg completed "$timestamp" \
           'map(if .id == $id then . + {
             status: $status,
             completed_at: $completed,
             duration_seconds: $duration,
             cost_usd: ($cost | tonumber? // 0),
             num_turns: $turns,
             resolution: $resolution
           } else . end)' \
           "$REPAIR_HISTORY" > "$REPAIR_HISTORY.tmp" && mv "$REPAIR_HISTORY.tmp" "$REPAIR_HISTORY"
    fi
    
    log "Repair tracking: recorded completion (success=$success, cost=$cost_usd, duration=${duration}s)"
}

# Get recent repair count for an issue fingerprint (last N minutes)
get_recent_repair_count() {
    local fingerprint="$1"
    local minutes="${2:-30}"
    local cutoff
    cutoff=$(($(date +%s) - minutes * 60))
    
    if [ -f "$REPAIR_HISTORY" ] && command -v jq &> /dev/null; then
        jq --arg fp "$fingerprint" --argjson cutoff "$cutoff" \
           '[.[] | select(.issue_fingerprint == $fp and .epoch >= $cutoff)] | length' \
           "$REPAIR_HISTORY" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Get repair statistics summary
get_repair_stats() {
    if [ -f "$REPAIR_HISTORY" ] && command -v jq &> /dev/null; then
        local total
        local successful
        local failed
        local total_cost
        
        total=$(jq 'length' "$REPAIR_HISTORY" 2>/dev/null || echo "0")
        successful=$(jq '[.[] | select(.status == "success")] | length' "$REPAIR_HISTORY" 2>/dev/null || echo "0")
        failed=$(jq '[.[] | select(.status == "failed")] | length' "$REPAIR_HISTORY" 2>/dev/null || echo "0")
        total_cost=$(jq '[.[] | .cost_usd // 0] | add' "$REPAIR_HISTORY" 2>/dev/null || echo "0")
        
        echo "Total repairs: $total | Successful: $successful | Failed: $failed | Total cost: \$$(printf "%.2f" "$total_cost")"
    else
        echo "No repair history available"
    fi
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
            local config_file="$HOME/.openclaw/openclaw.json"
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
                        if launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null; then
                            log "Auto-fix: Gateway restart triggered via launchctl"
                        else
                            # Fallback: try starting gateway directly
                            pkill -f 'openclaw gateway\|clawdbot gateway' 2>/dev/null || true
                            sleep 1
                            nohup $OPENCLAW_CMD gateway > /dev/null 2>&1 &
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

            if launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null; then
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

    # Generate issue fingerprint for tracking
    local issue_fingerprint
    issue_fingerprint=$(generate_issue_fingerprint "$doctor_output" "$doctor_exit")
    LAST_ISSUE_FP="$issue_fingerprint"
    log "Issue fingerprint: $issue_fingerprint"
    notify_event "start" "🟡 OpenClaw Sentinel: repair started on $(hostname). Issue=${LAST_ISSUE_FP}. Doctor exit=${doctor_exit}. Gateway=${GATEWAY_URL}."

    # First, try auto-fix for common issues
    if try_auto_fix "$doctor_output"; then
        log "Auto-fix succeeded, verifying gateway..."
        # Track auto-fix success
        LAST_REPAIR_TYPE="auto_fix"
        LAST_REPAIR_EXIT="0"
        LAST_REPAIR_ID=$(record_repair_start "$issue_fingerprint" "$doctor_exit" "auto_fix")
        if check_gateway; then
            log "Gateway is responsive after auto-fix"
            # Record completion for auto-fix
            if [ -f "$REPAIR_HISTORY" ] && command -v jq &> /dev/null; then
                record_repair_complete "$LAST_REPAIR_ID" "success" "0" "auto_fix_applied" "null"
            fi
            LAST_REPAIR_SUCCESS="success"
            LAST_REPAIR_COST="0"
            LAST_REPAIR_TURNS="null"
            LAST_REPAIR_RESOLUTION="auto_fix_applied"
            return 0
        fi
        log "Auto-fix applied but gateway still not responsive, invoking Claude Code"
    fi

    # Track this repair attempt
    local repair_id
    repair_id=$(record_repair_start "$issue_fingerprint" "$doctor_exit" "claude_code")
    LAST_REPAIR_ID="$repair_id"
    LAST_REPAIR_TYPE="claude_code"
    
    log "Triggering Claude Code repair (ID: $repair_id)..."
    log_repair "=== Repair attempt started ($repair_id) ==="
    log_repair "Issue fingerprint: $issue_fingerprint"

    # Gather additional diagnostic information
    local process_state
    process_state=$(ps aux | grep -E "(openclaw|clawdbot|node)" | grep -v grep | head -20 || echo "No openclaw/clawdbot/node processes found")

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

    # Change to openclaw directory for context
    cd "$HOME/.openclaw"

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
The OpenClaw gateway is not responding and needs repair.

## Diagnostic Information

### $OPENCLAW_CMD doctor output (exit code: $doctor_exit):
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
- Restart: \`$OPENCLAW_CMD gateway\` (may need to run in background or via launchd)
- Kill stuck process: \`pkill -f 'openclaw\|clawdbot'\` then restart
- Check config: \`~/.openclaw/openclaw.json\` (or legacy \`~/.clawdbot/clawdbot.json\`)
- Reinstall service: \`$OPENCLAW_CMD gateway install\`
- If env var missing: check if value exists in config env.vars and inline it

Note: The CLI was rebranded from 'clawdbot' to 'openclaw' in January 2026.
- Config moved: ~/.clawdbot/ → ~/.openclaw/ (symlinked for compatibility)
- Both CLI names work, but 'openclaw' is preferred

Consult https://docs.openclaw.ai/ for additional troubleshooting guidance if needed.
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
    LAST_REPAIR_EXIT="$repair_exit"

    # Extract key data from repair output for tracking
    local repair_success="failed"
    local repair_cost="0"
    local repair_turns="null"
    local resolution_summary="unknown"
    
    if echo "$repair_output" | grep -q '"is_error":false'; then
        repair_success="success"
    fi
    
    # Extract cost from JSON output
    if command -v jq &> /dev/null; then
        repair_cost=$(echo "$repair_output" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
        repair_turns=$(echo "$repair_output" | jq -r '.num_turns // "null"' 2>/dev/null || echo "null")
        
        # Try to extract a brief resolution from the result field
        resolution_summary=$(echo "$repair_output" | jq -r '.result | split("\n")[0] // "see repair log"' 2>/dev/null | cut -c1-100 || echo "see repair log")
    fi
    
    # Record repair completion
    record_repair_complete "$repair_id" "$repair_success" "$repair_cost" "$resolution_summary" "$repair_turns"
    LAST_REPAIR_SUCCESS="$repair_success"
    LAST_REPAIR_COST="$repair_cost"
    LAST_REPAIR_TURNS="$repair_turns"
    LAST_REPAIR_RESOLUTION="$resolution_summary"

    # Clean up temp file
    rm -f "$prompt_file"

    # Log the repair attempt
    log_repair "Repair ID: $repair_id"
    log_repair "Exit code: $repair_exit"
    log_repair "Success: $repair_success | Cost: \$$repair_cost | Turns: $repair_turns"
    log_repair "Resolution: $resolution_summary"
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
    doctor_output=$($OPENCLAW_CMD doctor 2>&1) || true
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
        notify_event "success" "🟢 OpenClaw Sentinel: repair succeeded on $(hostname). Type=${LAST_REPAIR_TYPE:-unknown}. Issue=${LAST_ISSUE_FP:-unknown}. Cost=\$${LAST_REPAIR_COST:-0} Turns=${LAST_REPAIR_TURNS:-null}."
    else
        log "Repair attempt completed but gateway still not responding"
        notify_event "failure" "🔴 OpenClaw Sentinel: repair failed on $(hostname). Type=${LAST_REPAIR_TYPE:-unknown}. Issue=${LAST_ISSUE_FP:-unknown}. Exit=${LAST_REPAIR_EXIT:-unknown}. Gateway still unhealthy."
    fi
    
    # Log repair statistics summary
    log "$(get_repair_stats)"
}

# Run main function
main "$@"
