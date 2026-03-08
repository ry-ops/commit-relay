#!/bin/bash
###############################################################################
# Integration Validator Daemon
#
# Purpose: Validates all routing integration points and monitors routing
#          pipeline health in real-time
#
# Role: Routing Health Monitor - Ensures tasks flow correctly through system
# Responsibilities:
#   - Runtime health monitoring of routing pipelines
#   - Automatic detection of routing failures
#   - Alert generation when routing breaks
#   - Track metrics on routing success/failure rates
###############################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
COORD_DIR="$COMMIT_RELAY_HOME/coordination"
TASK_QUEUE="$COORD_DIR/task-queue.json"
ROUTING_HEALTH_FILE="$COORD_DIR/routing-health.json"
HEALTH_ALERTS_FILE="$COORD_DIR/health-alerts.json"
LOG_DIR="$COMMIT_RELAY_HOME/agents/logs/system"
LOG_FILE="$LOG_DIR/integration-validator.log"
PID_FILE="/tmp/commit-relay-integration-validator.pid"
EVENTS_FILE="$COORD_DIR/dashboard-events.jsonl"

# Monitoring intervals
CHECK_INTERVAL=60  # Check every 60 seconds
ROUTING_TIMEOUT=300  # Alert if task not routed within 5 minutes (300 seconds)
STALL_THRESHOLD=1800  # Alert if no tasks processed in 30 minutes (1800 seconds)

# Daemon name
DAEMON_NAME="commit-relay-integration-validator"

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
# Alert Creation
###############################################################################

create_alert() {
    local alert_type="$1"
    local severity="$2"
    local message="$3"

    log_daemon "ALERT: [$severity] $alert_type - $message"

    # Check if alerts file exists
    if [ ! -f "$HEALTH_ALERTS_FILE" ]; then
        cat > "$HEALTH_ALERTS_FILE" <<EOF
{
  "sla_config": {
    "critical": 15,
    "high": 30,
    "medium": 60,
    "low": 120
  },
  "alerts": []
}
EOF
    fi

    local alert_id="routing-$(date +%s)-$(echo "$alert_type" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)
    local sla_minutes=$(jq -r --arg sev "$severity" '.sla_config[$sev] // 60' "$HEALTH_ALERTS_FILE")

    # Check if alert already exists
    local existing=$(jq --arg id "$alert_id" --arg type "$alert_type" \
        '.alerts[] | select(.type == $type and .status == "active")' \
        "$HEALTH_ALERTS_FILE" 2>/dev/null || echo "")

    if [ -n "$existing" ]; then
        log_daemon "INFO: Alert for $alert_type already active, skipping creation"
        return
    fi

    # Add alert
    local temp_file=$(mktemp)
    jq --arg id "$alert_id" \
       --arg type "$alert_type" \
       --arg sev "$severity" \
       --arg msg "$message" \
       --arg ts "$timestamp" \
       --argjson sla "$sla_minutes" \
       '.alerts += [{
           "id": $id,
           "type": $type,
           "severity": $sev,
           "status": "active",
           "message": $msg,
           "created_at": $ts,
           "sla_minutes": $sla,
           "sla_breach_at": ($ts | fromdateiso8601 + ($sla * 60) | todateiso8601)
       }]' "$HEALTH_ALERTS_FILE" > "$temp_file" && mv "$temp_file" "$HEALTH_ALERTS_FILE"

    log_daemon "SUCCESS: Created alert: $alert_id"

    # Log event
    log_event "routing_alert_created" "{\"alert_id\":\"$alert_id\",\"type\":\"$alert_type\",\"severity\":\"$severity\"}"
}

###############################################################################
# Initialization
###############################################################################

