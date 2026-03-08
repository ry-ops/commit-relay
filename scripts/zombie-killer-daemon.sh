#!/bin/bash
################################################################################
# Zombie Killer Daemon
#
# Monitors worker specs for zombies (marked "running" with no active process)
# and cleans them up by marking as failed and moving to failed/ directory
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || true

# Configuration
DAEMON_NAME="commit-relay-zombie-killer"
CHECK_INTERVAL="${ZOMBIE_KILLER_INTERVAL:-300}"  # Check every 5 minutes
STALE_THRESHOLD="${ZOMBIE_STALE_THRESHOLD:-900}"  # 15 minutes = stale
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/zombie-killer.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

log_zombie() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_zombie "ERROR: Zombie killer already running with PID $OLD_PID"
        exit 1
    else
        log_zombie "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_zombie "INFO: Zombie Killer daemon starting (PID $$)"
log_zombie "INFO: Check interval: ${CHECK_INTERVAL}s"
log_zombie "INFO: Stale threshold: ${STALE_THRESHOLD}s ($(($STALE_THRESHOLD / 60)) minutes)"
log_zombie "INFO: Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_zombie "INFO: Zombie Killer daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Get current timestamp in seconds since epoch
get_timestamp_seconds() {
    date +%s
}

# Convert ISO 8601 timestamp to seconds since epoch
iso_to_seconds() {
    local iso_time="$1"
    date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso_time" +%s 2>/dev/null || echo "0"
}

