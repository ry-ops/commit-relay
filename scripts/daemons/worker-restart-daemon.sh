#!/bin/bash
# scripts/daemons/worker-restart-daemon.sh
# Worker Restart Daemon - Phase 4.3 Self-Healing Implementation
# Processes restart queue and executes scheduled worker restarts
#
# Features:
#   - Polls restart queue every 10 seconds
#   - Executes restarts when scheduled time arrives
#   - Tracks restart success/failure rates
#   - Manages circuit breakers
#   - Emits observability events
#   - Collects restart metrics
#
# Usage:
#   ./scripts/daemons/worker-restart-daemon.sh
#   or via systemd/launchd for auto-start

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load libraries
source "$COMMIT_RELAY_HOME/scripts/lib/worker-restart.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || true
source "$COMMIT_RELAY_HOME/scripts/lib/coordination.sh" 2>/dev/null || true

# Daemon configuration
DAEMON_NAME="commit-relay-worker-restart"
POLL_INTERVAL="${WORKER_RESTART_POLL_INTERVAL:-10}"  # Check every 10 seconds
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/worker-restart-daemon.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
METRICS_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/worker-restart-metrics.json"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$METRICS_FILE")"

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

log_daemon() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_daemon "ERROR: Worker restart daemon already running with PID $OLD_PID"
        exit 1
    else
        log_daemon "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_daemon "INFO: Worker restart daemon starting (PID $$)"
log_daemon "INFO: Poll interval: ${POLL_INTERVAL}s"
log_daemon "INFO: Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_daemon "INFO: Worker restart daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Metrics counters
TOTAL_RESTARTS_ATTEMPTED=0
TOTAL_RESTARTS_SUCCEEDED=0
TOTAL_RESTARTS_FAILED=0

# ============================================================================
# Restart Queue Processing
# ============================================================================

##############################################################################
# is_time_to_restart: Check if scheduled time has arrived
# Args:
#   $1: scheduled_at (ISO-8601 timestamp)
# Returns: 0 if time to restart, 1 if not yet
##############################################################################
is_time_to_restart() {
    local scheduled_at="$1"

    # Convert scheduled time to epoch
    local scheduled_epoch
    if command -v gdate &> /dev/null; then
        # GNU date (macOS with coreutils)
        scheduled_epoch=$(gdate -d "$scheduled_at" +%s 2>/dev/null || echo "0")
    elif date -j -f "%Y-%m-%dT%H:%M:%S%z" "$scheduled_at" +%s > /dev/null 2>&1; then
        # BSD date (macOS)
        scheduled_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$scheduled_at" +%s)
    else
        # GNU date (Linux)
        scheduled_epoch=$(date -d "$scheduled_at" +%s 2>/dev/null || echo "0")
    fi

    local now_epoch=$(date +%s)

    if [ "$scheduled_epoch" -le "$now_epoch" ]; then
        return 0  # Time to restart
    else
        return 1  # Not yet
    fi
}

