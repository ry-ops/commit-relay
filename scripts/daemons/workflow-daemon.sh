#!/bin/bash

# Workflow Daemon
# Monitors and executes scheduled workflows based on cron triggers
#
# Features:
# - Loads workflow schedules from YAML files
# - Executes workflows at scheduled times
# - Handles webhook triggers
# - Logs execution history
# - Supports daemon mode for continuous operation

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COORD_DIR="$PROJECT_ROOT/coordination"
WORKFLOWS_DIR="$COORD_DIR/workflows"
EXECUTIONS_DIR="$COORD_DIR/workflow-executions"
PIDS_DIR="$COORD_DIR/pids"
METRICS_DIR="$COORD_DIR/metrics"

# Daemon settings
PID_FILE="$PIDS_DIR/workflow-daemon.pid"
LOG_FILE="$COORD_DIR/logs/workflow-daemon.log"
METRICS_FILE="$METRICS_DIR/workflow-daemon-metrics.json"
CHECK_INTERVAL=${WORKFLOW_CHECK_INTERVAL:-60}  # Check every 60 seconds
API_URL=${DASHBOARD_URL:-"http://localhost:3000"}
API_KEY=${DASHBOARD_API_KEY:-""}

# Ensure directories exist
mkdir -p "$PIDS_DIR" "$EXECUTIONS_DIR" "$(dirname "$LOG_FILE")" "$METRICS_DIR"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Initialize metrics
init_metrics() {
    cat > "$METRICS_FILE" << EOF
{
  "daemon_started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_check": null,
  "total_checks": 0,
  "total_executions": 0,
  "successful_executions": 0,
  "failed_executions": 0,
  "scheduled_workflows": {},
  "last_execution": null
}
EOF
}

# Update metrics
update_metrics() {
    local field="$1"
    local value="$2"

    if [[ -f "$METRICS_FILE" ]]; then
        local tmp_file=$(mktemp)
        jq --arg field "$field" --arg value "$value" \
            '.[$field] = $value' "$METRICS_FILE" > "$tmp_file" && mv "$tmp_file" "$METRICS_FILE"
    fi
}

# Increment metric counter
increment_metric() {
    local field="$1"

    if [[ -f "$METRICS_FILE" ]]; then
        local tmp_file=$(mktemp)
        jq --arg field "$field" \
            '.[$field] = (.[$field] + 1)' "$METRICS_FILE" > "$tmp_file" && mv "$tmp_file" "$METRICS_FILE"
    fi
}

# Parse cron expression and check if it matches current time
# Simplified cron matching for: minute hour day-of-month month day-of-week
matches_cron() {
    local cron_expr="$1"

    # Parse cron expression (minute hour day month weekday)
    local cron_minute=$(echo "$cron_expr" | awk '{print $1}')
    local cron_hour=$(echo "$cron_expr" | awk '{print $2}')
    local cron_day=$(echo "$cron_expr" | awk '{print $3}')
    local cron_month=$(echo "$cron_expr" | awk '{print $4}')
    local cron_weekday=$(echo "$cron_expr" | awk '{print $5}')

    # Get current time components
    local curr_minute=$(date +%M | sed 's/^0//')
    local curr_hour=$(date +%H | sed 's/^0//')
    local curr_day=$(date +%d | sed 's/^0//')
    local curr_month=$(date +%m | sed 's/^0//')
    local curr_weekday=$(date +%u)  # 1=Monday, 7=Sunday

    # Handle empty values
    [[ -z "$curr_minute" ]] && curr_minute=0
    [[ -z "$curr_hour" ]] && curr_hour=0
    [[ -z "$curr_day" ]] && curr_day=1
    [[ -z "$curr_month" ]] && curr_month=1

    # Check each component (supports * and specific values)
    check_cron_field() {
        local cron_val="$1"
        local curr_val="$2"

        [[ "$cron_val" == "*" ]] && return 0
        [[ "$cron_val" == "$curr_val" ]] && return 0

        # Check for intervals like */5
        if [[ "$cron_val" == *"/"* ]]; then
            local interval=$(echo "$cron_val" | cut -d'/' -f2)
            [[ $((curr_val % interval)) -eq 0 ]] && return 0
        fi

        return 1
    }

    check_cron_field "$cron_minute" "$curr_minute" || return 1
    check_cron_field "$cron_hour" "$curr_hour" || return 1
    check_cron_field "$cron_day" "$curr_day" || return 1
    check_cron_field "$cron_month" "$curr_month" || return 1
    check_cron_field "$cron_weekday" "$curr_weekday" || return 1

    return 0
}

