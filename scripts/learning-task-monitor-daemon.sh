#!/bin/bash

# Learning Task Monitor Daemon
# Monitors MoE learning tasks for progress, deliverables, and stalls
# Automatically kills tasks that become unresponsive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
SLEEP_INTERVAL="${LEARNING_MONITOR_INTERVAL:-30}"  # Check every 30 seconds
STALL_THRESHOLD_MINUTES="${LEARNING_STALL_THRESHOLD:-15}"  # Kill after 15 minutes of no activity
DELIVERABLES_DIR="$PROJECT_ROOT/coordination/moe-learning/deliverables"
LEARNING_STATE_FILE="$PROJECT_ROOT/coordination/moe-learning/learning-state.json"
LEARNING_EVENTS_FILE="$PROJECT_ROOT/coordination/events/learning-events.jsonl"
LEARNING_METRICS_FILE="$PROJECT_ROOT/coordination/metrics/learning-monitor-metrics.json"
LOG_FILE="$PROJECT_ROOT/agents/logs/system/learning-task-monitor.log"
PID_FILE="$PROJECT_ROOT/coordination/pids/learning-monitor.pid"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$LEARNING_STATE_FILE")"
mkdir -p "$(dirname "$LEARNING_EVENTS_FILE")"
mkdir -p "$(dirname "$LEARNING_METRICS_FILE")"
mkdir -p "$DELIVERABLES_DIR"
mkdir -p "$(dirname "$PID_FILE")"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] LEARNING-MONITOR: $1" | tee -a "$LOG_FILE"
}

emit_event() {
    local event_type="$1"
    local task_id="$2"
    local details="$3"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "{\"timestamp\":\"$timestamp\",\"event\":\"$event_type\",\"task_id\":\"$task_id\",\"details\":$details}" >> "$LEARNING_EVENTS_FILE"
}

# Initialize or load learning state
init_state() {
    if [[ ! -f "$LEARNING_STATE_FILE" ]]; then
        cat > "$LEARNING_STATE_FILE" << 'EOF'
{
  "monitored_tasks": {},
  "total_tasks_monitored": 0,
  "total_tasks_completed": 0,
  "total_tasks_killed": 0,
  "last_updated": null
}
EOF
    fi
}

# Get current timestamp in seconds since epoch
get_epoch() {
    date +%s
}

# Calculate minutes since a given ISO timestamp
minutes_since() {
    local timestamp="$1"
    local then_epoch
    local now_epoch

    # Handle different date formats
    if [[ "$OSTYPE" == "darwin"* ]]; then
        then_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${timestamp%%.*}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo 0)
    else
        then_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)
    fi

    now_epoch=$(get_epoch)
    echo $(( (now_epoch - then_epoch) / 60 ))
}

