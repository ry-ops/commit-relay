#!/bin/bash
################################################################################
# Metrics Snapshot Daemon
#
# Purpose: Periodically collects system metrics and stores historical snapshots
# Usage: ./scripts/metrics-snapshot-daemon.sh
# Interval: Configurable via SNAPSHOT_INTERVAL (default: 300s = 5 minutes)
################################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || true

# Configuration
DAEMON_NAME="commit-relay-metrics-snapshot"
SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-300}"  # 5 minutes by default
HISTORY_DIR="${COMMIT_RELAY_HOME}/coordination/history"
DAILY_DIR="${HISTORY_DIR}/daily"
HOURLY_DIR="${HISTORY_DIR}/hourly"
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/metrics-snapshot.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"

# Coordination files
WORKER_POOL="${COMMIT_RELAY_HOME}/coordination/worker-pool.json"
TOKEN_BUDGET="${COMMIT_RELAY_HOME}/coordination/token-budget.json"
TASK_QUEUE="${COMMIT_RELAY_HOME}/coordination/task-queue.json"
ORCHESTRATOR_STATE="${COMMIT_RELAY_HOME}/coordination/orchestrator/state/current.json"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$DAILY_DIR"
mkdir -p "$HOURLY_DIR"

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

log_snapshot() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_snapshot "ERROR: Metrics snapshot daemon already running with PID $OLD_PID"
        exit 1
    else
        log_snapshot "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_snapshot "INFO: Metrics Snapshot daemon starting (PID $$)"
log_snapshot "INFO: Snapshot interval: ${SNAPSHOT_INTERVAL}s"
log_snapshot "INFO: History directory: $HISTORY_DIR"

