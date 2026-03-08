#!/bin/bash
# scripts/pm-daemon.sh
# Project Manager Daemon - Monitors workers and ensures task completion
# Part of commit-relay autonomous automation system

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Configuration
PM_ID="pm-001"
PM_VERSION="1.0.0"
LOOP_INTERVAL="${PM_LOOP_INTERVAL:-180}"  # 3 minutes
SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-300}"  # 5 minutes for historical snapshots
TEST_MODE="${1:-}"

# Paths
PM_STATE_FILE="$COMMIT_RELAY_HOME/coordination/pm-state.json"
PM_ACTIVITY_LOG="$COMMIT_RELAY_HOME/coordination/pm-activity.jsonl"
PID_FILE="/tmp/pm-daemon.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log"

# Directories
WORKER_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs"
CHECKINS_DIR="$COMMIT_RELAY_HOME/coordination/worker-checkins"
REQUESTS_DIR="$COMMIT_RELAY_HOME/coordination/pm-requests"
ALERTS_DIR="$COMMIT_RELAY_HOME/coordination/pm-alerts"
HISTORY_DIR="$COMMIT_RELAY_HOME/coordination/history"
HOURLY_DIR="$HISTORY_DIR/hourly"
DAILY_DIR="$HISTORY_DIR/daily"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$CHECKINS_DIR"
mkdir -p "$REQUESTS_DIR"/{pending,processed}
mkdir -p "$ALERTS_DIR"/{pending,resolved}
mkdir -p "$WORKER_SPECS_DIR"/{active,completed,failed}
mkdir -p "$HOURLY_DIR"
mkdir -p "$DAILY_DIR"

# Redirect output to log file
exec >> "$LOG_FILE" 2>&1

# Logging functions
log_pm() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [PM] $1"
}