initialize() {
    log_daemon "INFO: Initializing Integration Validator Daemon..."

    # Ensure directories exist
    mkdir -p "$LOG_DIR"
    mkdir -p "$COORD_DIR"

    # Initialize routing health file
    if [ ! -f "$ROUTING_HEALTH_FILE" ]; then
        cat > "$ROUTING_HEALTH_FILE" <<EOF
{
  "daemon_started_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "last_check": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "checks_performed": 0,
  "routing_metrics": {
    "tasks_pending": 0,
    "tasks_assigned": 0,
    "tasks_completed": 0,
    "tasks_failed": 0,
    "routing_success_rate": 100.0,
    "avg_routing_latency_seconds": 0
  },
  "current_issues": [],
  "last_successful_routing": null,
  "status": "healthy"
}
EOF
        log_daemon "INFO: Created initial routing health file"
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
    log_daemon "INFO: Integration validator daemon started (PID $$)"
    log_daemon "INFO: Check interval: ${CHECK_INTERVAL}s"
    log_daemon "INFO: Routing timeout: ${ROUTING_TIMEOUT}s"
    log_daemon "INFO: Stall threshold: ${STALL_THRESHOLD}s"

    # Log startup event
    log_event "integration_validator_started" '{"pid":'$$'}'
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log_daemon "INFO: Integration validator daemon stopping (PID $$)"
    log_event "integration_validator_stopped" '{"pid":'$$'}'
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

###############################################################################
# Routing Health Checks
###############################################################################

check_routing_pipeline() {
    log_daemon "INFO: Checking routing pipeline health..."

    # Check if task queue exists
    if [ ! -f "$TASK_QUEUE" ]; then
        log_daemon "WARN: Task queue not found"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$TASK_QUEUE" 2>/dev/null; then
        log_daemon "ERROR: Task queue contains invalid JSON"
        create_alert "task_queue_corrupted" "critical" "Task queue JSON is malformed and cannot be read"
        return 1
    fi

    # Count tasks by status
    local pending_count=$(jq -r '[.tasks[] | select(.status == "pending")] | length' "$TASK_QUEUE" 2>/dev/null || echo "0")
    local assigned_count=$(jq -r '[.tasks[] | select(.status == "assigned")] | length' "$TASK_QUEUE" 2>/dev/null || echo "0")
    local in_progress_count=$(jq -r '[.tasks[] | select(.status == "in_progress")] | length' "$TASK_QUEUE" 2>/dev/null || echo "0")
    local completed_count=$(jq -r '[.tasks[] | select(.status == "completed")] | length' "$TASK_QUEUE" 2>/dev/null || echo "0")
    local failed_count=$(jq -r '[.tasks[] | select(.status == "failed")] | length' "$TASK_QUEUE" 2>/dev/null || echo "0")

    log_daemon "INFO: Task counts - Pending: $pending_count, Assigned: $assigned_count, In Progress: $in_progress_count, Completed: $completed_count, Failed: $failed_count"

    # Check for stuck pending tasks (pending > routing timeout)
    local current_time=$(date +%s)
    local stuck_tasks=$(jq -r --arg current "$current_time" --arg timeout "$ROUTING_TIMEOUT" \
        '.tasks[] | select(.status == "pending") |
         select((.created_at | fromdateiso8601) < ($current | tonumber) - ($timeout | tonumber)) |
         .id' "$TASK_QUEUE" 2>/dev/null || echo "")

    if [ -n "$stuck_tasks" ]; then
        local stuck_count=$(echo "$stuck_tasks" | grep -v "^$" | wc -l | tr -d ' ')
        log_daemon "WARN: Found $stuck_count task(s) stuck in pending for > ${ROUTING_TIMEOUT}s"

        create_alert "tasks_stuck_pending" "high" "$stuck_count tasks stuck in pending state for over ${ROUTING_TIMEOUT} seconds - coordinator may not be routing"
    fi

    # Check if coordinator is running
    local coordinator_pid_file="/tmp/commit-relay-coordinator.pid"
    if [ ! -f "$coordinator_pid_file" ]; then
        log_daemon "ERROR: Coordinator daemon PID file not found"
        create_alert "coordinator_not_running" "critical" "Coordinator daemon is not running - tasks will not be routed"
    else
        local coordinator_pid=$(cat "$coordinator_pid_file")
        if ! ps -p "$coordinator_pid" > /dev/null 2>&1; then
            log_daemon "ERROR: Coordinator daemon (PID $coordinator_pid) is not running"
            create_alert "coordinator_not_running" "critical" "Coordinator daemon crashed or stopped - tasks will not be routed"
        else
            log_daemon "INFO: Coordinator daemon is running (PID $coordinator_pid)"
        fi
    fi

    # Check if worker daemon is running
    local worker_pid_file="/tmp/commit-relay-worker-daemon.pid"
    if [ ! -f "$worker_pid_file" ]; then
        log_daemon "WARN: Worker daemon PID file not found"
        create_alert "worker_daemon_not_running" "high" "Worker daemon is not running - workers will not be spawned"
    else
        local worker_pid=$(cat "$worker_pid_file")
        if ! ps -p "$worker_pid" > /dev/null 2>&1; then
            log_daemon "WARN: Worker daemon (PID $worker_pid) is not running"
            create_alert "worker_daemon_not_running" "high" "Worker daemon crashed or stopped - workers will not be spawned"
        else
            log_daemon "INFO: Worker daemon is running (PID $worker_pid)"
        fi
    fi

    # Calculate routing success rate
    local total_routed=$((assigned_count + in_progress_count + completed_count + failed_count))
    local total_tasks=$((pending_count + total_routed))
    local success_rate=100.0

    if [ "$total_tasks" -gt 0 ]; then
        success_rate=$(echo "scale=2; ($total_routed * 100.0) / $total_tasks" | bc)
    fi

    log_daemon "INFO: Routing success rate: ${success_rate}%"

    # Update routing health file
    local checks_performed=$(jq -r '.checks_performed // 0' "$ROUTING_HEALTH_FILE")
    checks_performed=$((checks_performed + 1))

    local health_status="healthy"
    if [ "$pending_count" -gt 0 ] && [ "$stuck_count" -gt 0 ]; then
        health_status="degraded"
    fi

    if [ ! -f "$coordinator_pid_file" ] || ! ps -p "$(cat "$coordinator_pid_file" 2>/dev/null || echo 0)" > /dev/null 2>&1; then
        health_status="critical"
    fi

    jq --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --argjson checks "$checks_performed" \
       --argjson pending "$pending_count" \
       --argjson assigned "$assigned_count" \
       --argjson completed "$completed_count" \
       --argjson failed "$failed_count" \
       --arg rate "$success_rate" \
       --arg status "$health_status" \
       '. + {
           last_check: $timestamp,
           checks_performed: $checks,
           routing_metrics: {
               tasks_pending: $pending,
               tasks_assigned: $assigned,
               tasks_completed: $completed,
               tasks_failed: $failed,
               routing_success_rate: ($rate | tonumber)
           },
           status: $status
       }' "$ROUTING_HEALTH_FILE" > "${ROUTING_HEALTH_FILE}.tmp" && mv "${ROUTING_HEALTH_FILE}.tmp" "$ROUTING_HEALTH_FILE"

    log_daemon "SUCCESS: Routing health check complete - Status: $health_status"
}

###############################################################################
# Main Daemon Loop
###############################################################################

main_loop() {
    log_daemon "INFO: Starting main integration validator loop"

    while true; do
        cd "$COMMIT_RELAY_HOME"

        # Run routing health checks
        check_routing_pipeline

        # Sleep before next check
        sleep "$CHECK_INTERVAL"
    done
}

###############################################################################
# Entry Point
###############################################################################

initialize
main_loop
