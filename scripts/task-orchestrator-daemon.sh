#!/bin/bash

###############################################################################
# Task Orchestrator Daemon
#
# Purpose: Continuously monitors task queue for complex tasks requiring
#          orchestration and coordinates multi-master execution
#
# Layer: Between User Requests and Master Agents
# Type: Permanent Daemon
# Role: Strategic Project Manager
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COORD_DIR="$PROJECT_ROOT/coordination"
ORCH_DIR="$COORD_DIR/orchestrator"
TASK_QUEUE="$COORD_DIR/task-queue.json"
ORCH_STATE="$ORCH_DIR/state/current.json"
ORCH_TASKS_DIR="$ORCH_DIR/tasks"
ORCH_SUBTASKS_DIR="$ORCH_DIR/subtasks"
PROMPT_FILE="$PROJECT_ROOT/agents/prompts/orchestrator/task-orchestrator.md"
LOG_DIR="$PROJECT_ROOT/agents/logs/system"
LOG_FILE="$LOG_DIR/task-orchestrator-daemon.log"
PID_FILE="/tmp/task-orchestrator-daemon.pid"
EVENTS_FILE="$COORD_DIR/dashboard-events.jsonl"

# Polling interval
POLL_INTERVAL=10  # Check every 10 seconds

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

###############################################################################
# Logging Functions
###############################################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_orch() {
    echo -e "${PURPLE}[ORCHESTRATOR]${NC} $*" | tee -a "$LOG_FILE"
}

###############################################################################
# Dashboard Event Logging
###############################################################################

log_dashboard_event() {
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
    log_info "Initializing Task Orchestrator Daemon..."

    # Create directories
    mkdir -p "$LOG_DIR"
    mkdir -p "$ORCH_DIR"/{tasks,subtasks,state}

    # Initialize state file if doesn't exist
    if [ ! -f "$ORCH_STATE" ]; then
        cat > "$ORCH_STATE" <<EOF
{
  "active_orchestrations": 0,
  "total_orchestrations": 0,
  "completed_orchestrations": 0,
  "failed_orchestrations": 0,
  "current_orchestrations": [],
  "last_update": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
        log_info "Created initial orchestrator state file"
    fi

    # Write PID
    echo $$ > "$PID_FILE"
    log_info "Task Orchestrator Daemon started with PID: $$"

    # Log startup event
    log_dashboard_event "orchestrator_started" '{"pid":'$$'}'

    log_success "Initialization complete"
}

###############################################################################
# Task Queue Monitoring
###############################################################################

check_for_new_tasks() {
    if [ ! -f "$TASK_QUEUE" ]; then
        return 0
    fi

    # Find pending tasks that require orchestration
    local pending_tasks=$(jq -r '.tasks[] | select(.status == "pending") | select(.orchestration_required == true or .complexity == "high") | .id' "$TASK_QUEUE" 2>/dev/null || echo "")

    if [ -z "$pending_tasks" ]; then
        return 0
    fi

    # Process each pending task
    while IFS= read -r task_id; do
        if [ -n "$task_id" ]; then
            log_orch "Found task requiring orchestration: $task_id"
            orchestrate_task "$task_id"
        fi
    done <<< "$pending_tasks"
}

###############################################################################
# Task Orchestration
###############################################################################

orchestrate_task() {
    local task_id="$1"
    local orch_id="orch-$task_id"

    log_orch "Starting orchestration for task: $task_id"

    # Extract task data
    local task_data=$(jq --arg id "$task_id" '.tasks[] | select(.id == $id)' "$TASK_QUEUE")

    if [ -z "$task_data" ]; then
        log_error "Task $task_id not found in queue"
        return 1
    fi

    local task_title=$(echo "$task_data" | jq -r '.title')
    local task_description=$(echo "$task_data" | jq -r '.context.description // .title')

    log_info "Task: $task_title"

    # Create orchestration session using Claude Code
    log_orch "Invoking Task Orchestrator agent..."

    # Build orchestration prompt
    local orchestration_prompt=$(cat <<EOF
You are the Task Orchestrator. A new complex task has arrived that requires your strategic coordination.

TASK DETAILS:
- Task ID: $task_id
- Title: $task_title
- Description: $task_description

YOUR MISSION:
1. Analyze this task's complexity
2. If it's actually simple, route directly to the appropriate master (update task with assigned_to field)
3. If complex, decompose it into subtasks with clear dependencies
4. Create an orchestration plan with execution stages
5. Save the orchestration plan to: coordination/orchestrator/tasks/$orch_id.json
6. Create subtask specs in: coordination/orchestrator/subtasks/
7. Create handoffs for stage 1 subtasks to their assigned masters
8. Update orchestrator state in: coordination/orchestrator/state/current.json

Remember: You are a strategic thinker. Break down complexity into manageable, coordinated steps.

Orchestration ID: $orch_id
Start time: $(date +%Y-%m-%dT%H:%M:%S%z)

Read the full Task Orchestrator prompt at: $PROMPT_FILE
EOF
)

    # Create temporary prompt file
    local temp_prompt="/tmp/orchestrator-prompt-$task_id.txt"
    echo "$orchestration_prompt" > "$temp_prompt"

    log_info "Launching Task Orchestrator session..."

    # Launch Claude Code session in background
    # Note: In production, this would be an interactive Claude Code session
    # For now, we'll create a marker that the orchestration needs manual processing

    local orch_file="$ORCH_TASKS_DIR/$orch_id.json"
    cat > "$orch_file" <<EOF
{
  "orchestration_id": "$orch_id",
  "parent_task_id": "$task_id",
  "task_title": "$task_title",
  "status": "pending_analysis",
  "created_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "prompt_file": "$temp_prompt",
  "notes": "Awaiting Task Orchestrator agent analysis. Run: claude < $temp_prompt"
}
EOF

    log_success "Orchestration plan initialized: $orch_file"
    log_info "To complete orchestration, run: claude < $temp_prompt"

    # Update task queue to mark as being orchestrated
    local updated_queue=$(jq --arg id "$task_id" --arg orch "$orch_id" \
        '(.tasks[] | select(.id == $id)) |= . + {status: "orchestrating", orchestration_id: $orch, updated_at: (now | todate)}' \
        "$TASK_QUEUE")
    echo "$updated_queue" > "$TASK_QUEUE"

    # Log event
    log_dashboard_event "orchestration_created" "{\"orchestration_id\":\"$orch_id\",\"task_id\":\"$task_id\"}"

    log_success "Task $task_id marked as 'orchestrating'"
}

###############################################################################
# Progress Monitoring
###############################################################################

monitor_active_orchestrations() {
    # Check for active orchestrations and monitor their progress
    local active_orchs=$(find "$ORCH_TASKS_DIR" -name "*.json" -type f 2>/dev/null || echo "")

    if [ -z "$active_orchs" ]; then
        return 0
    fi

    while IFS= read -r orch_file; do
        if [ -f "$orch_file" ]; then
            local status=$(jq -r '.status' "$orch_file" 2>/dev/null || echo "unknown")

            case "$status" in
                "in_progress")
                    monitor_orchestration_progress "$orch_file"
                    ;;
                "blocked")
                    handle_blocked_orchestration "$orch_file"
                    ;;
                "pending_analysis")
                    # Skip - waiting for agent to analyze
                    ;;
            esac
        fi
    done <<< "$active_orchs"
}