log_pm_event() {
    local event_type="$1"
    local worker_id="${2:-}"
    local data_json="${3:-}"

    # Default to empty object if not provided
    if [ -z "$data_json" ]; then
        data_json="{}"
    fi

    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    local log_entry
    if [ -n "$worker_id" ]; then
        log_entry=$(jq -nc \
            --arg ts "$timestamp" \
            --arg pm "$PM_ID" \
            --arg evt "$event_type" \
            --arg wid "$worker_id" \
            --argjson data "$data_json" \
            '{timestamp: $ts, pm_id: $pm, event: $evt, worker_id: $wid, data: $data}')
    else
        log_entry=$(jq -nc \
            --arg ts "$timestamp" \
            --arg pm "$PM_ID" \
            --arg evt "$event_type" \
            --argjson data "$data_json" \
            '{timestamp: $ts, pm_id: $pm, event: $evt, data: $data}')
    fi

    echo "$log_entry" >> "$PM_ACTIVITY_LOG"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_pm "ERROR: PM daemon already running with PID $OLD_PID"
        exit 1
    else
        log_pm "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

# Cleanup on exit
cleanup() {
    log_pm "INFO: PM daemon stopping (PID $$)"
    log_pm_event "pm_stopped" "" "{\"uptime_hours\": $((SECONDS / 3600))}"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Initialize PM state
initialize_pm_state() {
    if [ ! -f "$PM_STATE_FILE" ]; then
        log_pm "INFO: Initializing PM state"
        jq -n \
            --arg pm_id "$PM_ID" \
            --arg version "$PM_VERSION" \
            --arg started "$(date +%Y-%m-%dT%H:%M:%S%z)" \
            '{
                version: $version,
                pm_daemon: {
                    pm_id: $pm_id,
                    pid: null,
                    started_at: $started,
                    last_loop: null,
                    loops_completed: 0,
                    uptime_seconds: 0
                },
                monitored_workers: {},
                metrics: {
                    total_workers_monitored: 0,
                    workers_by_state: {
                        healthy: 0,
                        late: 0,
                        stalled: 0,
                        timeout_warning: 0,
                        zombie: 0
                    },
                    completed_today: 0,
                    failed_today: 0,
                    interventions_today: 0,
                    success_rate_today: 0
                },
                configuration: {
                    loop_interval_seconds: '$LOOP_INTERVAL',
                    checkin_timeout_minutes: 15,
                    stall_timeout_minutes: 20,
                    timeout_warning_levels: [50, 75, 90],
                    timeout_grace_pct: 110
                }
            }' > "$PM_STATE_FILE"
    fi

    # Update PID and start time
    jq --arg pid "$$" \
       --arg started "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       '.pm_daemon.pid = ($pid | tonumber) | .pm_daemon.started_at = $started' \
       "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
       mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"
}

# Save PM state
save_pm_state() {
    local temp_state="/tmp/pm-state-$$.json"

    # Update state with current metrics
    jq --arg last_loop "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --arg loops "$LOOP_COUNT" \
       --arg uptime "$SECONDS" \
       '.pm_daemon.last_loop = $last_loop |
        .pm_daemon.loops_completed = ($loops | tonumber) |
        .pm_daemon.uptime_seconds = ($uptime | tonumber)' \
       "$PM_STATE_FILE" > "$temp_state"

    # Validate temp file was created successfully
    if [ ! -s "$temp_state" ]; then
        log_pm "ERROR: Failed to create temp state file"
        rm -f "$temp_state"
        return 1
    fi

    # Always write to file first (primary data store)
    if mv "$temp_state" "$PM_STATE_FILE"; then
        log_pm "DEBUG: PM state saved to file"
    else
        log_pm "ERROR: Failed to save PM state to file"
        rm -f "$temp_state"
        return 1
    fi

    # Optionally report to dashboard API (best effort, non-critical)
    # This triggers WebSocket updates but is not required for daemon operation
    if curl -s -f -X POST http://localhost:3000/api/pm/state \
        -H "Content-Type: application/json" \
        -d @"$PM_STATE_FILE" \
        --max-time 2 > /dev/null 2>&1; then
        log_pm "DEBUG: PM state reported to dashboard API"
    else
        # This is expected if dashboard is not running or endpoint not available
        # Don't log as error - just skip API notification
        : # no-op
    fi
}

# Calculate age in minutes
calculate_age_minutes() {
    local timestamp="$1"
    local now=$(date +%s)

    # macOS-compatible date parsing
    local then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: use -j -f for ISO8601 parsing
        then=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$timestamp" +%s 2>/dev/null || echo 0)
    else
        # Linux: use -d
        then=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)
    fi

    local age_seconds=$((now - then))
    echo $((age_seconds / 60))
}

# Register worker for monitoring
register_worker() {
    local spec_file="$1"
    local worker_id=$(jq -r '.worker_id' "$spec_file")
    local task_id=$(jq -r '.task_id // "unknown"' "$spec_file")
    local worker_type=$(jq -r '.worker_type' "$spec_file")
    local started_at=$(jq -r '.execution.started_at // empty' "$spec_file")

    # Skip if not started yet
    [ -z "$started_at" ] && return

    # Check if already registered
    local already_registered=$(jq -r ".monitored_workers[\"$worker_id\"] // empty" "$PM_STATE_FILE")
    [ -n "$already_registered" ] && return

    log_pm "INFO: Registering worker: $worker_id (task: $task_id, type: $worker_type)"

    # Add to monitored workers
    jq --arg wid "$worker_id" \
       --arg tid "$task_id" \
       --arg wtype "$worker_type" \
       --arg started "$started_at" \
       --arg registered "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       '.monitored_workers[$wid] = {
           worker_id: $wid,
           task_id: $tid,
           worker_type: $wtype,
           registered_at: $registered,
           started_at: $started,
           last_checkin: null,
           checkin_count: 0,
           health_state: "unknown",
           progress_pct: 0,
           warnings_sent: 0,
           interventions: [],
           legacy_worker: false
       }' "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
       mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"

    log_pm_event "worker_registered" "$worker_id" \
        "{\"task_id\": \"$task_id\", \"type\": \"$worker_type\"}"
}

