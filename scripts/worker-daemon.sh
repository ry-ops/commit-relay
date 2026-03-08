#!/bin/bash
# scripts/worker-daemon.sh
# Background daemon that monitors for pending workers and launches them automatically
# Part of commit-relay autonomous automation system

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"
source "$SCRIPT_DIR/lib/heartbeat.sh"

# Daemon configuration
DAEMON_NAME="commit-relay-worker-daemon"
POLL_INTERVAL="${WORKER_DAEMON_POLL_INTERVAL:-30}"  # Check every 30 seconds
AUTO_CLOSE_WORKERS="${AUTO_CLOSE_WORKERS:-true}"     # Auto-close terminal tabs after completion
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/worker-daemon.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

log_daemon() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_daemon "ERROR: Daemon already running with PID $OLD_PID"
        exit 1
    else
        log_daemon "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_daemon "INFO: Worker daemon starting (PID $$)"
log_daemon "INFO: Poll interval: ${POLL_INTERVAL}s"
log_daemon "INFO: Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_daemon "INFO: Worker daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Track active workers using a simple file-based approach
TRACKING_DIR="/tmp/commit-relay-workers"
mkdir -p "$TRACKING_DIR"

# Sparse Pool Manager Integration (MoE-inspired)
check_pool_capacity() {
    local sparse_manager="$COMMIT_RELAY_HOME/scripts/sparse-pool-manager.sh"

    if [ ! -f "$sparse_manager" ]; then
        # No sparse manager - allow unlimited (legacy mode)
        return 0
    fi

    # Run sparse pool manager to get recommendations
    local pool_output=$("$sparse_manager" 2>/dev/null || echo "")

    if [ -z "$pool_output" ]; then
        # Manager failed - allow launch (fail-open)
        log_daemon "WARN: Sparse pool manager check failed, allowing worker launch"
        return 0
    fi

    # Check pool state file for capacity
    local pool_state="$COMMIT_RELAY_HOME/coordination/memory/working/pool-state.json"
    if [ -f "$pool_state" ]; then
        local active_workers=$(jq -r '.pool_metrics.active_workers' "$pool_state" 2>/dev/null || echo 0)
        local target_workers=$(jq -r '.pool_metrics.target_workers' "$pool_state" 2>/dev/null || echo 99)
        local activation_rate=$(jq -r '.pool_metrics.activation_rate' "$pool_state" 2>/dev/null || echo 100)

        log_daemon "INFO: Pool capacity check - Active: $active_workers, Target: $target_workers, Rate: ${activation_rate}%"

        if [ "$active_workers" -ge "$target_workers" ]; then
            log_daemon "WARN: Worker pool at capacity ($active_workers/$target_workers), deferring launch"
            return 1  # At capacity, don't launch
        fi

        log_daemon "INFO: Pool has capacity, allowing launch ($active_workers < $target_workers)"
        return 0
    fi

    # No pool state - allow launch
    return 0
}

