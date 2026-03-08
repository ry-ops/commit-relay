#!/bin/bash
###############################################################################
# Handoff Processor Daemon
#
# Purpose: Monitors master handoff directories and automatically creates
#          worker specs to enable autonomous task execution
#
# Role: Master Agent Automation - Bridges coordinator handoffs to workers
# Layer: Between Master Handoffs and Worker Specs
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
COORD_DIR="$COMMIT_RELAY_HOME/coordination"
MASTERS_DIR="$COORD_DIR/masters"
WORKER_SPECS_DIR="$COORD_DIR/worker-specs/active"
LOG_DIR="$COMMIT_RELAY_HOME/agents/logs/system"
LOG_FILE="$LOG_DIR/handoff-processor.log"
PID_FILE="/tmp/commit-relay-handoff-processor.pid"
EVENTS_FILE="$COORD_DIR/dashboard-events.jsonl"

# Polling interval
POLL_INTERVAL=10  # Check every 10 seconds

# Daemon name
DAEMON_NAME="commit-relay-handoff-processor"

###############################################################################
# Logging Functions
###############################################################################

log_daemon() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1" | tee -a "$LOG_FILE"
}

log_event() {
    local event_type="$1"
    local event_data="$2"
    local event_json=$(cat <<EOF
{"timestamp":"$(date +%Y-%m-%dT%H:%M:%S%z)","type":"$event_type","data":$event_data}
EOF
)
    echo "$event_json" >> "$EVENTS_FILE"
}

###############################################################################
# Worker Type Mapping
###############################################################################

get_worker_type_for_task() {
    local task_type="$1"
    local task_description="$2"

    # Map task types to worker types
    case "$task_type" in
        development|feature|bug-fix|refactor)
            echo "implementation-worker"
            ;;
        security|vulnerability|audit|cve|scan)
            echo "scan-worker"
            ;;
        inventory|catalog|documentation)
            echo "documentation-worker"
            ;;
        test|testing)
            echo "test-worker"
            ;;
        review)
            echo "review-worker"
            ;;
        *)
            # Default based on description keywords
            if echo "$task_description" | grep -qi "implement\|develop\|code\|feature"; then
                echo "implementation-worker"
            elif echo "$task_description" | grep -qi "test\|spec"; then
                echo "test-worker"
            elif echo "$task_description" | grep -qi "document\|readme"; then
                echo "documentation-worker"
            else
                echo "implementation-worker"  # Default
            fi
            ;;
    esac
}

###############################################################################
# Worker Spec Generation
###############################################################################

create_worker_spec_from_handoff() {
    local handoff_file="$1"
    local master_type="$2"

    log_daemon "Processing handoff: $(basename "$handoff_file")"

    # Read handoff data
    local handoff_data=$(cat "$handoff_file")
    local task_id=$(echo "$handoff_data" | jq -r '.task_id')
    local task_data=$(echo "$handoff_data" | jq -r '.task')
    local task_type=$(echo "$task_data" | jq -r '.type // "development"')
    local task_description=$(echo "$task_data" | jq -r '.description // ""')
    local task_priority=$(echo "$task_data" | jq -r '.priority // "medium"')

    # Determine worker type
    local worker_type=$(get_worker_type_for_task "$task_type" "$task_description")

    log_daemon "  Task: $task_id"
    log_daemon "  Type: $task_type → Worker: $worker_type"
    log_daemon "  Priority: $task_priority"

    # Generate unique worker ID
    local worker_id="worker-${worker_type#*-}-$(date +%s)-$(printf '%03d' $RANDOM)"

    # Spawn worker using spawn-worker script
    log_daemon "  Spawning worker: $worker_id"

    # Use spawn-worker.sh with governance bypass
    GOVERNANCE_BYPASS=true "$SCRIPT_DIR/spawn-worker.sh" \
        --type "$worker_type" \
        --task-id "$task_id" \
        --master "${master_type}-master" \
        --priority "$task_priority" \
        >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        log_daemon "  ✅ Worker spec created successfully"

        # Update handoff status
        local updated_handoff=$(echo "$handoff_data" | jq '.status = "processed" | .processed_at = "'$(date +%Y-%m-%dT%H:%M:%S%z)'" | .worker_id = "'$worker_id'"')
        echo "$updated_handoff" > "$handoff_file"

        # Log event
        log_event "handoff_processed" "{\"handoff_id\":\"$task_id\",\"worker_id\":\"$worker_id\",\"master\":\"$master_type\"}"

        return 0
    else
        log_daemon "  ❌ Failed to create worker spec"
        return 1
    fi
}

###############################################################################
# Handoff Monitoring
###############################################################################

process_pending_handoffs() {
    local processed_count=0
    local failed_count=0

    # Check each master's handoff directory
    for master in development security inventory cicd; do
        local handoff_dir="$MASTERS_DIR/$master/handoffs"

        if [ ! -d "$handoff_dir" ]; then
            continue
        fi

        # Find pending handoffs
        for handoff_file in "$handoff_dir"/*.json; do
            if [ ! -f "$handoff_file" ]; then
                continue
            fi

            # Check if handoff is pending
            local status=$(jq -r '.status // "pending"' "$handoff_file" 2>/dev/null)

            if [ "$status" = "pending" ]; then
                if create_worker_spec_from_handoff "$handoff_file" "$master"; then
                    ((processed_count++))
                else
                    ((failed_count++))
                fi
            fi
        done
    done

    if [ $processed_count -gt 0 ] || [ $failed_count -gt 0 ]; then
        log_daemon "Processed: $processed_count, Failed: $failed_count"
    fi
}

###############################################################################
# Initialization
###############################################################################

initialize() {
    log_daemon "INFO: Initializing Handoff Processor Daemon..."

    # Ensure directories exist
    mkdir -p "$LOG_DIR"
    mkdir -p "$WORKER_SPECS_DIR"

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
    log_daemon "INFO: Handoff processor daemon started (PID $$)"
    log_daemon "INFO: Poll interval: ${POLL_INTERVAL}s"
    log_daemon "INFO: Working directory: $COMMIT_RELAY_HOME"

    # Log startup event
    log_event "handoff_processor_started" "{\"pid\":$$}"
}

###############################################################################
# Main Loop
###############################################################################

main_loop() {
    log_daemon "INFO: Starting main handoff processing loop"

    while true; do
        process_pending_handoffs
        sleep "$POLL_INTERVAL"
    done
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log_daemon "INFO: Handoff processor daemon stopping"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

###############################################################################
# Entry Point
###############################################################################

initialize
main_loop