# Find active learning tasks
find_learning_tasks() {
    local tasks=()

    # Check handoffs directory for learning tasks
    for handoff in "$PROJECT_ROOT/coordination/masters"/*/handoffs/task-moe-learning-*.json; do
        if [[ -f "$handoff" ]]; then
            local task_id
            task_id=$(jq -r '.task_id // .handoff_id' "$handoff" 2>/dev/null)
            if [[ -n "$task_id" && "$task_id" != "null" ]]; then
                tasks+=("$task_id:$handoff")
            fi
        fi
    done

    # Check task queue for learning tasks
    if [[ -f "$PROJECT_ROOT/coordination/task-queue.json" ]]; then
        local queue_tasks
        queue_tasks=$(jq -r '.tasks[]? | select(.id | startswith("task-moe-learning")) | .id' "$PROJECT_ROOT/coordination/task-queue.json" 2>/dev/null)
        for task_id in $queue_tasks; do
            tasks+=("$task_id:queue")
        done
    fi

    printf '%s\n' "${tasks[@]}" | sort -u
}

# Get task status and details
get_task_info() {
    local task_id="$1"
    local source="$2"

    if [[ "$source" == "queue" ]]; then
        jq -r --arg tid "$task_id" '.tasks[] | select(.id == $tid)' "$PROJECT_ROOT/coordination/task-queue.json" 2>/dev/null
    else
        jq -r '.' "$source" 2>/dev/null
    fi
}

# Count deliverables for a task
count_deliverables() {
    local task_id="$1"
    local task_dir="$DELIVERABLES_DIR/$task_id"

    if [[ -d "$task_dir" ]]; then
        find "$task_dir" -type f | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# Get last activity timestamp for a task
get_last_activity() {
    local task_id="$1"
    local last_activity=""

    # Check deliverables directory
    local task_dir="$DELIVERABLES_DIR/$task_id"
    if [[ -d "$task_dir" ]]; then
        local latest_file
        latest_file=$(find "$task_dir" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [[ -n "$latest_file" ]]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                last_activity=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$latest_file" 2>/dev/null)
            else
                last_activity=$(stat -c "%y" "$latest_file" 2>/dev/null | cut -d'.' -f1 | tr ' ' 'T')
            fi
        fi
    fi

    # Check for associated workers
    for worker_spec in "$PROJECT_ROOT/coordination/worker-specs/active"/*.json; do
        if [[ -f "$worker_spec" ]]; then
            local worker_task_id
            worker_task_id=$(jq -r '.task_id // ""' "$worker_spec" 2>/dev/null)
            if [[ "$worker_task_id" == "$task_id" ]]; then
                local heartbeat
                heartbeat=$(jq -r '.heartbeat.last_heartbeat // ""' "$worker_spec" 2>/dev/null)
                if [[ -n "$heartbeat" && "$heartbeat" != "null" ]]; then
                    if [[ -z "$last_activity" ]] || [[ "$heartbeat" > "$last_activity" ]]; then
                        last_activity="$heartbeat"
                    fi
                fi
            fi
        fi
    done

    # Fallback to task creation time
    if [[ -z "$last_activity" ]]; then
        for handoff in "$PROJECT_ROOT/coordination/masters"/*/handoffs/"$task_id".json; do
            if [[ -f "$handoff" ]]; then
                last_activity=$(jq -r '.created_at // ""' "$handoff" 2>/dev/null)
                break
            fi
        done
    fi

    echo "${last_activity:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

# Kill a stalled learning task
kill_learning_task() {
    local task_id="$1"
    local reason="$2"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log "⚠️  Killing stalled task: $task_id (reason: $reason)"

    # Find and kill associated workers
    for worker_spec in "$PROJECT_ROOT/coordination/worker-specs/active"/*.json; do
        if [[ -f "$worker_spec" ]]; then
            local worker_task_id
            worker_task_id=$(jq -r '.task_id // ""' "$worker_spec" 2>/dev/null)
            if [[ "$worker_task_id" == "$task_id" ]]; then
                local worker_id
                worker_id=$(basename "$worker_spec" .json)

                # Try to find and kill the worker process
                local pid
                pid=$(pgrep -f "$worker_id" 2>/dev/null || true)
                if [[ -n "$pid" ]]; then
                    kill -TERM "$pid" 2>/dev/null || true
                    log "  Killed worker process $pid for $worker_id"
                fi

                # Move worker spec to failed
                mkdir -p "$PROJECT_ROOT/coordination/worker-specs/failed"
                mv "$worker_spec" "$PROJECT_ROOT/coordination/worker-specs/failed/" 2>/dev/null || true
                log "  Moved $worker_id to failed"
            fi
        fi
    done

    # Update task status in queue
    if [[ -f "$PROJECT_ROOT/coordination/task-queue.json" ]]; then
        jq --arg tid "$task_id" \
           --arg ts "$timestamp" \
           --arg reason "$reason" \
           '(.tasks[] | select(.id == $tid)) |= (.status = "killed" | .updated_at = $ts | .kill_reason = $reason)' \
           "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue-kill.json && \
        mv /tmp/task-queue-kill.json "$PROJECT_ROOT/coordination/task-queue.json"
    fi

    # Update handoff status
    for handoff in "$PROJECT_ROOT/coordination/masters"/*/handoffs/"$task_id".json; do
        if [[ -f "$handoff" ]]; then
            jq --arg ts "$timestamp" --arg reason "$reason" \
               '.status = "killed" | .killed_at = $ts | .kill_reason = $reason' \
               "$handoff" > /tmp/handoff-kill.json && \
            mv /tmp/handoff-kill.json "$handoff"
        fi
    done

    # Emit kill event
    emit_event "task_killed" "$task_id" "{\"reason\":\"$reason\",\"threshold_minutes\":$STALL_THRESHOLD_MINUTES}"

    # Update metrics
    update_metrics "killed"
}

# Update monitoring metrics
update_metrics() {
    local action="$1"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Read current metrics or create new
    local current_metrics
    if [[ -f "$LEARNING_METRICS_FILE" ]]; then
        current_metrics=$(cat "$LEARNING_METRICS_FILE")
    else
        current_metrics='{}'
    fi

    # Update based on action
    case "$action" in
        "killed")
            echo "$current_metrics" | jq --arg ts "$timestamp" \
                '.total_killed = ((.total_killed // 0) + 1) | .last_kill = $ts | .last_updated = $ts' \
                > "$LEARNING_METRICS_FILE"
            ;;
        "completed")
            echo "$current_metrics" | jq --arg ts "$timestamp" \
                '.total_completed = ((.total_completed // 0) + 1) | .last_completed = $ts | .last_updated = $ts' \
                > "$LEARNING_METRICS_FILE"
            ;;
        "check")
            echo "$current_metrics" | jq --arg ts "$timestamp" \
                '.total_checks = ((.total_checks // 0) + 1) | .last_check = $ts | .last_updated = $ts' \
                > "$LEARNING_METRICS_FILE"
            ;;
    esac
}