# Scan for active workers
scan_active_workers() {
    local active_dir="$WORKER_SPECS_DIR/active"

    for spec_file in "$active_dir"/*.json; do
        [ ! -f "$spec_file" ] && continue
        register_worker "$spec_file"
    done
}

# Process check-in files
process_checkins() {
    for checkin_file in "$CHECKINS_DIR"/*.json; do
        [ ! -f "$checkin_file" ] && continue

        # Skip warning files
        [[ "$checkin_file" == *"WARNING"* ]] && continue

        local filename=$(basename "$checkin_file")
        local worker_id=$(echo "$filename" | sed 's/-[0-9T]*Z\.json$//')
        local status=$(jq -r '.status' "$checkin_file" 2>/dev/null || echo "unknown")
        local progress=$(jq -r '.progress_pct' "$checkin_file" 2>/dev/null || echo 0)
        local timestamp=$(jq -r '.timestamp' "$checkin_file" 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)

        # Update worker state
        update_worker_checkin "$worker_id" "$status" "$progress" "$timestamp"

        # Archive check-in (delete after processing)
        rm -f "$checkin_file"
    done
}

# Update worker from check-in
update_worker_checkin() {
    local worker_id="$1"
    local status="$2"
    local progress="$3"
    local timestamp="$4"

    # Check if worker is registered
    local registered=$(jq -r ".monitored_workers[\"$worker_id\"] // empty" "$PM_STATE_FILE")
    [ -z "$registered" ] && return

    # Update worker state
    jq --arg wid "$worker_id" \
       --arg status "$status" \
       --arg progress "$progress" \
       --arg ts "$timestamp" \
       '.monitored_workers[$wid].last_checkin = $ts |
        .monitored_workers[$wid].progress_pct = ($progress | tonumber) |
        .monitored_workers[$wid].checkin_count += 1 |
        .monitored_workers[$wid].health_state = "healthy"' \
       "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
       mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"

    log_pm_event "checkin_received" "$worker_id" \
        "{\"status\": \"$status\", \"progress\": $progress}"

    # Handle completion
    if [ "$status" = "completed" ]; then
        log_pm "INFO: Worker $worker_id reported completion"
        log_pm_event "worker_completed" "$worker_id" "{\"progress\": $progress}"
    fi

    # Handle failure
    if [ "$status" = "failed" ]; then
        log_pm "WARN: Worker $worker_id reported failure"
        log_pm_event "worker_failed" "$worker_id" "{\"progress\": $progress}"
    fi
}

# Check for missed check-ins
check_missed_checkins() {
    local workers=$(jq -r '.monitored_workers | keys[]' "$PM_STATE_FILE" 2>/dev/null || echo "")

    for worker_id in $workers; do
        local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"
        [ ! -f "$worker_spec" ] && continue

        local status=$(jq -r '.status' "$worker_spec")
        [ "$status" != "running" ] && continue

        local started_at=$(jq -r ".monitored_workers[\"$worker_id\"].started_at" "$PM_STATE_FILE")
        local last_checkin=$(jq -r ".monitored_workers[\"$worker_id\"].last_checkin" "$PM_STATE_FILE")

        # Calculate time since last check-in or start
        local age_minutes
        if [ "$last_checkin" = "null" ] || [ -z "$last_checkin" ]; then
            # No check-ins yet, use start time
            age_minutes=$(calculate_age_minutes "$started_at")
        else
            # Has check-ins, use last check-in time
            age_minutes=$(calculate_age_minutes "$last_checkin")
        fi

        # Determine health state
        local health_state="healthy"
        if [ $age_minutes -ge 20 ]; then
            health_state="stalled"
            log_pm "WARN: Worker $worker_id stalled (no check-in for $age_minutes min)"
            log_pm_event "worker_stalled" "$worker_id" \
                "{\"minutes_since_checkin\": $age_minutes}"
        elif [ $age_minutes -ge 15 ]; then
            health_state="late"
            log_pm "WARN: Worker $worker_id late (no check-in for $age_minutes min)"
            log_pm_event "missed_checkin" "$worker_id" \
                "{\"minutes_since_checkin\": $age_minutes}"
        fi

        # Update health state
        jq --arg wid "$worker_id" \
           --arg health "$health_state" \
           '.monitored_workers[$wid].health_state = $health' \
           "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
           mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"
    done
}

# Check worker timeouts
check_worker_timeouts() {
    local workers=$(jq -r '.monitored_workers | keys[]' "$PM_STATE_FILE" 2>/dev/null || echo "")

    for worker_id in $workers; do
        local worker_spec="$WORKER_SPECS_DIR/active/${worker_id}.json"
        [ ! -f "$worker_spec" ] && continue

        local status=$(jq -r '.status' "$worker_spec")
        [ "$status" != "running" ] && continue

        local started_at=$(jq -r '.execution.started_at' "$worker_spec")
        local time_limit=$(jq -r '.resources.time_limit_minutes // 60' "$worker_spec")

        local age_minutes=$(calculate_age_minutes "$started_at")
        local time_used_pct=$((age_minutes * 100 / time_limit))

        # Check for timeout warnings
        local warnings_sent=$(jq -r ".monitored_workers[\"$worker_id\"].warnings_sent // 0" "$PM_STATE_FILE")

        if [ $time_used_pct -ge 90 ] && [ $warnings_sent -lt 3 ]; then
            log_pm "WARN: Worker $worker_id at 90% time limit ($age_minutes/$time_limit min)"
            log_pm_event "timeout_warning" "$worker_id" \
                "{\"level\": \"final\", \"time_used_pct\": $time_used_pct}"

            # Increment warnings count
            jq --arg wid "$worker_id" \
               '.monitored_workers[$wid].warnings_sent += 1' \
               "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
               mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"

        elif [ $time_used_pct -ge 75 ] && [ $warnings_sent -lt 2 ]; then
            log_pm "WARN: Worker $worker_id at 75% time limit ($age_minutes/$time_limit min)"
            log_pm_event "timeout_warning" "$worker_id" \
                "{\"level\": \"second\", \"time_used_pct\": $time_used_pct}"

            jq --arg wid "$worker_id" \
               '.monitored_workers[$wid].warnings_sent += 1' \
               "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
               mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"

        elif [ $time_used_pct -ge 50 ] && [ $warnings_sent -lt 1 ]; then
            log_pm "INFO: Worker $worker_id at 50% time limit ($age_minutes/$time_limit min)"
            log_pm_event "timeout_warning" "$worker_id" \
                "{\"level\": \"first\", \"time_used_pct\": $time_used_pct}"

            jq --arg wid "$worker_id" \
               '.monitored_workers[$wid].warnings_sent += 1' \
               "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
               mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"
        fi

        # Check hard timeout (110% grace period)
        if [ $age_minutes -ge $((time_limit * 110 / 100)) ]; then
            log_pm "ERROR: Worker $worker_id exceeded timeout ($age_minutes/$time_limit min)"
            log_pm_event "timeout_exceeded" "$worker_id" \
                "{\"age_minutes\": $age_minutes, \"limit_minutes\": $time_limit}"
            # Will implement kill in Phase 2
        fi
    done
}

# Detect zombie workers
detect_zombies() {
    local active_dir="$WORKER_SPECS_DIR/active"
    local zombie_count=0
    local zombie_workers=()

    for spec_file in "$active_dir"/*.json; do
        [ ! -f "$spec_file" ] && continue

        local worker_id=$(jq -r '.worker_id' "$spec_file")
        local status=$(jq -r '.status' "$spec_file")
        local started_at=$(jq -r '.execution.started_at // empty' "$spec_file")

        # Only check workers marked as "running"
        [ "$status" != "running" ] && continue
        [ -z "$started_at" ] && continue

        # Skip if just started (< 5 minutes)
        local age_minutes=$(calculate_age_minutes "$started_at")
        [ $age_minutes -lt 5 ] && continue

        # Check if process exists (simple check for Claude process)
        local pid=$(ps aux | grep -i "claude" | grep "$worker_id" | grep -v grep | awk '{print $2}' | head -1)

        if [ -z "$pid" ]; then
            log_pm "ERROR: Zombie worker detected: $worker_id (no process, age: $age_minutes min)"
            log_pm_event "zombie_detected" "$worker_id" \
                "{\"age_minutes\": $age_minutes, \"process_found\": false}"

            zombie_count=$((zombie_count + 1))
            zombie_workers+=("$worker_id")
        fi
    done

    # Create health alert if 10+ zombies detected
    if [ $zombie_count -ge 10 ]; then
        log_pm "CRITICAL: Zombie threshold exceeded ($zombie_count zombies detected)"

        # Create health alert
        local alert_id="alert-zombie-threshold-$(date +%s)"
        local zombie_list=$(printf '%s,' "${zombie_workers[@]}" | sed 's/,$//')

        # Check if alert already exists
        if [ -f "$COMMIT_RELAY_HOME/coordination/health-alerts.json" ]; then
            local existing_zombie_alerts=$(jq '[.alerts[] | select(.type == "zombie_threshold" and .status == "active")] | length' \
                "$COMMIT_RELAY_HOME/coordination/health-alerts.json" 2>/dev/null || echo 0)

            if [ "$existing_zombie_alerts" -eq 0 ]; then
                log_pm "Creating zombie threshold health alert"

                "$COMMIT_RELAY_HOME/scripts/log-health-incident.sh" \
                    "$alert_id" \
                    "pm-daemon" \
                    "zombie_threshold_exceeded" \
                    "$zombie_count zombie workers detected (threshold: 10). Workers: $zombie_list" \
                    2>/dev/null || true

                # Add alert to health-alerts.json
                local temp_alerts=$(mktemp)
                jq --arg id "$alert_id" \
                   --arg count "$zombie_count" \
                   --arg workers "$zombie_list" \
                   --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                   '.alerts += [{
                       "id": $id,
                       "type": "zombie_threshold",
                       "severity": "high",
                       "status": "active",
                       "message": "Zombie threshold exceeded: \($count) zombies detected (threshold: 10)",
                       "metric_value": ($count | tonumber),
                       "threshold": 10,
                       "sla_minutes": 30,
                       "created_at": $ts,
                       "worker_id": null,
                       "investigation_notes": [],
                       "zombie_workers": $workers
                   }]' "$COMMIT_RELAY_HOME/coordination/health-alerts.json" > "$temp_alerts" && \
                   mv "$temp_alerts" "$COMMIT_RELAY_HOME/coordination/health-alerts.json"

                log_pm_event "zombie_threshold_alert" "" \
                    "{\"zombie_count\": $zombie_count, \"threshold\": 10, \"alert_id\": \"$alert_id\"}"
            fi
        fi
    fi

    return 0
}

# Calculate metrics
calculate_metrics() {
    # Get all-time counts for dashboard
    local active_count=$(find "$WORKER_SPECS_DIR/active" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local completed_count=$(find "$WORKER_SPECS_DIR/completed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local failed_count=$(find "$WORKER_SPECS_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local zombie_count=$(find "$WORKER_SPECS_DIR/zombie" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    # Get today-only counts for daily metrics
    local completed_today=$(find "$WORKER_SPECS_DIR/completed" -name "*.json" -mtime -1 2>/dev/null | wc -l | tr -d ' ')
    local failed_today=$(find "$WORKER_SPECS_DIR/failed" -name "*.json" -mtime -1 2>/dev/null | wc -l | tr -d ' ')

    # Calculate all-time success rate
    local total_all=$((active_count + completed_count + failed_count + zombie_count))
    local success_rate_all=0
    if [ $total_all -gt 0 ]; then
        success_rate_all=$(echo "scale=1; $completed_count * 100 / $total_all" | bc 2>/dev/null || echo 0)
    fi

    # Calculate today's success rate
    local total_today=$((completed_today + failed_today))
    local success_rate_today=0
    if [ $total_today -gt 0 ]; then
        success_rate_today=$(echo "scale=1; $completed_today * 100 / $total_today" | bc 2>/dev/null || echo 0)
    fi

    # Update metrics in PM state
    jq --arg active "$active_count" \
       --arg completed "$completed_count" \
       --arg failed "$failed_count" \
       --arg zombie "$zombie_count" \
       --arg total "$total_all" \
       --arg rate "$success_rate_all" \
       --arg completed_today "$completed_today" \
       --arg failed_today "$failed_today" \
       --arg rate_today "$success_rate_today" \
       '.metrics.active_workers = ($active | tonumber) |
        .metrics.completed_workers = ($completed | tonumber) |
        .metrics.failed_workers = ($failed | tonumber) |
        .metrics.total_workers = ($total | tonumber) |
        .metrics.success_rate = ($rate | tonumber) |
        .metrics.completed_today = ($completed_today | tonumber) |
        .metrics.failed_today = ($failed_today | tonumber) |
        .metrics.success_rate_today = ($rate_today | tonumber)' \
       "$PM_STATE_FILE" > "${PM_STATE_FILE}.tmp" && \
       mv "${PM_STATE_FILE}.tmp" "$PM_STATE_FILE"

    # Update workforce-streams.json for dashboard
    jq --arg active "$active_count" \
       --arg completed "$completed_count" \
       --arg failed "$failed_count" \
       --arg zombie "$zombie_count" \
       '.workers.active = ($active | tonumber) |
        .workers.completed = ($completed | tonumber) |
        .workers.failed = ($failed | tonumber) |
        .workers.zombie = ($zombie | tonumber) |
        .last_updated = "'$(date +%Y-%m-%dT%H:%M:%S%z)'"' \
       "$COMMIT_RELAY_HOME/coordination/workforce-streams.json" > \
       "$COMMIT_RELAY_HOME/coordination/workforce-streams.json.tmp" && \
       mv "$COMMIT_RELAY_HOME/coordination/workforce-streams.json.tmp" \
          "$COMMIT_RELAY_HOME/coordination/workforce-streams.json"
}

# Create historical snapshot
create_snapshot() {
    local timestamp="$1"
    local snapshot_file="${HOURLY_DIR}/${timestamp}.json"

    # Read current metrics from PM state
    local active_workers=$(jq -r '.metrics.active_workers // 0' "$PM_STATE_FILE")
    local completed_workers=$(jq -r '.metrics.completed_workers // 0' "$PM_STATE_FILE")
    local failed_workers=$(jq -r '.metrics.failed_workers // 0' "$PM_STATE_FILE")
    local success_rate=$(jq -r '.metrics.success_rate // 0' "$PM_STATE_FILE")
    local total_workers=$(jq -r '.metrics.total_workers // 0' "$PM_STATE_FILE")
    local completed_today=$(jq -r '.metrics.completed_today // 0' "$PM_STATE_FILE")
    local failed_today=$(jq -r '.metrics.failed_today // 0' "$PM_STATE_FILE")

    # Count zombie workers
    local zombie_count=$(find "$WORKER_SPECS_DIR/zombie" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    # Read token budget if exists
    local total_budget=200000
    local total_used=0
    local token_budget_file="$COMMIT_RELAY_HOME/coordination/token-budget.json"

    if [ -f "$token_budget_file" ]; then
        total_budget=$(jq -r '.total_budget // 200000' "$token_budget_file" 2>/dev/null || echo 200000)
        total_used=$(jq -r '.usage_metrics.total_tokens_used_today // 0' "$token_budget_file" 2>/dev/null || echo 0)
    fi

    local usage_pct=0
    if [ $total_budget -gt 0 ]; then
        usage_pct=$(echo "scale=2; ($total_used * 100) / $total_budget" | bc 2>/dev/null || echo 0)
    fi

    # Read task queue if exists
    local pending_tasks=0
    local in_progress_tasks=0
    local completed_tasks=0
    local task_queue_file="$COMMIT_RELAY_HOME/coordination/task-queue.json"

    if [ -f "$task_queue_file" ]; then
        pending_tasks=$(jq -r '[.tasks[] | select(.status == "pending")] | length' "$task_queue_file" 2>/dev/null || echo 0)
        in_progress_tasks=$(jq -r '[.tasks[] | select(.status == "in_progress" or .status == "assigned")] | length' "$task_queue_file" 2>/dev/null || echo 0)
        completed_tasks=$(jq -r '[.tasks[] | select(.status == "completed")] | length' "$task_queue_file" 2>/dev/null || echo 0)
    fi

    # Create snapshot JSON
    cat > "$snapshot_file" <<EOF
{
  "timestamp": "$timestamp",
  "workers": {
    "active": $active_workers,
    "completed": $completed_workers,
    "failed": $failed_workers,
    "zombie": $zombie_count,
    "total": $total_workers,
    "success_rate": $success_rate,
    "completed_today": $completed_today,
    "failed_today": $failed_today
  },
  "tokens": {
    "total_budget": $total_budget,
    "total_used": $total_used,
    "available": $((total_budget - total_used)),
    "usage_percentage": $usage_pct
  },
  "tasks": {
    "pending": $pending_tasks,
    "in_progress": $in_progress_tasks,
    "completed": $completed_tasks,
    "total": $((pending_tasks + in_progress_tasks + completed_tasks))
  },
  "pm_daemon": {
    "pid": $$,
    "uptime_seconds": $SECONDS,
    "loops_completed": $LOOP_COUNT
  }
}
EOF

    log_pm "DEBUG: Historical snapshot created: $snapshot_file"
}

# Aggregate daily snapshots
aggregate_daily_snapshot() {
    local date_prefix="$1"
    local daily_file="${DAILY_DIR}/${date_prefix}.json"

    # Find all hourly snapshots for this day
    local hourly_pattern="${HOURLY_DIR}/${date_prefix}T*.json"
    local hourly_count=$(ls -1 $hourly_pattern 2>/dev/null | wc -l | tr -d ' ')

    if [ "$hourly_count" -eq 0 ]; then
        return
    fi

    log_pm "INFO: Aggregating daily snapshot for $date_prefix from $hourly_count hourly snapshots"

    # Use jq to aggregate
    jq -s '[.[] | {
        timestamp: .timestamp,
        workers: .workers,
        tokens: .tokens,
        tasks: .tasks
    }] | {
        date: "'$date_prefix'",
        snapshots_count: length,
        first_snapshot: .[0].timestamp,
        last_snapshot: .[-1].timestamp,
        workers: {
            avg_active: ([.[].workers.active] | add / length),
            total_completed: .[-1].workers.completed,
            total_failed: .[-1].workers.failed,
            total_zombie: .[-1].workers.zombie,
            avg_success_rate: ([.[].workers.success_rate] | add / length)
        },
        tokens: {
            total_budget: .[-1].tokens.total_budget,
            total_used: .[-1].tokens.total_used,
            avg_usage_percentage: ([.[].tokens.usage_percentage] | add / length)
        },
        tasks: {
            total_completed: .[-1].tasks.completed,
            avg_pending: ([.[].tasks.pending] | add / length),
            avg_in_progress: ([.[].tasks.in_progress] | add / length)
        }
    }' $hourly_pattern > "$daily_file" 2>/dev/null

    log_pm "INFO: Daily snapshot saved to $daily_file"
}

# Cleanup old hourly snapshots (keep last 7 days)
cleanup_old_snapshots() {
    local cutoff_date=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)

    log_pm "DEBUG: Cleaning up hourly snapshots older than $cutoff_date"

    find "$HOURLY_DIR" -name "*.json" -type f | while read -r file; do
        local file_date=$(basename "$file" | cut -d'T' -f1)
        if [[ "$file_date" < "$cutoff_date" ]]; then
            rm -f "$file"
            log_pm "DEBUG: Removed old hourly snapshot: $(basename $file)"
        fi
    done
}

# Main PM daemon loop
PM_START_TIME=$(date +%Y-%m-%dT%H:%M:%S%z)
LOOP_COUNT=0
LAST_SNAPSHOT_TIME=0
LAST_DAILY_AGGREGATION=""

log_pm "INFO: PM daemon starting (PID $$, version $PM_VERSION)"
log_pm "INFO: Loop interval: ${LOOP_INTERVAL}s, Snapshot interval: ${SNAPSHOT_INTERVAL}s"
log_pm "INFO: Working directory: $COMMIT_RELAY_HOME"

initialize_pm_state

log_pm_event "pm_started" "" \
    "{\"version\": \"$PM_VERSION\", \"loop_interval\": $LOOP_INTERVAL, \"snapshot_interval\": $SNAPSHOT_INTERVAL}"

# Test mode: run once and exit
if [ "$TEST_MODE" = "--test-mode" ]; then
    log_pm "INFO: Running in test mode (single loop)"

    scan_active_workers
    process_checkins
    check_missed_checkins
    check_worker_timeouts
    detect_zombies
    calculate_metrics
    save_pm_state

    log_pm "INFO: Test loop completed"
    exit 0
fi

# Main monitoring loop
while true; do
    LOOP_START=$(date +%s)
    LOOP_COUNT=$((LOOP_COUNT + 1))
    CURRENT_TIME=$(date +%Y-%m-%dT%H:%M:%S%z)
    CURRENT_DATE=$(date +%Y-%m-%d)
    CURRENT_HOUR=$(date +%H)

    log_pm "DEBUG: Starting loop $LOOP_COUNT"

    # Monitoring tasks with error handling
    # Each function failure is logged but doesn't crash the daemon
    scan_active_workers || log_pm "WARN: scan_active_workers failed in loop $LOOP_COUNT"
    process_checkins || log_pm "WARN: process_checkins failed in loop $LOOP_COUNT"
    check_missed_checkins || log_pm "WARN: check_missed_checkins failed in loop $LOOP_COUNT"
    check_worker_timeouts || log_pm "WARN: check_worker_timeouts failed in loop $LOOP_COUNT"
    detect_zombies || log_pm "WARN: detect_zombies failed in loop $LOOP_COUNT"
    calculate_metrics || log_pm "WARN: calculate_metrics failed in loop $LOOP_COUNT"
    save_pm_state || log_pm "WARN: save_pm_state failed in loop $LOOP_COUNT"

    # Historical snapshot (every SNAPSHOT_INTERVAL seconds)
    TIME_SINCE_SNAPSHOT=$((LOOP_START - LAST_SNAPSHOT_TIME))
    if [ $TIME_SINCE_SNAPSHOT -ge $SNAPSHOT_INTERVAL ]; then
        create_snapshot "$CURRENT_TIME"
        LAST_SNAPSHOT_TIME=$LOOP_START

        # Aggregate daily snapshot at midnight UTC
        if [ "$CURRENT_HOUR" = "00" ] && [ "$LAST_DAILY_AGGREGATION" != "$CURRENT_DATE" ]; then
            YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
            aggregate_daily_snapshot "$YESTERDAY"
            LAST_DAILY_AGGREGATION="$CURRENT_DATE"

            # Cleanup old hourly snapshots
            cleanup_old_snapshots
        fi
    fi

    LOOP_END=$(date +%s)
    LOOP_DURATION=$((LOOP_END - LOOP_START))

    log_pm "DEBUG: Loop $LOOP_COUNT completed in ${LOOP_DURATION}s"
    log_pm_event "pm_loop_completed" "" \
        "{\"loop_number\": $LOOP_COUNT, \"duration_seconds\": $LOOP_DURATION}"

    # Sleep until next loop
    sleep "$LOOP_INTERVAL"
done
