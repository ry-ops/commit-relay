#!/bin/bash
###############################################################################
# Coordinator Daemon
#
# Purpose: Continuously monitors task queue and routes tasks to appropriate
#          master agents using MoE (Mixture of Experts) pattern matching
#
# Role: Task Router - Routes pending tasks from queue to masters via handoffs
# Layer: Between Task Queue and Master Agents
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
COORD_DIR="$COMMIT_RELAY_HOME/coordination"
TASK_QUEUE="$COORD_DIR/task-queue.json"
MASTERS_DIR="$COORD_DIR/masters"
MOE_ROUTER="$MASTERS_DIR/coordinator/lib/moe-router.sh"
STATE_FILE="$COORD_DIR/orchestrator/state/current.json"
LOG_DIR="$COMMIT_RELAY_HOME/agents/logs/system"
LOG_FILE="$LOG_DIR/coordinator-daemon.log"
PID_FILE="/tmp/commit-relay-coordinator.pid"
EVENTS_FILE="$COORD_DIR/dashboard-events.jsonl"

# Polling interval
POLL_INTERVAL=15  # Check every 15 seconds

# Daemon name
DAEMON_NAME="commit-relay-coordinator"

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
# Initialization
###############################################################################

initialize() {
    log_daemon "INFO: Initializing Coordinator Daemon..."

    # Ensure directories exist
    mkdir -p "$LOG_DIR"
    mkdir -p "$COORD_DIR/orchestrator/state"
    mkdir -p "$MASTERS_DIR"

    # Check if MoE router exists
    if [ ! -f "$MOE_ROUTER" ]; then
        log_daemon "ERROR: MoE router not found at: $MOE_ROUTER"
        log_daemon "ERROR: Cannot route tasks without MoE router"
        exit 1
    fi

    # Initialize state file
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" <<EOF
{
  "started_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "tasks_routed": 0,
  "tasks_failed": 0,
  "last_check": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
        log_daemon "INFO: Created initial coordinator state file"
    fi

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
    log_daemon "INFO: Coordinator daemon started (PID $$)"
    log_daemon "INFO: Poll interval: ${POLL_INTERVAL}s"
    log_daemon "INFO: Working directory: $COMMIT_RELAY_HOME"

    # Log startup event
    log_event "coordinator_started" '{"pid":'$$'}'
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log_daemon "INFO: Coordinator daemon stopping (PID $$)"
    log_event "coordinator_stopped" '{"pid":'$$'}'
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

###############################################################################
# Task Routing
###############################################################################

route_task() {
    local task_id="$1"
    local task_data="$2"

    log_daemon "INFO: Routing task: $task_id"

    # Extract task information
    local task_title=$(echo "$task_data" | jq -r '.title // "Untitled"')
    local task_type=$(echo "$task_data" | jq -r '.type // "general"')
    local task_priority=$(echo "$task_data" | jq -r '.priority // "medium"')

    log_daemon "INFO:   Title: $task_title"
    log_daemon "INFO:   Type: $task_type"
    log_daemon "INFO:   Priority: $task_priority"

    # Use MoE router to determine best master
    log_daemon "INFO: Consulting MoE router for master assignment..."

    # Prepare task description for router (combines title and type)
    local task_description="$task_title (type: $task_type, priority: $task_priority)"

    # Call MoE router with proper arguments and error handling
    local assigned_master=""
    local routing_output=""

    if [ -x "$MOE_ROUTER" ]; then
        # Call router with task_id and task_description as args (with governance bypass)
        routing_output=$(GOVERNANCE_BYPASS=true bash "$MOE_ROUTER" "$task_id" "$task_description" 2>&1) || {
            local router_exit=$?
            log_daemon "WARN: MoE router failed with exit code $router_exit"
            log_daemon "WARN: Router output: $routing_output"
        }

        # Extract primary expert from routing decision
        if [ -n "$routing_output" ]; then
            assigned_master=$(echo "$routing_output" | jq -r '.decision.primary_expert // ""' 2>/dev/null)

            # Log routing decision details
            local confidence=$(echo "$routing_output" | jq -r '.decision.primary_confidence // 0' 2>/dev/null)
            local strategy=$(echo "$routing_output" | jq -r '.decision.strategy // ""' 2>/dev/null)

            if [ -n "$assigned_master" ] && [ "$assigned_master" != "null" ]; then
                log_daemon "SUCCESS: MoE router assigned to: $assigned_master (confidence: ${confidence}%, strategy: $strategy)"
            fi
        fi
    else
        log_daemon "WARN: MoE router script not executable: $MOE_ROUTER"
    fi

    # Fallback if router fails or returns no master
    if [ -z "$assigned_master" ] || [ "$assigned_master" = "null" ]; then
        log_daemon "WARN: MoE router did not return a master, using fallback routing"

        # Simple fallback routing based on task type
        case "$task_type" in
            security|security-scan|audit|vulnerability)
                assigned_master="security"
                ;;
            build|test|deploy|release|ci|cd|cicd)
                assigned_master="cicd"
                ;;
            catalog|inventory|documentation|docs)
                assigned_master="inventory"
                ;;
            *)
                assigned_master="development"
                ;;
        esac
        log_daemon "INFO: Fallback routing assigned to: $assigned_master"
    fi

    # Create handoff for the assigned master
    local handoff_dir="$MASTERS_DIR/$assigned_master/handoffs"
    mkdir -p "$handoff_dir"

    local handoff_file="$handoff_dir/$task_id.json"
    local handoff_data=$(jq -n \
        --arg task_id "$task_id" \
        --arg master "$assigned_master" \
        --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson task "$task_data" \
        '{
            handoff_id: $task_id,
            task_id: $task_id,
            assigned_to: $master,
            created_at: $timestamp,
            status: "pending",
            task: $task
        }')

    echo "$handoff_data" > "$handoff_file"
    log_daemon "SUCCESS: Created handoff: $handoff_file"

    # Update task in queue with assigned_to field
    local updated_queue=$(jq --arg id "$task_id" \
        --arg master "$assigned_master" \
        --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '(.tasks[] | select(.id == $id)) |= . + {
            status: "assigned",
            assigned_to: $master,
            assigned_at: $timestamp
        }' "$TASK_QUEUE")

    echo "$updated_queue" > "$TASK_QUEUE"
    log_daemon "SUCCESS: Updated task status to 'assigned'"

    # Update coordinator state
    local tasks_routed=$(jq -r '.tasks_routed // 0' "$STATE_FILE")
    tasks_routed=$((tasks_routed + 1))

    jq --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --argjson count "$tasks_routed" \
       '. + {
           tasks_routed: $count,
           last_check: $timestamp
       }' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    # Log event
    log_event "task_assigned" "{\"task_id\":\"$task_id\",\"assigned_to\":\"$assigned_master\",\"task_title\":\"$task_title\"}"

    log_daemon "SUCCESS: Task $task_id routed to $assigned_master"
}

