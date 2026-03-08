#!/bin/bash
# scripts/pm-intervention.sh
# PM intervention actions library
# Provides functions for PM daemon to take corrective actions on workers

set -euo pipefail

# Configuration
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Directories
WORKER_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs"
CHECKINS_DIR="$COMMIT_RELAY_HOME/coordination/worker-checkins"
ALERTS_DIR="$COMMIT_RELAY_HOME/coordination/pm-alerts"
REQUESTS_DIR="$COMMIT_RELAY_HOME/coordination/pm-requests"
PM_ACTIVITY_LOG="$COMMIT_RELAY_HOME/coordination/pm-activity.jsonl"

# Logging function
log_intervention() {
    local action="$1"
    local worker_id="$2"
    local details="${3:-{}}"

    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [INTERVENTION] $action: $worker_id" >&2

    # Log to PM activity log
    local log_entry=$(jq -nc \
        --arg ts "$timestamp" \
        --arg pm "pm-001" \
        --arg evt "intervention_$action" \
        --arg wid "$worker_id" \
        --argjson data "$details" \
        '{timestamp: $ts, pm_id: $pm, event: $evt, worker_id: $wid, data: $data}')

    echo "$log_entry" >> "$PM_ACTIVITY_LOG"
}

# 1. Send warning to worker
# Creates a warning file that worker can see on next check-in
send_warning_to_worker() {
    local worker_id="$1"
    local warning_type="$2"  # "timeout" | "missed_checkin" | "stalled"
    local message="$3"

    local warning_file="$CHECKINS_DIR/${worker_id}-WARNING.json"

    jq -n \
        --arg wid "$worker_id" \
        --arg type "$warning_type" \
        --arg msg "$message" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            worker_id: $wid,
            warning_type: $type,
            message: $msg,
            timestamp: $ts,
            severity: "warning",
            action_required: "Check in within 5 minutes or will be escalated to master"
        }' > "$warning_file"

    log_intervention "warning_sent" "$worker_id" \
        "{\"type\": \"$warning_type\", \"message\": \"$message\"}"

    return 0
}

# 2. Escalate to master
# Creates an alert for the worker's parent master to handle
escalate_to_master() {
    local worker_id="$1"
    local issue_type="$2"  # "worker_stalled" | "timeout_exceeded" | "blocked" | etc.
    local details="$3"

    local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "ERROR: Worker spec not found: $worker_spec" >&2
        return 1
    fi

    local parent_master=$(jq -r '.parent_master // "unknown"' "$worker_spec")
    local task_id=$(jq -r '.task_id // "unknown"' "$worker_spec")

    local alert_id="alert-${worker_id}-${issue_type}"
    local alert_file="$ALERTS_DIR/pending/${alert_id}.json"

    jq -n \
        --arg aid "$alert_id" \
        --arg wid "$worker_id" \
        --arg tid "$task_id" \
        --arg master "$parent_master" \
        --arg issue "$issue_type" \
        --arg det "$details" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            alert_id: $aid,
            created_at: $ts,
            alert_type: $issue,
            severity: "high",
            worker_id: $wid,
            task_id: $tid,
            parent_master: $master,
            status: "pending",
            alert_data: {
                issue: $det,
                requires_human_review: false
            },
            pm_actions_taken: [],
            response: null
        }' > "$alert_file"

    log_intervention "escalated_to_master" "$worker_id" \
        "{\"alert_id\": \"$alert_id\", \"master\": \"$parent_master\", \"issue\": \"$issue_type\"}"

    return 0
}

