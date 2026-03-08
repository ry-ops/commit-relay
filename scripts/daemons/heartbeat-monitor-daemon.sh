#!/bin/bash
# scripts/daemons/heartbeat-monitor-daemon.sh
# Heartbeat Monitor Daemon - Phase 4.1 Self-Healing Implementation
# Monitors worker heartbeats and detects failures automatically
#
# Features:
#   - Monitors all active workers every 30 seconds
#   - Detects missing heartbeats (warning @ 60s, critical @ 120s)
#   - Marks zombies after 300s of no heartbeat
#   - Emits observability events
#   - Updates worker status based on heartbeat health
#
# Usage:
#   ./scripts/daemons/heartbeat-monitor-daemon.sh
#   or via systemd/launchd for auto-start

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load libraries
source "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/zombie-cleanup.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/coordination.sh" 2>/dev/null || true

# Daemon configuration
DAEMON_NAME="commit-relay-heartbeat-monitor"
POLL_INTERVAL="${HEARTBEAT_MONITOR_POLL_INTERVAL:-30}"  # Check every 30 seconds
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/heartbeat-monitor.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
METRICS_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/heartbeat-monitor-metrics.json"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$METRICS_FILE")"

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

log_monitor() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_monitor "ERROR: Heartbeat monitor already running with PID $OLD_PID"
        exit 1
    else
        log_monitor "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_monitor "INFO: Heartbeat monitor starting (PID $$)"
log_monitor "INFO: Poll interval: ${POLL_INTERVAL}s"
log_monitor "INFO: Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_monitor "INFO: Heartbeat monitor stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Metrics counters
TOTAL_WORKERS_CHECKED=0
WORKERS_HEALTHY=0
WORKERS_DEGRADED=0
WORKERS_WARNING=0
WORKERS_CRITICAL=0
WORKERS_ZOMBIE=0

# ============================================================================
# Observability Integration
# ============================================================================

emit_heartbeat_event() {
    local event_type="$1"
    local worker_id="$2"
    local task_id="$3"
    local time_since="$4"
    local health_status="${5:-unknown}"

    # Create event JSON
    local event_json=$(jq -nc \
        --arg event "$event_type" \
        --arg worker "$worker_id" \
        --arg task "$task_id" \
        --argjson time_since "$time_since" \
        --arg health "$health_status" \
        --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            event_type: $event,
            worker_id: $worker,
            task_id: $task,
            time_since_heartbeat_seconds: $time_since,
            health_status: $health,
            timestamp: $timestamp,
            detected_by: "heartbeat-monitor"
        }')

    # Emit to observability hub if available
    if command -v broadcast_dashboard_event &> /dev/null; then
        broadcast_dashboard_event "$event_type" "$event_json" 2>/dev/null || true
    fi

    # Also log locally
    local event_log="${COMMIT_RELAY_HOME}/coordination/events/heartbeat-events.jsonl"
    mkdir -p "$(dirname "$event_log")"
    echo "$event_json" >> "$event_log"
}

# ============================================================================
# Worker Health Monitoring
# ============================================================================