# Main zombie killer loop
while true; do
    cd "$COMMIT_RELAY_HOME"

    CURRENT_TIME=$(get_timestamp_seconds)
    ACTIVE_SPECS_DIR="coordination/worker-specs/active"
    FAILED_DIR="coordination/worker-specs/failed"
    mkdir -p "$FAILED_DIR"

    ZOMBIES_FOUND=0
    ZOMBIES_KILLED=0

    if [ -d "$ACTIVE_SPECS_DIR" ]; then
        for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
            if [ ! -f "$spec_file" ]; then
                continue
            fi

            WORKER_ID=$(jq -r '.worker_id' "$spec_file" 2>/dev/null || echo "")
            WORKER_STATUS=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "")
            STARTED_AT=$(jq -r '.execution.started_at // "1970-01-01T00:00:00Z"' "$spec_file" 2>/dev/null)

            if [ -z "$WORKER_ID" ] || [ "$WORKER_ID" = "null" ]; then
                continue
            fi

            # Only check workers marked as "running"
            if [ "$WORKER_STATUS" != "running" ]; then
                continue
            fi

            # Calculate how long the worker has been running
            STARTED_SECONDS=$(iso_to_seconds "$STARTED_AT")
            if [ "$STARTED_SECONDS" = "0" ]; then
                log_zombie "WARN: Could not parse start time for $WORKER_ID: $STARTED_AT"
                continue
            fi

            RUNNING_TIME=$(($CURRENT_TIME - $STARTED_SECONDS))

            # Check heartbeat (v4.0 health monitoring)
            LAST_HEARTBEAT=$(jq -r '.execution.last_heartbeat // "1970-01-01T00:00:00Z"' "$spec_file" 2>/dev/null)
            HEARTBEAT_SECONDS=$(iso_to_seconds "$LAST_HEARTBEAT")
            HEARTBEAT_AGE=0

            if [ "$HEARTBEAT_SECONDS" != "0" ]; then
                HEARTBEAT_AGE=$(($CURRENT_TIME - $HEARTBEAT_SECONDS))
            fi

            # Zombie detection logic (v4.0):
            # 1. Running longer than threshold (15 min) OR
            # 2. Has heartbeat but hasn't pinged in >5 minutes
            IS_ZOMBIE=false
            ZOMBIE_REASON=""

            if [ $RUNNING_TIME -gt $STALE_THRESHOLD ]; then
                IS_ZOMBIE=true
                ZOMBIE_REASON="Running for ${RUNNING_TIME}s ($(($RUNNING_TIME / 60)) minutes) without completion"
            elif [ "$HEARTBEAT_SECONDS" != "0" ] && [ $HEARTBEAT_AGE -gt 300 ]; then
                # Heartbeat exists but hasn't updated in 5+ minutes
                IS_ZOMBIE=true
                ZOMBIE_REASON="Heartbeat stale for ${HEARTBEAT_AGE}s ($(($HEARTBEAT_AGE / 60)) minutes)"
            fi

            if [ "$IS_ZOMBIE" = true ]; then
                ZOMBIES_FOUND=$((ZOMBIES_FOUND + 1))

                # Check if there's actually a Claude process for this worker
                # Note: This is approximate - we check for any Claude process
                CLAUDE_PROCESSES=$(ps aux | grep -i "claude" | grep -v grep | wc -l | tr -d ' ')

                log_zombie "ZOMBIE DETECTED: $WORKER_ID"
                log_zombie "  Reason: $ZOMBIE_REASON"
                log_zombie "  Running for: ${RUNNING_TIME}s ($(($RUNNING_TIME / 60)) minutes)"
                log_zombie "  Started at: $STARTED_AT"
                log_zombie "  Last heartbeat: $LAST_HEARTBEAT (age: ${HEARTBEAT_AGE}s)"
                log_zombie "  Active Claude processes: $CLAUDE_PROCESSES"

                # Mark as failed and move to failed directory
                jq --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg runtime "$RUNNING_TIME" \
                   '.status = "failed" |
                    .execution.completed_at = $ts |
                    .execution.error = "Zombie worker detected - running for \($runtime)s with no completion" |
                    .execution.killed_by = "zombie-killer-daemon"' \
                   "$spec_file" > "${spec_file}.tmp" && \
                   mv "${spec_file}.tmp" "$FAILED_DIR/$(basename "$spec_file")"

                # Update task status to failed
                TASK_ID=$(jq -r '.task_id' "$spec_file" 2>/dev/null)
                if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
                    TASK_QUEUE="coordination/task-queue.json"
                    if [ -f "$TASK_QUEUE" ]; then
                        jq --arg id "$TASK_ID" --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                           '.tasks |= map(
                               if .id == $id then
                                   .status = "failed" |
                                   .completed_at = $ts |
                                   .error = "Worker became zombie and was killed"
                               else
                                   .
                               end
                           )' "$TASK_QUEUE" > "${TASK_QUEUE}.tmp" && \
                           mv "${TASK_QUEUE}.tmp" "$TASK_QUEUE"
                    fi
                fi

                ZOMBIES_KILLED=$((ZOMBIES_KILLED + 1))
                log_zombie "KILLED: $WORKER_ID moved to failed/"
            fi
        done
    fi

    # Check Execution Managers for zombies (v4.0)
    EM_ACTIVE_DIR="coordination/execution-managers/active"
    EM_COMPLETED_DIR="coordination/execution-managers/completed"
    EM_ZOMBIES_FOUND=0
    EM_ZOMBIES_KILLED=0

    if [ -d "$EM_ACTIVE_DIR" ]; then
        for em_file in "$EM_ACTIVE_DIR"/*.json; do
            if [ ! -f "$em_file" ]; then
                continue
            fi

            EM_ID=$(jq -r '.exec_mgr_id' "$em_file" 2>/dev/null || echo "")
            EM_STATUS=$(jq -r '.status' "$em_file" 2>/dev/null || echo "")
            EM_STARTED_AT=$(jq -r '.started_at // "1970-01-01T00:00:00Z"' "$em_file" 2>/dev/null)
            EM_LAST_HEARTBEAT=$(jq -r '.last_heartbeat // "1970-01-01T00:00:00Z"' "$em_file" 2>/dev/null)

            if [ -z "$EM_ID" ] || [ "$EM_ID" = "null" ]; then
                continue
            fi

            # Only check EMs marked as "running" or "ready"
            if [ "$EM_STATUS" != "running" ] && [ "$EM_STATUS" != "ready" ]; then
                continue
            fi

            # Calculate EM runtime
            EM_STARTED_SECONDS=$(iso_to_seconds "$EM_STARTED_AT")
            if [ "$EM_STARTED_SECONDS" = "0" ]; then
                continue
            fi

            EM_RUNNING_TIME=$(($CURRENT_TIME - $EM_STARTED_SECONDS))

            # Calculate heartbeat age
            EM_HEARTBEAT_SECONDS=$(iso_to_seconds "$EM_LAST_HEARTBEAT")
            EM_HEARTBEAT_AGE=0

            if [ "$EM_HEARTBEAT_SECONDS" != "0" ]; then
                EM_HEARTBEAT_AGE=$(($CURRENT_TIME - $EM_HEARTBEAT_SECONDS))
            fi

            # EM Zombie detection:
            # 1. Running longer than 60 minutes (EMs can be long-running) OR
            # 2. Heartbeat stale for >5 minutes
            EM_IS_ZOMBIE=false
            EM_ZOMBIE_REASON=""

            if [ $EM_RUNNING_TIME -gt 3600 ]; then
                # 60 minutes = 3600 seconds
                EM_IS_ZOMBIE=true
                EM_ZOMBIE_REASON="Running for ${EM_RUNNING_TIME}s ($(($EM_RUNNING_TIME / 60)) minutes) without completion"
            elif [ "$EM_HEARTBEAT_SECONDS" != "0" ] && [ $EM_HEARTBEAT_AGE -gt 300 ]; then
                # Heartbeat exists but hasn't updated in 5+ minutes
                EM_IS_ZOMBIE=true
                EM_ZOMBIE_REASON="Heartbeat stale for ${EM_HEARTBEAT_AGE}s ($(($EM_HEARTBEAT_AGE / 60)) minutes)"
            fi

            if [ "$EM_IS_ZOMBIE" = true ]; then
                EM_ZOMBIES_FOUND=$((EM_ZOMBIES_FOUND + 1))

                log_zombie "EXECUTION MANAGER ZOMBIE DETECTED: $EM_ID"
                log_zombie "  Reason: $EM_ZOMBIE_REASON"
                log_zombie "  Running for: ${EM_RUNNING_TIME}s ($(($EM_RUNNING_TIME / 60)) minutes)"
                log_zombie "  Started at: $EM_STARTED_AT"
                log_zombie "  Last heartbeat: $EM_LAST_HEARTBEAT (age: ${EM_HEARTBEAT_AGE}s)"

                # Mark as failed and move to completed directory
                mkdir -p "$EM_COMPLETED_DIR"
                jq --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg runtime "$EM_RUNNING_TIME" \
                   '.status = "failed" |
                    .current_phase = "zombie_detected" |
                    .failed_at = $ts |
                    .error = "Execution Manager became zombie - running for \($runtime)s with no completion" |
                    .killed_by = "zombie-killer-daemon"' \
                   "$em_file" > "${em_file}.tmp" && \
                   mv "${em_file}.tmp" "$EM_COMPLETED_DIR/$(basename "$em_file")"

                EM_ZOMBIES_KILLED=$((EM_ZOMBIES_KILLED + 1))
                log_zombie "KILLED: $EM_ID moved to completed/"
            fi
        done
    fi

    # Summary logging
    TOTAL_ZOMBIES=$((ZOMBIES_FOUND + EM_ZOMBIES_FOUND))
    TOTAL_KILLED=$((ZOMBIES_KILLED + EM_ZOMBIES_KILLED))

    if [ $TOTAL_ZOMBIES -gt 0 ]; then
        log_zombie "INFO: Zombie scan complete - Workers: $ZOMBIES_FOUND/$ZOMBIES_KILLED, EMs: $EM_ZOMBIES_FOUND/$EM_ZOMBIES_KILLED, Total: $TOTAL_KILLED killed"
    else
        log_zombie "DEBUG: No zombies detected - all workers and EMs healthy"
    fi

    # Sleep until next check
    sleep $CHECK_INTERVAL
done