# 3. Kill worker process
# Terminates worker process (gracefully then forcefully)
kill_worker_process() {
    local worker_id="$1"
    local reason="$2"

    # Find process ID
    # Look for Claude process with this worker ID in command line or environment
    local pid=$(ps aux | grep -i "claude" | grep "$worker_id" | grep -v grep | awk '{print $2}' | head -1)

    if [ -n "$pid" ]; then
        echo "Killing worker $worker_id (PID: $pid, reason: $reason)" >&2

        # Try graceful termination first (SIGTERM)
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2

        # Check if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Worker $worker_id did not respond to SIGTERM, sending SIGKILL" >&2
            kill -KILL "$pid" 2>/dev/null || true
            sleep 1
        fi

        # Verify killed
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "ERROR: Failed to kill worker $worker_id (PID: $pid)" >&2
            log_intervention "kill_failed" "$worker_id" \
                "{\"reason\": \"$reason\", \"pid\": $pid}"
            return 1
        else
            log_intervention "worker_killed" "$worker_id" \
                "{\"reason\": \"$reason\", \"pid\": $pid}"
        fi
    else
        echo "WARNING: No process found for worker $worker_id" >&2
        log_intervention "kill_no_process" "$worker_id" \
            "{\"reason\": \"$reason\"}"
    fi

    # Mark worker as failed
    mark_worker_failed "$worker_id" "$reason"

    return 0
}

# 4. Mark worker as failed
# Moves worker spec to failed directory with failure reason
mark_worker_failed() {
    local worker_id="$1"
    local reason="$2"

    local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"
    local failed_dir="$WORKER_SPECS_DIR/failed"

    if [ ! -f "$worker_spec" ]; then
        echo "WARNING: Worker spec not found: $worker_spec" >&2
        return 1
    fi

    # Update spec with failure information
    local temp_spec="/tmp/${worker_id}-failed.json"

    jq --arg reason "$reason" \
       --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --arg by "pm-daemon" \
       '.status = "failed" |
        .execution.failed_at = $ts |
        .execution.failure_reason = $reason |
        .execution.failed_by = $by' \
       "$worker_spec" > "$temp_spec"

    # Move to failed directory
    mv "$temp_spec" "$failed_dir/${worker_id}.json"

    # Remove from active directory
    rm -f "$worker_spec"

    log_intervention "worker_marked_failed" "$worker_id" \
        "{\"reason\": \"$reason\"}"

    return 0
}

# 5. Restart worker
# Spawns a new worker for the same task (after killing stalled one)
restart_worker() {
    local worker_id="$1"
    local reason="$2"

    local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "ERROR: Cannot restart - worker spec not found: $worker_spec" >&2
        return 1
    fi

    # Extract task information
    local task_id=$(jq -r '.task_id' "$worker_spec")
    local task_data=$(jq -r '.task_data' "$worker_spec")
    local parent_master=$(jq -r '.parent_master' "$worker_spec")
    local worker_type=$(jq -r '.worker_type' "$worker_spec")

    echo "Restarting worker $worker_id for task $task_id (reason: $reason)" >&2

    # Kill existing worker
    kill_worker_process "$worker_id" "$reason"

    # Create new worker spec
    local new_worker_id="${worker_type}-$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')"
    local new_spec="$WORKER_SPECS_DIR/active/${new_worker_id}.json"

    jq --arg wid "$new_worker_id" \
       --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --arg restart_from "$worker_id" \
       '.worker_id = $wid |
        .created_at = $ts |
        .status = "pending" |
        .execution = {restarted_from: $restart_from} |
        .context.restarted = true' \
       "$WORKER_SPECS_DIR/failed/${worker_id}.json" > "$new_spec"

    log_intervention "worker_restarted" "$new_worker_id" \
        "{\"original_worker\": \"$worker_id\", \"task_id\": \"$task_id\", \"reason\": \"$reason\"}"

    echo "New worker spawned: $new_worker_id" >&2

    return 0
}