# Cleanup on exit
cleanup() {
    log_snapshot "INFO: Metrics Snapshot daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Calculate percentile from sorted array
# Usage: calculate_percentile "1 2 3 4 5" 90
calculate_percentile() {
    local values_str="$1"
    local percentile="$2"

    # Convert to array and sort
    local -a values=($values_str)
    local count=${#values[@]}

    if [ $count -eq 0 ]; then
        echo "0"
        return
    fi

    # Sort numerically
    IFS=$'\n' sorted=($(sort -n <<<"${values[*]}")); unset IFS

    # Calculate index for percentile
    local index=$(echo "scale=0; ($count * $percentile / 100)" | bc)

    # Clamp to valid range
    if [ $index -ge $count ]; then
        index=$((count - 1))
    fi
    if [ $index -lt 0 ]; then
        index=0
    fi

    echo "${sorted[$index]}"
}

# Calculate metrics from coordination files
collect_metrics() {
    local timestamp="$1"
    local snapshot_file="$2"

    # Read worker pool data
    local active_workers=0
    local completed_workers=0
    local failed_workers=0
    local zombies_killed=0
    local avg_duration=0
    local avg_tokens=0
    local duration_p50=0
    local duration_p90=0
    local duration_p95=0
    local duration_p99=0

    if [ -f "$WORKER_POOL" ]; then
        active_workers=$(jq -r '.active_workers | length' "$WORKER_POOL" 2>/dev/null || echo 0)
        completed_workers=$(jq -r '.completed_workers | length' "$WORKER_POOL" 2>/dev/null || echo 0)
        failed_workers=$(jq -r '.failed_workers | length' "$WORKER_POOL" 2>/dev/null || echo 0)
        zombies_killed=$(jq -r '[.failed_workers[] | select(.killed_by == "zombie-killer-daemon")] | length' "$WORKER_POOL" 2>/dev/null || echo 0)
        avg_duration=$(jq -r '.stats.avg_duration_minutes // 0' "$WORKER_POOL" 2>/dev/null || echo 0)
        avg_tokens=$(jq -r '.stats.avg_tokens_used // 0' "$WORKER_POOL" 2>/dev/null || echo 0)

        # Calculate duration percentiles from completed workers
        local durations=$(jq -r '[.completed_workers[].duration_minutes // 0] | .[]' "$WORKER_POOL" 2>/dev/null | tr '\n' ' ')
        if [ -n "$durations" ]; then
            duration_p50=$(calculate_percentile "$durations" 50)
            duration_p90=$(calculate_percentile "$durations" 90)
            duration_p95=$(calculate_percentile "$durations" 95)
            duration_p99=$(calculate_percentile "$durations" 99)
        fi
    fi

    # Read token budget data
    local total_budget=270000
    local total_used=0
    local masters_used=0
    local workers_used=0
    local efficiency=0

    if [ -f "$TOKEN_BUDGET" ]; then
        total_budget=$(jq -r '.total_budget // 270000' "$TOKEN_BUDGET" 2>/dev/null || echo 270000)
        total_used=$(jq -r '.usage_metrics.total_tokens_used_today // 0' "$TOKEN_BUDGET" 2>/dev/null || echo 0)
        masters_used=$(jq -r '.usage_metrics.masters_used // 0' "$TOKEN_BUDGET" 2>/dev/null || echo 0)
        workers_used=$(jq -r '.usage_metrics.workers_used // 0' "$TOKEN_BUDGET" 2>/dev/null || echo 0)
        efficiency=$(jq -r '.usage_metrics.efficiency_score // 0' "$TOKEN_BUDGET" 2>/dev/null || echo 0)
    fi

    # Read task queue data
    local pending_tasks=0
    local in_progress_tasks=0
    local completed_tasks=0
    local total_tasks=0

    if [ -f "$TASK_QUEUE" ]; then
        pending_tasks=$(jq -r '[.tasks[] | select(.status == "pending")] | length' "$TASK_QUEUE" 2>/dev/null || echo 0)
        in_progress_tasks=$(jq -r '[.tasks[] | select(.status == "in_progress" or .status == "in-progress")] | length' "$TASK_QUEUE" 2>/dev/null || echo 0)
        completed_tasks=$(jq -r '[.tasks[] | select(.status == "completed")] | length' "$TASK_QUEUE" 2>/dev/null || echo 0)
        total_tasks=$(jq -r '.tasks | length' "$TASK_QUEUE" 2>/dev/null || echo 0)
    fi

    # Read orchestrator data (v4.0)
    local active_orchestrations=0
    local total_orchestrations=0
    local completed_orchestrations=0
    local failed_orchestrations=0

    if [ -f "$ORCHESTRATOR_STATE" ]; then
        active_orchestrations=$(jq -r '.active_orchestrations // 0' "$ORCHESTRATOR_STATE" 2>/dev/null || echo 0)
        total_orchestrations=$(jq -r '.total_orchestrations // 0' "$ORCHESTRATOR_STATE" 2>/dev/null || echo 0)
        completed_orchestrations=$(jq -r '.completed_orchestrations // 0' "$ORCHESTRATOR_STATE" 2>/dev/null || echo 0)
        failed_orchestrations=$(jq -r '.failed_orchestrations // 0' "$ORCHESTRATOR_STATE" 2>/dev/null || echo 0)
    fi

    # Read Execution Manager data (v4.0)
    local active_ems=0
    local completed_ems=0
    local failed_ems=0
    local total_ems=0
    local em_success_rate=0

    local EM_ACTIVE_DIR="${COMMIT_RELAY_HOME}/coordination/execution-managers/active"
    local EM_COMPLETED_DIR="${COMMIT_RELAY_HOME}/coordination/execution-managers/completed"

    if [ -d "$EM_ACTIVE_DIR" ]; then
        active_ems=$(find "$EM_ACTIVE_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [ -d "$EM_COMPLETED_DIR" ]; then
        total_completed=$(find "$EM_COMPLETED_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
        failed_ems=0

        for em_file in "$EM_COMPLETED_DIR"/*.json; do
            if [ -f "$em_file" ]; then
                em_status=$(jq -r '.status // "unknown"' "$em_file" 2>/dev/null || echo "unknown")
                if [ "$em_status" = "failed" ]; then
                    failed_ems=$((failed_ems + 1))
                fi
            fi
        done 2>/dev/null

        completed_ems=$((total_completed - failed_ems))
    fi

    total_ems=$((active_ems + completed_ems + failed_ems))

    if [ $((completed_ems + failed_ems)) -gt 0 ]; then
        em_success_rate=$(echo "scale=2; ($completed_ems * 100) / ($completed_ems + $failed_ems)" | bc 2>/dev/null || echo 0)
    fi

    # Calculate success rate
    local success_rate=0
    if [ $((completed_workers + failed_workers)) -gt 0 ]; then
        success_rate=$(echo "scale=2; ($completed_workers * 100) / ($completed_workers + $failed_workers)" | bc 2>/dev/null || echo 0)
    fi

    # Create snapshot JSON
    cat > "$snapshot_file" <<EOF
{
  "timestamp": "$timestamp",
  "workers": {
    "active": $active_workers,
    "completed": $completed_workers,
    "failed": $failed_workers,
    "zombies_killed": $zombies_killed,
    "success_rate": $success_rate,
    "avg_duration_minutes": $avg_duration,
    "avg_tokens_used": $avg_tokens,
    "duration_percentiles": {
      "p50": $duration_p50,
      "p90": $duration_p90,
      "p95": $duration_p95,
      "p99": $duration_p99
    }
  },
  "tokens": {
    "total_budget": $total_budget,
    "total_used": $total_used,
    "available": $((total_budget - total_used)),
    "masters_used": $masters_used,
    "workers_used": $workers_used,
    "usage_percentage": $(echo "scale=2; ($total_used * 100) / $total_budget" | bc 2>/dev/null || echo 0),
    "efficiency_score": $efficiency
  },
  "tasks": {
    "pending": $pending_tasks,
    "in_progress": $in_progress_tasks,
    "completed": $completed_tasks,
    "total": $total_tasks
  },
  "orchestrator": {
    "active": $active_orchestrations,
    "total": $total_orchestrations,
    "completed": $completed_orchestrations,
    "failed": $failed_orchestrations
  },
  "execution_managers": {
    "active": $active_ems,
    "completed": $completed_ems,
    "failed": $failed_ems,
    "total": $total_ems,
    "success_rate": $em_success_rate
  }
}
EOF

    log_snapshot "SNAPSHOT: Workers(A:$active_workers C:$completed_workers F:$failed_workers) EMs(A:$active_ems C:$completed_ems F:$failed_ems) Tokens(${total_used}/${total_budget}) Tasks(P:$pending_tasks IP:$in_progress_tasks C:$completed_tasks)"

    # Report metrics via API for real-time dashboard updates
    if curl -s -X POST http://localhost:3000/api/metrics/report \
        -H "Content-Type: application/json" \
        -d @"$snapshot_file" > /dev/null 2>&1; then
        log_snapshot "Metrics snapshot reported via API"
    else
        log_snapshot "WARNING: Failed to report metrics snapshot to API (API may be unavailable)"
    fi
}

# Aggregate hourly snapshots into daily snapshot
aggregate_daily_snapshot() {
    local date_prefix="$1"
    local daily_file="${DAILY_DIR}/${date_prefix}.json"

    # Find all hourly snapshots for this day
    local hourly_files=("${HOURLY_DIR}/${date_prefix}"T*.json)

    if [ ! -e "${hourly_files[0]}" ]; then
        return
    fi

    log_snapshot "INFO: Aggregating daily snapshot for $date_prefix from ${#hourly_files[@]} hourly snapshots"

    # Use jq to aggregate - calculate averages and final values
    jq -s '[.[] | {
        timestamp: .timestamp,
        workers: .workers,
        tokens: .tokens,
        tasks: .tasks,
        orchestrator: .orchestrator
    }] | {
        date: "'$date_prefix'",
        snapshots_count: length,
        first_snapshot: .[0].timestamp,
        last_snapshot: .[-1].timestamp,
        workers: {
            avg_active: ([.[].workers.active] | add / length),
            total_completed: .[-1].workers.completed,
            total_failed: .[-1].workers.failed,
            total_zombies_killed: .[-1].workers.zombies_killed,
            avg_success_rate: ([.[].workers.success_rate] | add / length),
            avg_duration_minutes: ([.[].workers.avg_duration_minutes] | add / length),
            avg_tokens_used: ([.[].workers.avg_tokens_used] | add / length)
        },
        tokens: {
            total_budget: .[-1].tokens.total_budget,
            total_used: .[-1].tokens.total_used,
            avg_usage_percentage: ([.[].tokens.usage_percentage] | add / length),
            avg_efficiency_score: ([.[].tokens.efficiency_score] | add / length)
        },
        tasks: {
            total_completed: .[-1].tasks.completed,
            avg_pending: ([.[].tasks.pending] | add / length),
            avg_in_progress: ([.[].tasks.in_progress] | add / length)
        },
        orchestrator: {
            total: .[-1].orchestrator.total,
            completed: .[-1].orchestrator.completed,
            failed: .[-1].orchestrator.failed
        }
    }' "${hourly_files[@]}" > "$daily_file"

    log_snapshot "INFO: Daily snapshot saved to $daily_file"
}

# Cleanup old snapshots (keep last 7 days of hourly, keep all daily)
cleanup_old_snapshots() {
    local cutoff_date=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)

    log_snapshot "INFO: Cleaning up hourly snapshots older than $cutoff_date"

    find "$HOURLY_DIR" -name "*.json" -type f | while read -r file; do
        local file_date=$(basename "$file" | cut -d'T' -f1)
        if [[ "$file_date" < "$cutoff_date" ]]; then
            rm -f "$file"
            log_snapshot "DEBUG: Removed old hourly snapshot: $file"
        fi
    done
}

# Main snapshot loop
LAST_DAILY_AGGREGATION=""
SNAPSHOTS_COLLECTED=0

while true; do
    cd "$COMMIT_RELAY_HOME"

    CURRENT_TIME=$(date +%Y-%m-%dT%H:%M:%S%z)
    CURRENT_DATE=$(date +%Y-%m-%d)
    CURRENT_HOUR=$(date +%H)

    # Collect snapshot
    SNAPSHOT_FILE="${HOURLY_DIR}/${CURRENT_TIME}.json"
    collect_metrics "$CURRENT_TIME" "$SNAPSHOT_FILE"
    SNAPSHOTS_COLLECTED=$((SNAPSHOTS_COLLECTED + 1))

    # Aggregate daily snapshot at midnight UTC
    if [ "$CURRENT_HOUR" = "00" ] && [ "$LAST_DAILY_AGGREGATION" != "$CURRENT_DATE" ]; then
        YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
        aggregate_daily_snapshot "$YESTERDAY"
        LAST_DAILY_AGGREGATION="$CURRENT_DATE"

        # Cleanup old hourly snapshots
        cleanup_old_snapshots
    fi

    # Log periodic status
    if [ $((SNAPSHOTS_COLLECTED % 12)) -eq 0 ]; then
        log_snapshot "INFO: Daemon healthy - $SNAPSHOTS_COLLECTED snapshots collected"
    fi

    # Sleep until next snapshot
    sleep "$SNAPSHOT_INTERVAL"
done