# Main monitoring loop
monitor_tasks() {
    log "Starting monitoring loop (interval: ${SLEEP_INTERVAL}s, stall threshold: ${STALL_THRESHOLD_MINUTES}m)"

    while true; do
        local tasks_found=0
        local timestamp
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        # Find all learning tasks
        while IFS=':' read -r task_id source; do
            [[ -z "$task_id" ]] && continue
            ((tasks_found++))

            # Get task status
            local task_info
            task_info=$(get_task_info "$task_id" "$source")
            local status
            status=$(echo "$task_info" | jq -r '.status // "unknown"' 2>/dev/null)

            # Skip completed/killed tasks
            if [[ "$status" == "completed" || "$status" == "killed" ]]; then
                continue
            fi

            # Get activity metrics
            local deliverable_count
            deliverable_count=$(count_deliverables "$task_id")
            local last_activity
            last_activity=$(get_last_activity "$task_id")
            local minutes_idle
            minutes_idle=$(minutes_since "$last_activity")

            # Log status
            log "Task $task_id: status=$status, deliverables=$deliverable_count, idle=${minutes_idle}m"

            # Check for stall
            if [[ "$minutes_idle" -ge "$STALL_THRESHOLD_MINUTES" ]]; then
                kill_learning_task "$task_id" "No activity for ${minutes_idle} minutes (threshold: ${STALL_THRESHOLD_MINUTES}m)"
            else
                # Emit progress event
                emit_event "task_progress" "$task_id" "{\"status\":\"$status\",\"deliverables\":$deliverable_count,\"idle_minutes\":$minutes_idle}"
            fi

        done < <(find_learning_tasks)

        # Update check metrics
        update_metrics "check"

        if [[ "$tasks_found" -eq 0 ]]; then
            log "No active learning tasks found"
        fi

        sleep "$SLEEP_INTERVAL"
    done
}

# Signal handlers
cleanup() {
    log "Shutting down Learning Task Monitor..."
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Main entry point
main() {
    log "============================================"
    log "Learning Task Monitor Daemon starting..."
    log "============================================"
    log "Configuration:"
    log "  Check interval: ${SLEEP_INTERVAL}s"
    log "  Stall threshold: ${STALL_THRESHOLD_MINUTES} minutes"
    log "  Deliverables dir: $DELIVERABLES_DIR"
    log "  Events file: $LEARNING_EVENTS_FILE"
    log "============================================"

    # Write PID file
    echo $$ > "$PID_FILE"

    # Initialize state
    init_state

    # Start monitoring
    monitor_tasks
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