# Extract schedule from workflow YAML
get_workflow_schedule() {
    local workflow_file="$1"

    # Use yq or grep to extract schedule
    if command -v yq &> /dev/null; then
        yq -r '.triggers[] | select(.type == "schedule" or .type == "cron") | .schedule // empty' "$workflow_file" 2>/dev/null
    else
        # Fallback to grep
        grep -A1 'type: schedule\|type: cron' "$workflow_file" | grep 'schedule:' | sed 's/.*schedule:\s*["'\'']\?\([^"'\'']*\)["'\'']\?.*/\1/'
    fi
}

# Execute a workflow via API
execute_workflow() {
    local workflow_name="$1"
    local inputs="${2:-{}}"

    log "INFO" "Executing workflow: $workflow_name"

    local response
    local http_code

    # Build curl command
    local curl_cmd="curl -s -w '%{http_code}' -X POST '$API_URL/api/v1/workflows/$workflow_name/execute'"
    curl_cmd+=" -H 'Content-Type: application/json'"

    if [[ -n "$API_KEY" ]]; then
        curl_cmd+=" -H 'X-API-Key: $API_KEY'"
    fi

    curl_cmd+=" -d '{\"inputs\": $inputs, \"options\": {\"async\": true}}'"

    # Execute
    response=$(eval "$curl_cmd" 2>/dev/null)
    http_code="${response: -3}"
    response="${response%???}"

    if [[ "$http_code" == "200" || "$http_code" == "202" ]]; then
        local exec_id=$(echo "$response" | jq -r '.data.execution_id // "unknown"')
        log "INFO" "Workflow $workflow_name started: execution_id=$exec_id"
        increment_metric "successful_executions"
        update_metrics "last_execution" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        return 0
    else
        log "ERROR" "Failed to execute workflow $workflow_name: HTTP $http_code - $response"
        increment_metric "failed_executions"
        return 1
    fi
}

