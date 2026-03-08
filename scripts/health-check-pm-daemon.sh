#!/bin/bash
# scripts/health-check-pm-daemon.sh
# Health check and auto-restart script for PM daemon
# Can be run via cron or manually to ensure daemon stays running

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Configuration
PID_FILE="/tmp/pm-daemon.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/pm-daemon-health.log"
PM_STATE_FILE="$COMMIT_RELAY_HOME/coordination/pm-state.json"
MAX_LOOP_AGE_MINUTES=10  # Alert if no loop in 10 minutes

# Logging
log_health() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [HEALTH] $1" | tee -a "$LOG_FILE"
}

# Check if PM daemon is running
check_pm_running() {
    if [ ! -f "$PID_FILE" ]; then
        log_health "ERROR: PID file not found at $PID_FILE"
        return 1
    fi

    local pid=$(cat "$PID_FILE")

    if ! ps -p "$pid" > /dev/null 2>&1; then
        log_health "ERROR: PM daemon process $pid not running (stale PID file)"
        return 1
    fi

    log_health "INFO: PM daemon running (PID: $pid)"
    return 0
}

# Check PM daemon is making progress (loops completing)
check_pm_progress() {
    if [ ! -f "$PM_STATE_FILE" ]; then
        log_health "ERROR: PM state file not found at $PM_STATE_FILE"
        return 1
    fi

    local last_loop=$(jq -r '.pm_daemon.last_loop // empty' "$PM_STATE_FILE")

    if [ -z "$last_loop" ]; then
        log_health "WARN: No last_loop timestamp in PM state"
        return 1
    fi

    # Calculate age of last loop
    local now=$(date +%s)
    local then

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: Handle both formats (with Z and with -0600)
        # Try Z format first, then timezone offset format
        then=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${last_loop%%-*}Z" +%s 2>/dev/null || \
               date -j -f "%Y-%m-%dT%H:%M:%S%z" "$last_loop" +%s 2>/dev/null || \
               echo 0)
    else
        # Linux: GNU date handles both formats
        then=$(date -d "$last_loop" +%s 2>/dev/null || echo 0)
    fi

    if [ "$then" -eq 0 ]; then
        log_health "ERROR: Failed to parse timestamp: $last_loop"
        return 1
    fi

    local age_minutes=$(( (now - then) / 60 ))

    if [ $age_minutes -gt $MAX_LOOP_AGE_MINUTES ]; then
        log_health "ERROR: PM daemon stalled - last loop was $age_minutes minutes ago (threshold: $MAX_LOOP_AGE_MINUTES min)"
        return 1
    fi

    log_health "INFO: PM daemon healthy - last loop $age_minutes minutes ago"
    return 0
}

# Restart PM daemon
restart_pm_daemon() {
    log_health "INFO: Attempting to restart PM daemon"

    # Kill old process if exists
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            log_health "INFO: Killing old PM daemon process $old_pid"
            kill "$old_pid" 2>/dev/null || kill -9 "$old_pid" 2>/dev/null || true
            sleep 2
        fi
        rm -f "$PID_FILE"
    fi

    # Start new daemon
    cd "$COMMIT_RELAY_HOME"
    nohup "$SCRIPT_DIR/pm-daemon.sh" > /dev/null 2>&1 &
    local new_pid=$!

    sleep 3

    # Verify it started
    if ps -p "$new_pid" > /dev/null 2>&1; then
        log_health "SUCCESS: PM daemon restarted (PID: $new_pid)"
        return 0
    else
        log_health "ERROR: Failed to restart PM daemon"
        return 1
    fi
}

# Main health check
main() {
    log_health "Starting PM daemon health check"

    local needs_restart=false

    # Check if daemon is running
    if ! check_pm_running; then
        log_health "WARN: PM daemon not running"
        needs_restart=true
    elif ! check_pm_progress; then
        log_health "WARN: PM daemon not making progress"
        needs_restart=true
    fi

    # Restart if needed
    if [ "$needs_restart" = true ]; then
        restart_pm_daemon
        exit $?
    else
        log_health "INFO: PM daemon health check passed"
        exit 0
    fi
}

# Run health check
main "$@"
