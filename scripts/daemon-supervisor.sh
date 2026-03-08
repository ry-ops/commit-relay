#!/bin/bash
# scripts/daemon-supervisor.sh
# Monitors critical daemons and automatically restarts them if they stop
# Ensures commit-relay system remains operational

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Configuration
DAEMON_NAME="daemon-supervisor"
CHECK_INTERVAL="${DAEMON_SUPERVISOR_INTERVAL:-60}"  # Check every 60 seconds
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/daemon-supervisor.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
EVENTS_FILE="${COMMIT_RELAY_HOME}/coordination/events/daemon-supervisor-events.jsonl"

# Critical daemons to monitor (name:script pairs)
CRITICAL_DAEMONS=(
    "worker-daemon:worker-daemon.sh"
    "coordinator-daemon:coordinator-daemon.sh"
    "pm-daemon:pm-daemon.sh"
    "heartbeat-monitor:daemons/heartbeat-monitor-daemon.sh"
    "handoff-processor:handoff-processor-daemon.sh"
)

# Optional daemons (will be restarted but not logged as critical)
OPTIONAL_DAEMONS=(
    "health-monitor:health-monitor-daemon.sh"
    "metrics-snapshot:metrics-snapshot-daemon.sh"
    "failure-pattern:daemons/failure-pattern-daemon.sh"
    "auto-fix:daemons/auto-fix-daemon.sh"
)

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$EVENTS_FILE")"

# Redirect output to log file
exec >> "$LOG_FILE" 2>&1

log() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

emit_event() {
    local event_type="$1"
    local data="$2"
    echo "{\"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"event\": \"$event_type\", \"data\": $data}" >> "$EVENTS_FILE"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log "ERROR: Daemon supervisor already running with PID $OLD_PID"
        exit 1
    else
        log "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

# Cleanup on exit
trap 'rm -f "$PID_FILE"; log "INFO: Daemon supervisor stopping (PID $$)"' EXIT INT TERM

log "INFO: Daemon supervisor starting (PID $$)"
log "INFO: Check interval: ${CHECK_INTERVAL}s"
log "INFO: Monitoring ${#CRITICAL_DAEMONS[@]} critical daemons"

# Track restart counts
declare -A restart_counts 2>/dev/null || true

# Main monitoring loop
while true; do
    cd "$COMMIT_RELAY_HOME"

    # Check critical daemons
    for daemon_pair in "${CRITICAL_DAEMONS[@]}"; do
        IFS=':' read -r daemon_name script_name <<< "$daemon_pair"
        script_path="$SCRIPT_DIR/$script_name"

        if ! pgrep -f "$script_name" > /dev/null 2>&1; then
            log "CRITICAL: $daemon_name is not running!"

            # Check if script exists
            if [ ! -f "$script_path" ]; then
                log "ERROR: Script not found: $script_path"
                emit_event "daemon_missing_script" "{\"daemon\": \"$daemon_name\", \"script\": \"$script_path\"}"
                continue
            fi

            # Attempt restart
            log "INFO: Attempting to restart $daemon_name..."
            nohup "$script_path" >> "$COMMIT_RELAY_HOME/agents/logs/system/${daemon_name}.log" 2>&1 &

            sleep 3

            # Verify restart
            if pgrep -f "$script_name" > /dev/null 2>&1; then
                log "SUCCESS: $daemon_name restarted successfully"
                emit_event "daemon_restarted" "{\"daemon\": \"$daemon_name\", \"critical\": true}"

                # Broadcast to dashboard
                curl -s -X POST "http://localhost:3000/api/events" \
                    -H "Content-Type: application/json" \
                    -d "{\"type\": \"daemon_restarted\", \"data\": {\"daemon\": \"$daemon_name\", \"critical\": true}}" \
                    2>/dev/null || true
            else
                log "ERROR: Failed to restart $daemon_name"
                emit_event "daemon_restart_failed" "{\"daemon\": \"$daemon_name\", \"critical\": true}"

                # Send alert
                curl -s -X POST "http://localhost:3000/api/events" \
                    -H "Content-Type: application/json" \
                    -d "{\"type\": \"daemon_restart_failed\", \"data\": {\"daemon\": \"$daemon_name\", \"critical\": true}, \"severity\": \"critical\"}" \
                    2>/dev/null || true
            fi
        fi
    done

    # Check optional daemons (less critical, still restart)
    for daemon_pair in "${OPTIONAL_DAEMONS[@]}"; do
        IFS=':' read -r daemon_name script_name <<< "$daemon_pair"
        script_path="$SCRIPT_DIR/$script_name"

        if ! pgrep -f "$script_name" > /dev/null 2>&1; then
            # Silently restart optional daemons
            if [ -f "$script_path" ]; then
                nohup "$script_path" >> "$COMMIT_RELAY_HOME/agents/logs/system/${daemon_name}.log" 2>&1 &
                sleep 2

                if pgrep -f "$script_name" > /dev/null 2>&1; then
                    log "INFO: Restarted optional daemon $daemon_name"
                    emit_event "daemon_restarted" "{\"daemon\": \"$daemon_name\", \"critical\": false}"
                fi
            fi
        fi
    done

    # Report overall health every 5 minutes
    if [ $(($(date +%s) % 300)) -lt $CHECK_INTERVAL ]; then
        running_critical=0
        total_critical=${#CRITICAL_DAEMONS[@]}

        for daemon_pair in "${CRITICAL_DAEMONS[@]}"; do
            IFS=':' read -r _ script_name <<< "$daemon_pair"
            if pgrep -f "$script_name" > /dev/null 2>&1; then
                ((running_critical++))
            fi
        done

        if [ $running_critical -eq $total_critical ]; then
            log "INFO: All $total_critical critical daemons running"
        else
            log "WARN: Only $running_critical/$total_critical critical daemons running"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