# Check for completed workers and finalize their lifecycle
check_completed_workers() {
    local ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"
    local COMPLETED_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/completed"
    local FAILED_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/failed"
    local WORKERS_DIR="$COMMIT_RELAY_HOME/agents/workers"

    mkdir -p "$COMPLETED_DIR" "$FAILED_DIR"

    if [ ! -d "$ACTIVE_SPECS_DIR" ]; then
        return 0
    fi

    for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
        if [ ! -f "$spec_file" ]; then
            continue
        fi

        local worker_id=$(jq -r '.worker_id' "$spec_file" 2>/dev/null || echo "")
        local worker_status=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "")

        if [ -z "$worker_id" ] || [ "$worker_id" = "null" ]; then
            continue
        fi

        # Skip pending workers
        if [ "$worker_status" = "pending" ]; then
            continue
        fi

        # Check for status.json in worker directory
        local status_file="$WORKERS_DIR/$worker_id/status.json"
        if [ ! -f "$status_file" ]; then
            continue
        fi

        local final_status=$(jq -r '.status' "$status_file" 2>/dev/null || echo "")

        if [ "$final_status" = "completed" ]; then
            log_daemon "INFO: Worker $worker_id completed successfully"

            # Update spec with completion info
            local completed_at=$(jq -r '.timestamp' "$status_file" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
            jq --arg status "completed" --arg completed "$completed_at" \
               '.status = $status | .execution.completed_at = $completed' \
               "$spec_file" > "${spec_file}.tmp" && mv "${spec_file}.tmp" "$spec_file"

            # Move to completed directory
            mv "$spec_file" "$COMPLETED_DIR/"
            log_daemon "INFO: Moved $worker_id spec to completed"

            # Update task queue status
            local task_id=$(jq -r '.task_id' "$COMPLETED_DIR/$(basename "$spec_file")" 2>/dev/null || echo "")
            if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
                local task_queue="$COMMIT_RELAY_HOME/coordination/task-queue.json"
                if [ -f "$task_queue" ]; then
                    jq --arg tid "$task_id" \
                       '(.tasks[] | select(.id == $tid)).status = "completed"' \
                       "$task_queue" > /tmp/task-queue-update.tmp && \
                       mv /tmp/task-queue-update.tmp "$task_queue"
                    log_daemon "INFO: Updated task $task_id status to completed"
                fi
            fi

            # Emit completion event
            broadcast_dashboard_event "worker_completed" \
                "{\"worker_id\": \"$worker_id\", \"task_id\": \"$task_id\", \"status\": \"completed\"}" \
                2>/dev/null || true

        elif [ "$final_status" = "failed" ]; then
            log_daemon "WARN: Worker $worker_id failed"

            # Get error info
            local error=$(jq -r '.error // "unknown"' "$status_file" 2>/dev/null || echo "unknown")
            local exit_code=$(jq -r '.exit_code // 1' "$status_file" 2>/dev/null || echo "1")

            # Update spec with failure info
            jq --arg status "failed" --arg error "$error" --argjson code "$exit_code" \
               '.status = $status | .execution.error = $error | .execution.exit_code = $code | .execution.completed_at = (now | todate)' \
               "$spec_file" > "${spec_file}.tmp" && mv "${spec_file}.tmp" "$spec_file"

            # Move to failed directory
            mv "$spec_file" "$FAILED_DIR/"
            log_daemon "INFO: Moved $worker_id spec to failed"

            # Update task queue status
            local task_id=$(jq -r '.task_id' "$FAILED_DIR/$(basename "$spec_file")" 2>/dev/null || echo "")
            if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
                local task_queue="$COMMIT_RELAY_HOME/coordination/task-queue.json"
                if [ -f "$task_queue" ]; then
                    jq --arg tid "$task_id" \
                       '(.tasks[] | select(.id == $tid)).status = "failed"' \
                       "$task_queue" > /tmp/task-queue-update.tmp && \
                       mv /tmp/task-queue-update.tmp "$task_queue"
                    log_daemon "INFO: Updated task $task_id status to failed"
                fi
            fi

            # Emit failure event
            broadcast_dashboard_event "worker_failed" \
                "{\"worker_id\": \"$worker_id\", \"task_id\": \"$task_id\", \"error\": \"$error\"}" \
                2>/dev/null || true
        fi
    done
}