##############################################################################
# execute_restart: Spawn the restarted worker
# Args:
#   $1: queue_file (path to restart queue entry JSON)
# Returns: 0 if successful, 1 if failed
##############################################################################
execute_restart() {
    local queue_file="$1"

    if [ ! -f "$queue_file" ]; then
        log_daemon "ERROR: Queue file not found: $queue_file"
        return 1
    fi

    local new_worker_id=$(jq -r '.new_worker_id' "$queue_file")
    local task_id=$(jq -r '.task_id' "$queue_file")
    local worker_type=$(jq -r '.worker_type' "$queue_file")
    local master=$(jq -r '.master' "$queue_file")
    local original_worker_id=$(jq -r '.original_worker_id' "$queue_file")
    local attempt=$(jq -r '.attempt' "$queue_file")

    log_daemon "INFO: Executing restart for $new_worker_id (attempt $attempt)"

    ((TOTAL_RESTARTS_ATTEMPTED++))

    # Find zombie spec to get original configuration
    local zombie_spec=""
    local today=$(date +%Y-%m-%d)
    local yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)

    if [ -f "$ZOMBIE_SPECS_DIR/$today/${original_worker_id}.json" ]; then
        zombie_spec="$ZOMBIE_SPECS_DIR/$today/${original_worker_id}.json"
    elif [ -f "$ZOMBIE_SPECS_DIR/$yesterday/${original_worker_id}.json" ]; then
        zombie_spec="$ZOMBIE_SPECS_DIR/$yesterday/${original_worker_id}.json"
    else
        log_daemon "ERROR: Zombie spec not found for $original_worker_id"
        ((TOTAL_RESTARTS_FAILED++))
        emit_restart_event "worker_restart_failed" "$original_worker_id" "{\"new_worker_id\": \"$new_worker_id\", \"attempt\": $attempt, \"reason\": \"zombie_spec_not_found\"}"
        return 1
    fi

    # Extract additional context from zombie spec
    local repository=$(jq -r '.repository // ""' "$zombie_spec")
    local priority=$(jq -r '.priority // "medium"' "$zombie_spec")
    local scope=$(jq -r '.scope // {}' "$zombie_spec")
    local context=$(jq -r '.context // {}' "$zombie_spec")

    # Build spawn-worker command
    local spawn_cmd="$COMMIT_RELAY_HOME/scripts/spawn-worker.sh"
    local spawn_args=(
        "--type" "$worker_type"
        "--task-id" "$task_id"
        "--master" "$master"
        "--priority" "$priority"
    )

    # Add optional arguments
    if [ -n "$repository" ] && [ "$repository" != "null" ]; then
        spawn_args+=("--repo" "$repository")
    fi

    # Set environment variables for restart context
    export RESTART_MODE=true
    export RESTART_ATTEMPT="$attempt"
    export RESTART_ORIGINAL_WORKER="$original_worker_id"

    # Execute spawn
    log_daemon "INFO: Spawning worker: ${spawn_args[*]}"

    if "$spawn_cmd" "${spawn_args[@]}" >> "$LOG_FILE" 2>&1; then
        log_daemon "SUCCESS: Worker restarted successfully: $new_worker_id"
        ((TOTAL_RESTARTS_SUCCEEDED++))
        emit_restart_event "worker_restarted" "$original_worker_id" "{\"new_worker_id\": \"$new_worker_id\", \"attempt\": $attempt}"

        # Mark queue entry as completed
        jq '.status = "completed" | .completed_at = "'"$(date +%Y-%m-%dT%H:%M:%S%z)"'"' \
           "$queue_file" > "${queue_file}.tmp" && mv "${queue_file}.tmp" "$queue_file"

        return 0
    else
        log_daemon "ERROR: Failed to spawn worker: $new_worker_id"
        ((TOTAL_RESTARTS_FAILED++))
        emit_restart_event "worker_restart_failed" "$original_worker_id" "{\"new_worker_id\": \"$new_worker_id\", \"attempt\": $attempt, \"reason\": \"spawn_failed\"}"

        # Mark queue entry as failed
        jq '.status = "failed" | .failed_at = "'"$(date +%Y-%m-%dT%H:%M:%S%z)"'"' \
           "$queue_file" > "${queue_file}.tmp" && mv "${queue_file}.tmp" "$queue_file"

        # Check if we should trip circuit breaker
        local max_retries=$(get_max_retries "$worker_type")
        if [ "$attempt" -ge "$max_retries" ]; then
            log_daemon "CRITICAL: Max restart attempts reached for $worker_type, tripping circuit breaker"
            trip_circuit_breaker "$worker_type" "Max restart attempts exceeded"
        fi

        return 1
    fi
}