# 6. Approve time extension
# Extends worker time limit
approve_time_extension() {
    local worker_id="$1"
    local extension_minutes="$2"
    local justification="$3"

    local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "ERROR: Worker spec not found: $worker_spec" >&2
        return 1
    fi

    # Get current time limit
    local current_limit=$(jq -r '.resources.time_limit_minutes // 60' "$worker_spec")
    local new_limit=$((current_limit + extension_minutes))

    # Update worker spec
    local temp_spec="/tmp/${worker_id}-extended.json"

    jq --arg new_limit "$new_limit" \
       --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --arg just "$justification" \
       '.resources.time_limit_minutes = ($new_limit | tonumber) |
        .execution.time_extensions = (.execution.time_extensions // []) +
        [{
            extended_at: $ts,
            extension_minutes: '$extension_minutes',
            new_limit_minutes: ($new_limit | tonumber),
            justification: $just
        }]' \
       "$worker_spec" > "$temp_spec"

    mv "$temp_spec" "$worker_spec"

    log_intervention "time_extension_granted" "$worker_id" \
        "{\"extension_minutes\": $extension_minutes, \"new_limit\": $new_limit, \"justification\": \"$justification\"}"

    echo "Time extension granted: +$extension_minutes minutes (new limit: $new_limit)" >&2

    return 0
}

# 7. Allocate additional resources
# Updates worker resource allocation (tokens, etc.)
allocate_resources() {
    local worker_id="$1"
    local resource_type="$2"  # "tokens" | "memory" | etc.
    local additional_amount="$3"
    local justification="$4"

    local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "ERROR: Worker spec not found: $worker_spec" >&2
        return 1
    fi

    case "$resource_type" in
        tokens)
            local current=$(jq -r '.resources.token_allocation // 10000' "$worker_spec")
            local new_allocation=$((current + additional_amount))

            jq --arg new_alloc "$new_allocation" \
               --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
               --arg just "$justification" \
               '.resources.token_allocation = ($new_alloc | tonumber) |
                .execution.resource_adjustments = (.execution.resource_adjustments // []) +
                [{
                    adjusted_at: $ts,
                    resource_type: "tokens",
                    additional_amount: '$additional_amount',
                    new_allocation: ($new_alloc | tonumber),
                    justification: $just
                }]' \
               "$worker_spec" > "${worker_spec}.tmp"

            mv "${worker_spec}.tmp" "$worker_spec"

            log_intervention "resources_allocated" "$worker_id" \
                "{\"type\": \"$resource_type\", \"amount\": $additional_amount, \"new_total\": $new_allocation}"

            echo "Additional $resource_type allocated: +$additional_amount (new total: $new_allocation)" >&2
            ;;

        *)
            echo "ERROR: Unknown resource type '$resource_type'" >&2
            return 1
            ;;
    esac

    return 0
}

# 8. Handle worker request
# Processes pending worker request
handle_worker_request() {
    local request_file="$1"

    if [ ! -f "$request_file" ]; then
        echo "ERROR: Request file not found: $request_file" >&2
        return 1
    fi

    local request_id=$(jq -r '.request_id' "$request_file")
    local worker_id=$(jq -r '.worker_id' "$request_file")
    local request_type=$(jq -r '.request_type' "$request_file")

    echo "Processing request $request_id from $worker_id (type: $request_type)" >&2

    case "$request_type" in
        need_time)
            # Auto-approve time extensions ≤ 30 minutes
            local requested=$(jq -r '.time_extension.requested_extension_minutes // 0' "$request_file")
            local justification=$(jq -r '.time_extension.justification // "No justification provided"' "$request_file")

            if [ "$requested" -le 30 ]; then
                approve_time_extension "$worker_id" "$requested" "$justification"

                # Mark request as approved
                jq '.status = "approved" |
                    .response = {
                        responded_by: "pm-daemon",
                        responded_at: "'$(date +%Y-%m-%dT%H:%M:%S%z)'",
                        decision: "approved",
                        response_message: "Time extension approved automatically"
                    }' "$request_file" > "${request_file}.tmp"

                mv "${request_file}.tmp" "$REQUESTS_DIR/processed/${request_id}.json"
                rm -f "$request_file"
            else
                # Escalate to master for large extensions
                escalate_request_to_master "$request_file"
            fi
            ;;

        need_resources)
            # Auto-approve token requests ≤ 5000
            local requested=$(jq -r '.resource_request.requested_additional // 0' "$request_file")
            local resource_type=$(jq -r '.resource_request.resource_type // "tokens"' "$request_file")
            local justification=$(jq -r '.resource_request.justification // "No justification provided"' "$request_file")

            if [ "$requested" -le 5000 ] && [ "$resource_type" = "tokens" ]; then
                allocate_resources "$worker_id" "$resource_type" "$requested" "$justification"

                # Mark request as approved
                jq '.status = "approved" |
                    .response = {
                        responded_by: "pm-daemon",
                        responded_at: "'$(date +%Y-%m-%dT%H:%M:%S%z)'",
                        decision: "approved",
                        response_message: "Resource allocation approved automatically"
                    }' "$request_file" > "${request_file}.tmp"

                mv "${request_file}.tmp" "$REQUESTS_DIR/processed/${request_id}.json"
                rm -f "$request_file"
            else
                # Escalate to master for large resource requests
                escalate_request_to_master "$request_file"
            fi
            ;;

        need_clarification|blocked|need_help)
            # Always escalate to master
            escalate_request_to_master "$request_file"
            ;;

        *)
            echo "WARNING: Unknown request type '$request_type'" >&2
            escalate_request_to_master "$request_file"
            ;;
    esac

    return 0
}