###############################################################################
# Task Queue Monitoring
###############################################################################

check_pending_tasks() {
    # Check if task queue exists
    if [ ! -f "$TASK_QUEUE" ]; then
        log_daemon "DEBUG: Task queue not found, creating empty queue"
        echo '{"tasks":[]}' > "$TASK_QUEUE"
        return 0
    fi

    # Validate JSON
    if ! jq empty "$TASK_QUEUE" 2>/dev/null; then
        log_daemon "ERROR: Task queue contains invalid JSON"
        return 1
    fi

    # Find pending tasks
    local pending_count=$(jq -r '[.tasks[] | select(.status == "pending")] | length' "$TASK_QUEUE" 2>/dev/null || echo "0")

    if [ "$pending_count" -eq 0 ]; then
        return 0
    fi

    log_daemon "INFO: Found $pending_count pending task(s) in queue"

    # Process each pending task
    local task_ids=$(jq -r '.tasks[] | select(.status == "pending") | .id' "$TASK_QUEUE" 2>/dev/null)

    while IFS= read -r task_id; do
        if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
            # Get full task data
            local task_data=$(jq --arg id "$task_id" '.tasks[] | select(.id == $id)' "$TASK_QUEUE")

            if [ -n "$task_data" ]; then
                route_task "$task_id" "$task_data"
            fi
        fi
    done <<< "$task_ids"
}

###############################################################################
# Main Daemon Loop
###############################################################################

main_loop() {
    log_daemon "INFO: Starting main coordinator loop"

    while true; do
        cd "$COMMIT_RELAY_HOME"

        # Update state with current timestamp
        jq --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
           '. + {last_check: $timestamp}' \
           "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

        # Pull latest coordination state (optional, fail silently)
        git pull origin main --quiet 2>/dev/null || true

        # Check for pending tasks and route them
        check_pending_tasks

        # Sleep before next check
        sleep "$POLL_INTERVAL"
    done
}

###############################################################################
# Entry Point
###############################################################################

initialize
main_loop