monitor_worker_heartbeat() {
    local spec_file="$1"
    local worker_id=$(jq -r '.worker_id' "$spec_file" 2>/dev/null || echo "")
    local task_id=$(jq -r '.task_id' "$spec_file" 2>/dev/null || echo "")
    local status=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "")

    if [ -z "$worker_id" ]; then
        log_monitor "WARN: Skipping spec with missing worker_id: $(basename "$spec_file")"
        return
    fi

    # Skip if worker is not in active state
    if [[ ! "$status" =~ ^(pending|active|running)$ ]]; then
        return
    fi

    ((TOTAL_WORKERS_CHECKED++))

    # Get time since last heartbeat
    local time_since=$(get_time_since_heartbeat "$worker_id")
    local health_status=$(jq -r '.heartbeat.health.status // "unknown"' "$spec_file" 2>/dev/null)

    # Check heartbeat status and take appropriate action
    if is_heartbeat_zombie "$worker_id"; then
        ((WORKERS_ZOMBIE++))
        log_monitor "CRITICAL: Worker $worker_id zombie detected (no heartbeat for ${time_since}s)"

        # Emit zombie detection event
        emit_heartbeat_event "worker_presumed_dead" "$worker_id" "$task_id" "$time_since" "unresponsive"

        # Trigger zombie cleanup (Phase 4.2)
        log_monitor "INFO: Initiating zombie cleanup for $worker_id"

        # Run cleanup in background to not block monitoring loop
        (
            cleanup_zombie_worker "$worker_id" &
        ) &

        log_monitor "INFO: Zombie cleanup initiated for $worker_id (background process)"

    elif is_heartbeat_critical "$worker_id"; then
        ((WORKERS_CRITICAL++))
        log_monitor "ERROR: Worker $worker_id critical (no heartbeat for ${time_since}s)"

        # Update missed count
        jq --argjson missed_count "$((time_since / HEARTBEAT_INTERVAL_SECONDS))" \
           '.heartbeat.missed_count = $missed_count | .heartbeat.health.status = "unresponsive"' \
           "$spec_file" > "${spec_file}.tmp" && \
           mv "${spec_file}.tmp" "$spec_file"

        # Emit critical alert
        emit_heartbeat_event "heartbeat_critical" "$worker_id" "$task_id" "$time_since" "unresponsive"

    elif is_heartbeat_warning "$worker_id"; then
        ((WORKERS_WARNING++))
        log_monitor "WARN: Worker $worker_id missing heartbeats (no heartbeat for ${time_since}s)"

        # Update missed count
        jq --argjson missed_count "$((time_since / HEARTBEAT_INTERVAL_SECONDS))" \
           '.heartbeat.missed_count = $missed_count' \
           "$spec_file" > "${spec_file}.tmp" && \
           mv "${spec_file}.tmp" "$spec_file"

        # Emit warning
        emit_heartbeat_event "heartbeat_warning" "$worker_id" "$task_id" "$time_since" "$health_status"

    else
        # Worker is healthy
        if [ "$health_status" = "degraded" ]; then
            ((WORKERS_DEGRADED++))
            log_monitor "INFO: Worker $worker_id degraded but heartbeat OK (last: ${time_since}s ago)"
        else
            ((WORKERS_HEALTHY++))
        fi

        # Check if worker was previously in warning/critical state
        local missed_count=$(jq -r '.heartbeat.missed_count // 0' "$spec_file" 2>/dev/null)
        if [ "$missed_count" -gt 0 ]; then
            log_monitor "INFO: Worker $worker_id heartbeat resumed"
            emit_heartbeat_event "heartbeat_resumed" "$worker_id" "$task_id" "$time_since" "$health_status"

            # Reset missed count
            jq '.heartbeat.missed_count = 0' "$spec_file" > "${spec_file}.tmp" && \
               mv "${spec_file}.tmp" "$spec_file"
        fi
    fi
}

# ============================================================================
# Metrics Collection
# ============================================================================

save_metrics() {
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)
    local metrics_json=$(jq -nc \
        --arg timestamp "$timestamp" \
        --argjson total "$TOTAL_WORKERS_CHECKED" \
        --argjson healthy "$WORKERS_HEALTHY" \
        --argjson degraded "$WORKERS_DEGRADED" \
        --argjson warning "$WORKERS_WARNING" \
        --argjson critical "$WORKERS_CRITICAL" \
        --argjson zombie "$WORKERS_ZOMBIE" \
        '{
            timestamp: $timestamp,
            total_workers_checked: $total,
            workers_healthy: $healthy,
            workers_degraded: $degraded,
            workers_warning: $warning,
            workers_critical: $critical,
            workers_zombie: $zombie,
            health_percentage: (if $total > 0 then ($healthy * 100 / $total) else 100 end)
        }')

    echo "$metrics_json" > "$METRICS_FILE"

    # Also append to time series log
    local metrics_log="${COMMIT_RELAY_HOME}/coordination/metrics/heartbeat-monitor-history.jsonl"
    mkdir -p "$(dirname "$metrics_log")"
    echo "$metrics_json" >> "$metrics_log"
}

# ============================================================================
# Main Monitor Loop
# ============================================================================

while true; do
    cd "$COMMIT_RELAY_HOME"

    # Reset counters
    TOTAL_WORKERS_CHECKED=0
    WORKERS_HEALTHY=0
    WORKERS_DEGRADED=0
    WORKERS_WARNING=0
    WORKERS_CRITICAL=0
    WORKERS_ZOMBIE=0

    log_monitor "INFO: Starting heartbeat monitoring cycle"

    # Monitor all active workers
    ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"

    if [ -d "$ACTIVE_SPECS_DIR" ]; then
        for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
            if [ ! -f "$spec_file" ]; then
                continue
            fi

            monitor_worker_heartbeat "$spec_file"
        done
    fi

    # Save metrics
    save_metrics

    # Log summary
    log_monitor "INFO: Monitoring cycle complete - Total: $TOTAL_WORKERS_CHECKED, Healthy: $WORKERS_HEALTHY, Degraded: $WORKERS_DEGRADED, Warning: $WORKERS_WARNING, Critical: $WORKERS_CRITICAL, Zombie: $WORKERS_ZOMBIE"

    # Sleep until next cycle
    sleep "$POLL_INTERVAL"
done