##############################################################################
# cleanup_completed_restarts: Remove old completed/failed restart entries
##############################################################################
cleanup_completed_restarts() {
    local cutoff_time=$(date -v-1H +%s 2>/dev/null || date -d "1 hour ago" +%s)

    for queue_file in "$RESTART_QUEUE_DIR"/*.json; do
        if [ ! -f "$queue_file" ]; then
            continue
        fi

        local status=$(jq -r '.status' "$queue_file" 2>/dev/null || echo "pending")

        if [[ "$status" =~ ^(completed|failed)$ ]]; then
            # Check age
            local queued_at=$(jq -r '.queued_at' "$queue_file" 2>/dev/null || echo "")

            if [ -n "$queued_at" ]; then
                local queued_epoch
                if command -v gdate &> /dev/null; then
                    queued_epoch=$(gdate -d "$queued_at" +%s 2>/dev/null || echo "0")
                elif date -j -f "%Y-%m-%dT%H:%M:%S%z" "$queued_at" +%s > /dev/null 2>&1; then
                    queued_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$queued_at" +%s)
                else
                    queued_epoch=$(date -d "$queued_at" +%s 2>/dev/null || echo "0")
                fi

                if [ "$queued_epoch" -lt "$cutoff_time" ]; then
                    log_daemon "INFO: Cleaning up old restart entry: $(basename "$queue_file")"
                    rm -f "$queue_file"
                fi
            fi
        fi
    done
}

# ============================================================================
# Metrics Collection
# ============================================================================

save_metrics() {
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)
    local success_rate=0

    if [ "$TOTAL_RESTARTS_ATTEMPTED" -gt 0 ]; then
        success_rate=$(awk "BEGIN {printf \"%.1f\", ($TOTAL_RESTARTS_SUCCEEDED * 100 / $TOTAL_RESTARTS_ATTEMPTED)}")
    fi

    local metrics_json=$(jq -nc \
        --arg timestamp "$timestamp" \
        --argjson attempted "$TOTAL_RESTARTS_ATTEMPTED" \
        --argjson succeeded "$TOTAL_RESTARTS_SUCCEEDED" \
        --argjson failed "$TOTAL_RESTARTS_FAILED" \
        --argjson success_rate "$success_rate" \
        '{
            timestamp: $timestamp,
            total_restarts_attempted: $attempted,
            total_restarts_succeeded: $succeeded,
            total_restarts_failed: $failed,
            success_rate: $success_rate
        }')

    echo "$metrics_json" > "$METRICS_FILE"

    # Also append to time series log
    local metrics_log="${COMMIT_RELAY_HOME}/coordination/metrics/worker-restart-history.jsonl"
    mkdir -p "$(dirname "$metrics_log")"
    echo "$metrics_json" >> "$metrics_log"
}

# ============================================================================
# Main Processing Loop
# ============================================================================

while true; do
    cd "$COMMIT_RELAY_HOME"

    log_daemon "INFO: Processing restart queue..."

    # Process pending restarts
    RESTARTS_PROCESSED=0

    if [ -d "$RESTART_QUEUE_DIR" ]; then
        for queue_file in "$RESTART_QUEUE_DIR"/*.json; do
            if [ ! -f "$queue_file" ]; then
                continue
            fi

            status=$(jq -r '.status' "$queue_file" 2>/dev/null || echo "")

            # Only process pending entries
            if [ "$status" != "pending" ]; then
                continue
            fi

            scheduled_at=$(jq -r '.scheduled_at' "$queue_file" 2>/dev/null || echo "")

            if [ -z "$scheduled_at" ]; then
                log_daemon "WARN: Invalid queue entry (no scheduled_at): $(basename "$queue_file")"
                continue
            fi

            # Check if it's time to execute
            if is_time_to_restart "$scheduled_at"; then
                log_daemon "INFO: Executing scheduled restart: $(basename "$queue_file")"
                execute_restart "$queue_file"
                ((RESTARTS_PROCESSED++))
            fi
        done
    fi

    # Cleanup old entries every 10 cycles (every ~100 seconds)
    if [ $(($(date +%s) % 100)) -lt "$POLL_INTERVAL" ]; then
        cleanup_completed_restarts
    fi

    # Save metrics
    save_metrics

    # Log summary
    if [ "$RESTARTS_PROCESSED" -gt 0 ]; then
        log_daemon "INFO: Processed $RESTARTS_PROCESSED restarts this cycle"
    fi

    log_daemon "INFO: Restart metrics - Attempted: $TOTAL_RESTARTS_ATTEMPTED, Succeeded: $TOTAL_RESTARTS_SUCCEEDED, Failed: $TOTAL_RESTARTS_FAILED"

    # Sleep until next cycle
    sleep "$POLL_INTERVAL"
done
