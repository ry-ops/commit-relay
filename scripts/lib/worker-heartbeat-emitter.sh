#!/bin/bash
# scripts/lib/worker-heartbeat-emitter.sh
# Background heartbeat emitter for running workers
# Phase 4.1 - Self-Healing Implementation
#
# This script runs in the background alongside a worker and emits periodic heartbeats
# to track worker health and detect failures.
#
# Usage:
#   ./worker-heartbeat-emitter.sh <worker_id> <worker_pid>
#
# The script will:
#   - Emit heartbeats every 30 seconds
#   - Monitor the worker process and stop when it completes
#   - Track worker activity and health metrics
#   - Stop automatically when the worker finishes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load heartbeat library
source "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh"

# Configuration
WORKER_ID="${1:-}"
WORKER_PID="${2:-}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL_SECONDS:-30}"

# Validate arguments
if [ -z "$WORKER_ID" ]; then
    echo "ERROR: WORKER_ID required as first argument"
    exit 1
fi

if [ -z "$WORKER_PID" ]; then
    echo "ERROR: WORKER_PID required as second argument"
    exit 1
fi

# Log file
LOG_FILE="$COMMIT_RELAY_HOME/agents/workers/$WORKER_ID/logs/heartbeat-emitter.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

log_heartbeat() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] HEARTBEAT: $1"
}

log_heartbeat "INFO: Heartbeat emitter starting for worker $WORKER_ID (PID: $WORKER_PID)"
log_heartbeat "INFO: Heartbeat interval: ${HEARTBEAT_INTERVAL}s"

# Track last activity description
LAST_ACTIVITY="Worker initialized"
HEARTBEAT_COUNT=0

# Main heartbeat emission loop
while true; do
    # Check if worker process is still running
    if ! ps -p "$WORKER_PID" > /dev/null 2>&1; then
        log_heartbeat "INFO: Worker process $WORKER_PID has stopped, ending heartbeat emission"
        break
    fi

    # Determine current activity by checking recent log output
    WORKER_LOGS="$COMMIT_RELAY_HOME/agents/workers/$WORKER_ID/logs/stdout.log"
    if [ -f "$WORKER_LOGS" ]; then
        # Get last non-empty line from logs as activity indicator
        RECENT_ACTIVITY=$(tail -n 5 "$WORKER_LOGS" 2>/dev/null | grep -v '^$' | tail -n 1 | cut -c1-100 || echo "Processing task")
        if [ -n "$RECENT_ACTIVITY" ]; then
            LAST_ACTIVITY="$RECENT_ACTIVITY"
        fi
    fi

    # Emit heartbeat with current activity
    ((HEARTBEAT_COUNT++))
    log_heartbeat "INFO: Emitting heartbeat #$HEARTBEAT_COUNT - Activity: $LAST_ACTIVITY"

    if emit_heartbeat "$WORKER_ID" "$LAST_ACTIVITY"; then
        log_heartbeat "SUCCESS: Heartbeat #$HEARTBEAT_COUNT emitted successfully"
    else
        log_heartbeat "ERROR: Failed to emit heartbeat #$HEARTBEAT_COUNT"
    fi

    # Sleep until next heartbeat
    sleep "$HEARTBEAT_INTERVAL"
done

log_heartbeat "INFO: Heartbeat emitter stopping (emitted $HEARTBEAT_COUNT heartbeats total)"
exit 0