# 9. Escalate request to master
# Converts worker request into master alert
escalate_request_to_master() {
    local request_file="$1"

    local request_id=$(jq -r '.request_id' "$request_file")
    local worker_id=$(jq -r '.worker_id' "$request_file")
    local request_type=$(jq -r '.request_type' "$request_file")
    local message=$(jq -r '.message' "$request_file")

    echo "Escalating request $request_id to master" >&2

    # Create alert from request
    escalate_to_master "$worker_id" "worker_request" \
        "Worker request: $request_type - $message"

    # Mark request as escalated
    jq '.status = "escalated" |
        .escalated_at = "'$(date +%Y-%m-%dT%H:%M:%S%z)'" |
        .escalated_by = "pm-daemon"' \
        "$request_file" > "${request_file}.tmp"

    mv "${request_file}.tmp" "$request_file"

    log_intervention "request_escalated" "$worker_id" \
        "{\"request_id\": \"$request_id\", \"type\": \"$request_type\"}"

    return 0
}

# Export functions for use in PM daemon
export -f send_warning_to_worker
export -f escalate_to_master
export -f kill_worker_process
export -f mark_worker_failed
export -f restart_worker
export -f approve_time_extension
export -f allocate_resources
export -f handle_worker_request
export -f escalate_request_to_master

# If executed directly (not sourced), show usage
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    cat << 'EOF'
PM Intervention Actions Library

This script provides functions for PM daemon to take corrective actions on workers.

USAGE (source this script in PM daemon):
    source scripts/pm-intervention.sh

FUNCTIONS:

1. send_warning_to_worker <worker_id> <type> <message>
   Creates warning file for worker to see on next check-in

2. escalate_to_master <worker_id> <issue_type> <details>
   Creates alert for worker's parent master to handle

3. kill_worker_process <worker_id> <reason>
   Terminates worker process (graceful then forceful)

4. mark_worker_failed <worker_id> <reason>
   Moves worker spec to failed directory

5. restart_worker <worker_id> <reason>
   Kills stalled worker and spawns replacement

6. approve_time_extension <worker_id> <minutes> <justification>
   Extends worker time limit

7. allocate_resources <worker_id> <type> <amount> <justification>
   Increases worker resource allocation

8. handle_worker_request <request_file>
   Processes pending worker request (auto-approve or escalate)

9. escalate_request_to_master <request_file>
   Converts worker request into master alert

EXAMPLES:

    # Send warning to late worker
    send_warning_to_worker "dev-worker-ABC123" "missed_checkin" \
        "Please check in within 5 minutes"

    # Escalate stalled worker to master
    escalate_to_master "dev-worker-ABC123" "worker_stalled" \
        "No check-in for 25 minutes"

    # Kill zombie worker
    kill_worker_process "dev-worker-ABC123" "zombie_detected"

    # Restart stalled worker
    restart_worker "dev-worker-ABC123" "stalled_no_progress"

    # Approve time extension
    approve_time_extension "dev-worker-ABC123" 30 "Test suite taking longer"

    # Allocate more tokens
    allocate_resources "dev-worker-ABC123" "tokens" 5000 \
        "Complex implementation requires more analysis"

    # Process worker request
    handle_worker_request "coordination/pm-requests/pending/req-12345.json"

EOF
    exit 0
fi