# Main daemon loop
while true; do
    cd "$COMMIT_RELAY_HOME"

    # Check for completed workers first
    check_completed_workers

    # MoE: Check pool capacity before processing workers
    if ! check_pool_capacity; then
        log_daemon "INFO: Pool at capacity, skipping this cycle"
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Pull latest coordination state (quietly)
    if git pull origin main --quiet 2>/dev/null; then
        log_daemon "DEBUG: Coordination state updated"
    fi

    # Check for pending workers
    ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"

    if [ -d "$ACTIVE_SPECS_DIR" ]; then
        for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
            if [ ! -f "$spec_file" ]; then
                continue
            fi

            # Validate JSON before parsing (capture errors)
            JQ_ERROR=$(jq empty "$spec_file" 2>&1 >/dev/null)
            if [ -n "$JQ_ERROR" ]; then
                log_daemon "ERROR: Malformed JSON in worker spec: $(basename "$spec_file")"
                log_daemon "ERROR: jq error: $JQ_ERROR"
                log_daemon "ERROR: Moving malformed spec to quarantine"

                # Create quarantine directory
                mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/quarantine"

                # Move malformed spec to quarantine with timestamp
                quarantine_file="$COMMIT_RELAY_HOME/coordination/worker-specs/quarantine/$(basename "$spec_file" .json)-malformed-$(date +%s).json"
                mv "$spec_file" "$quarantine_file"

                # Emit governance alert
                broadcast_dashboard_event "malformed_worker_spec" \
                    "{\"file\": \"$(basename "$spec_file")\", \"error\": \"jq parse failure\", \"quarantined\": \"$quarantine_file\"}" \
                    2>/dev/null || true

                continue
            fi

            WORKER_ID=$(jq -r '.worker_id' "$spec_file" 2>/dev/null || echo "")
            WORKER_STATUS=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "")

            if [ -z "$WORKER_ID" ] || [ "$WORKER_ID" = "null" ]; then
                log_daemon "WARN: Worker spec missing worker_id: $(basename "$spec_file")"
                continue
            fi

            # Skip if already tracked as active (using file marker)
            if [ -f "$TRACKING_DIR/$WORKER_ID" ]; then
                continue
            fi

            # Launch pending workers
            if [ "$WORKER_STATUS" = "pending" ]; then
                WORKER_TYPE=$(jq -r '.worker_type' "$spec_file")
                TASK_ID=$(jq -r '.task_id' "$spec_file")
                CREATED_BY=$(jq -r '.created_by' "$spec_file")
                TOKEN_BUDGET=$(jq -r '.resources.token_budget' "$spec_file")

                log_daemon "INFO: Found pending worker: $WORKER_ID"
                log_daemon "INFO:   Type: $WORKER_TYPE"
                log_daemon "INFO:   Task: $TASK_ID"
                log_daemon "INFO:   Master: $CREATED_BY"
                log_daemon "INFO:   Budget: ${TOKEN_BUDGET} tokens"

                # Launch worker in background
                log_daemon "INFO: Launching $WORKER_ID in new Claude Code session..."

                # Update worker status to running
                jq --arg started "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                   '.status = "running" | .execution.started_at = $started' \
                   "$spec_file" > "${spec_file}.tmp" && \
                   mv "${spec_file}.tmp" "$spec_file"

                # Initialize heartbeat tracking
                log_daemon "INFO: Initializing heartbeat for $WORKER_ID"
                init_heartbeat "$WORKER_ID" || log_daemon "WARN: Failed to initialize heartbeat for $WORKER_ID"

                # Broadcast worker started event
                EVENT_DATA=$(jq -nc \
                    --arg worker "$WORKER_ID" \
                    --arg task "$TASK_ID" \
                    --arg type "$WORKER_TYPE" \
                    '{worker_id: $worker, task_id: $task, worker_type: $type, launched_by: "daemon"}')
                broadcast_dashboard_event "worker_started" "$EVENT_DATA" 2>/dev/null || true

                # Use Claude Code launcher to spawn worker with AI capabilities
                # Use enhanced launcher with Terminal.app and TTY support
                CLAUDE_LAUNCHER="$COMMIT_RELAY_HOME/scripts/claude-worker-launcher-v2.sh"

                if [ -f "$CLAUDE_LAUNCHER" ]; then
                    # Read terminal settings
                    TERMINAL_SETTINGS="$COMMIT_RELAY_HOME/coordination/config/terminal-settings.json"
                    TERMINAL_ENABLED="true"
                    HEADLESS_MODE="false"
                    AUTO_CLOSE_DURATION="0"

                    if [ -f "$TERMINAL_SETTINGS" ]; then
                        TERMINAL_ENABLED=$(jq -r '.terminal_windows_enabled' "$TERMINAL_SETTINGS" 2>/dev/null || echo "true")
                        HEADLESS_MODE=$(jq -r '.headless_mode' "$TERMINAL_SETTINGS" 2>/dev/null || echo "false")
                        AUTO_CLOSE_DURATION=$(jq -r '.auto_close_duration_minutes' "$TERMINAL_SETTINGS" 2>/dev/null || echo "0")
                    fi

                    # Build launch command
                    TERMINAL_CMD="cd $COMMIT_RELAY_HOME && $CLAUDE_LAUNCHER $WORKER_ID"

                    if [ "$TERMINAL_ENABLED" = "true" ] && [ "$HEADLESS_MODE" = "false" ]; then
                        log_daemon "INFO: Launching worker with Claude Code in Terminal window"

                        # Launch Claude Code worker in Terminal
                        osascript -e "tell application \"Terminal\"
                            do script \"$TERMINAL_CMD\"
                            activate
                        end tell" > /dev/null 2>&1 &

                        # If auto-close duration is set, schedule terminal closure
                        if [ "$AUTO_CLOSE_DURATION" -gt 0 ]; then
                            (
                                sleep $((AUTO_CLOSE_DURATION * 60))
                                osascript -e "tell application \"Terminal\" to close (every window whose name contains \"$WORKER_ID\")" 2>/dev/null || true
                            ) &
                            log_daemon "INFO: Terminal window will auto-close in ${AUTO_CLOSE_DURATION} minutes"
                        fi
                    else
                        log_daemon "INFO: Launching worker with Claude Code in HEADLESS mode (no terminal window)"

                        # Launch worker headless in background
                        (
                            cd "$COMMIT_RELAY_HOME"
                            mkdir -p "agents/workers/$WORKER_ID/logs"
                            "$CLAUDE_LAUNCHER" "$WORKER_ID" "$TASK_ID" "$WORKER_TYPE" \
                                > "agents/workers/$WORKER_ID/logs/stdout.log" 2>&1 &
                        ) &
                    fi

                else
                    log_daemon "ERROR: Claude worker launcher not found: $CLAUDE_LAUNCHER"
                    log_daemon "ERROR: Cannot launch worker without Claude Code launcher"

                    # Update worker status to failed
                    jq --arg failed "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                       '.status = "failed" | .execution.failed_at = $failed | .execution.error = "Claude launcher not found"' \
                       "$spec_file" > "${spec_file}.tmp" && \
                       mv "${spec_file}.tmp" "$spec_file"

                    # Move to failed directory
                    mv "$spec_file" "$COMMIT_RELAY_HOME/coordination/worker-specs/failed/"

                    continue
                fi

                log_daemon "SUCCESS: Launched $WORKER_ID in new Terminal tab"

                # Mark as tracked
                touch "$TRACKING_DIR/$WORKER_ID"

                # Commit the status change
                git add "$spec_file" 2>/dev/null || true
                git commit -m "chore(daemon): launched $WORKER_ID automatically" --quiet 2>/dev/null || true
                git push origin main --quiet 2>/dev/null || true
            fi
        done
    fi

    # Clean up tracking for completed workers
    for tracking_file in "$TRACKING_DIR"/*; do
        if [ ! -f "$tracking_file" ]; then
            continue
        fi

        worker_id=$(basename "$tracking_file")
        if [ ! -f "$ACTIVE_SPECS_DIR/${worker_id}.json" ]; then
            log_daemon "DEBUG: Worker $worker_id completed, removing from tracking"
            rm -f "$tracking_file"
        fi
    done

    # Sleep before next check
    sleep "$POLL_INTERVAL"
done