monitor_orchestration_progress() {
    local orch_file="$1"
    local orch_id=$(jq -r '.orchestration_id' "$orch_file")

    # Check status of active subtasks
    local active_subtasks=$(jq -r '.progress.active_subtasks[]?' "$orch_file" 2>/dev/null || echo "")

    if [ -z "$active_subtasks" ]; then
        return 0
    fi

    log_info "Monitoring orchestration: $orch_id"

    # TODO: Check worker health for each active subtask
    # This will integrate with worker-specs directory
}

handle_blocked_orchestration() {
    local orch_file="$1"
    local orch_id=$(jq -r '.orchestration_id' "$orch_file")

    log_warn "Orchestration blocked: $orch_id"

    # TODO: Implement escalation logic
    # For now, just log
}

###############################################################################
# Main Loop
###############################################################################

main_loop() {
    log_success "Task Orchestrator Daemon running (polling every ${POLL_INTERVAL}s)"

    while true; do
        # Check for new tasks requiring orchestration
        check_for_new_tasks

        # Monitor active orchestrations
        monitor_active_orchestrations

        # Update state
        update_orchestrator_state

        # Sleep
        sleep "$POLL_INTERVAL"
    done
}

update_orchestrator_state() {
    # Count orchestrations by status
    local total=$(find "$ORCH_TASKS_DIR" -name "*.json" -type f | wc -l | tr -d ' ')
    local active=$(grep -l '"status":"in_progress"' "$ORCH_TASKS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local completed=$(grep -l '"status":"completed"' "$ORCH_TASKS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local failed=$(grep -l '"status":"failed"' "$ORCH_TASKS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')

    # Update state file
    cat > "$ORCH_STATE" <<EOF
{
  "active_orchestrations": $active,
  "total_orchestrations": $total,
  "completed_orchestrations": $completed,
  "failed_orchestrations": $failed,
  "current_orchestrations": [],
  "last_update": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log_warn "Shutting down Task Orchestrator Daemon..."
    log_dashboard_event "orchestrator_stopped" '{"reason":"shutdown"}'
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM

###############################################################################
# Entry Point
###############################################################################

# Check if already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_error "Task Orchestrator Daemon already running with PID: $OLD_PID"
        exit 1
    else
        log_warn "Removing stale PID file"
        rm -f "$PID_FILE"
    fi
fi

# Initialize and run
initialize
main_loop