# Check all workflows for scheduled execution
check_scheduled_workflows() {
    log "DEBUG" "Checking scheduled workflows..."

    update_metrics "last_check" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    increment_metric "total_checks"

    # Find all workflow files
    for workflow_file in "$WORKFLOWS_DIR"/*.yaml "$WORKFLOWS_DIR"/*.yml; do
        [[ -f "$workflow_file" ]] || continue

        local workflow_name=$(basename "$workflow_file" | sed 's/\.\(yaml\|yml\)$//')
        local schedule=$(get_workflow_schedule "$workflow_file")

        if [[ -n "$schedule" ]]; then
            if matches_cron "$schedule"; then
                log "INFO" "Schedule matched for workflow: $workflow_name (cron: $schedule)"
                execute_workflow "$workflow_name" "{}"
                increment_metric "total_executions"
            fi
        fi
    done
}

# Check for pending webhook triggers
check_webhook_triggers() {
    local triggers_dir="$COORD_DIR/workflow-triggers"

    [[ -d "$triggers_dir" ]] || return 0

    for trigger_file in "$triggers_dir"/*.json; do
        [[ -f "$trigger_file" ]] || continue

        local workflow_name=$(jq -r '.workflow_name' "$trigger_file")
        local inputs=$(jq -r '.inputs // {}' "$trigger_file")
        local status=$(jq -r '.status // "pending"' "$trigger_file")

        if [[ "$status" == "pending" ]]; then
            log "INFO" "Processing webhook trigger for: $workflow_name"

            # Mark as processing
            jq '.status = "processing"' "$trigger_file" > "$trigger_file.tmp" && mv "$trigger_file.tmp" "$trigger_file"

            if execute_workflow "$workflow_name" "$inputs"; then
                # Mark as completed and archive
                jq '.status = "completed"' "$trigger_file" > "$trigger_file.tmp" && mv "$trigger_file.tmp" "$trigger_file"
                mv "$trigger_file" "$triggers_dir/completed/"
            else
                # Mark as failed
                jq '.status = "failed"' "$trigger_file" > "$trigger_file.tmp" && mv "$trigger_file.tmp" "$trigger_file"
            fi
        fi
    done
}

# Main daemon loop
daemon_loop() {
    log "INFO" "Workflow daemon starting (check interval: ${CHECK_INTERVAL}s)"
    init_metrics

    while true; do
        check_scheduled_workflows
        check_webhook_triggers

        sleep "$CHECK_INTERVAL"
    done
}

# Start daemon
start_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local existing_pid=$(cat "$PID_FILE")
        if kill -0 "$existing_pid" 2>/dev/null; then
            log "WARN" "Daemon already running with PID $existing_pid"
            exit 1
        else
            log "INFO" "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi

    log "INFO" "Starting workflow daemon..."

    # Run in background
    nohup "$0" run >> "$LOG_FILE" 2>&1 &
    local daemon_pid=$!

    echo "$daemon_pid" > "$PID_FILE"
    log "INFO" "Workflow daemon started with PID $daemon_pid"

    echo "Workflow daemon started (PID: $daemon_pid)"
    echo "Log file: $LOG_FILE"
    echo "Metrics: $METRICS_FILE"
}

# Stop daemon
stop_daemon() {
    if [[ ! -f "$PID_FILE" ]]; then
        log "WARN" "No PID file found - daemon may not be running"
        exit 0
    fi

    local pid=$(cat "$PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        log "INFO" "Stopping workflow daemon (PID: $pid)..."
        kill "$pid"
        rm -f "$PID_FILE"
        log "INFO" "Workflow daemon stopped"
        echo "Workflow daemon stopped"
    else
        log "WARN" "Process $pid not running - removing stale PID file"
        rm -f "$PID_FILE"
    fi
}

# Show daemon status
show_status() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Workflow daemon is running (PID: $pid)"

            if [[ -f "$METRICS_FILE" ]]; then
                echo ""
                echo "Metrics:"
                jq '.' "$METRICS_FILE"
            fi
        else
            echo "Workflow daemon is not running (stale PID file)"
        fi
    else
        echo "Workflow daemon is not running"
    fi
}

# Execute single workflow (for testing)
execute_single() {
    local workflow_name="$1"
    local inputs="${2:-{}}"

    if [[ -z "$workflow_name" ]]; then
        echo "Usage: $0 execute <workflow-name> [inputs-json]"
        exit 1
    fi

    execute_workflow "$workflow_name" "$inputs"
}

# List workflows with schedules
list_workflows() {
    echo "Workflows with schedules:"
    echo "========================="

    for workflow_file in "$WORKFLOWS_DIR"/*.yaml "$WORKFLOWS_DIR"/*.yml; do
        [[ -f "$workflow_file" ]] || continue

        local workflow_name=$(basename "$workflow_file" | sed 's/\.\(yaml\|yml\)$//')
        local schedule=$(get_workflow_schedule "$workflow_file")

        if [[ -n "$schedule" ]]; then
            echo "  $workflow_name: $schedule"
        else
            echo "  $workflow_name: (no schedule)"
        fi
    done
}

# Main entry point
case "${1:-}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 2
        start_daemon
        ;;
    status)
        show_status
        ;;
    run)
        daemon_loop
        ;;
    execute)
        execute_single "${2:-}" "${3:-{}}"
        ;;
    list)
        list_workflows
        ;;
    check)
        check_scheduled_workflows
        ;;
    *)
        echo "Workflow Daemon - Scheduled workflow execution"
        echo ""
        echo "Usage: $0 {start|stop|restart|status|run|execute|list|check}"
        echo ""
        echo "Commands:"
        echo "  start     - Start daemon in background"
        echo "  stop      - Stop running daemon"
        echo "  restart   - Restart daemon"
        echo "  status    - Show daemon status and metrics"
        echo "  run       - Run daemon in foreground"
        echo "  execute   - Execute single workflow"
        echo "  list      - List workflows and schedules"
        echo "  check     - Run single schedule check"
        echo ""
        echo "Environment variables:"
        echo "  WORKFLOW_CHECK_INTERVAL - Check interval in seconds (default: 60)"
        echo "  DASHBOARD_URL          - API server URL (default: http://localhost:3000)"
        echo "  DASHBOARD_API_KEY      - API authentication key"
        exit 1
        ;;
esac
