#!/usr/bin/env bash
#
# Metrics Aggregator Daemon
# Part of Q2 Week 15-16: Metrics Collection System
#
# Runs in background to create hourly/daily rollups
# and perform continuous aggregations
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source metrics collector
source "$PROJECT_ROOT/scripts/lib/observability/metrics-collector.sh"

readonly PID_FILE="/tmp/commit-relay-metrics-aggregator.pid"
readonly LOG_FILE="$PROJECT_ROOT/coordination/observability/metrics/aggregator.log"
readonly AGGREGATION_INTERVAL=300  # 5 minutes

#
# Log message
#
log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

#
# Perform hourly aggregations
#
perform_hourly_aggregations() {
    log "Performing hourly aggregations..."

    local current_hour=$(date +%s)
    current_hour=$((current_hour - current_hour % 3600))  # Truncate to hour

    # Get list of metrics from today's raw data
    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        log "No metrics file found for today"
        return 0
    fi

    # Get unique metric names
    local metric_names=$(cat "$metrics_file" | jq -r '.metric_name' | sort -u)

    # Create rollup for each metric
    while IFS= read -r metric_name; do
        if [[ -n "$metric_name" ]]; then
            log "Creating hourly rollup for $metric_name"
            create_hourly_rollup "$metric_name" "$current_hour" || true
        fi
    done <<< "$metric_names"

    log "Hourly aggregations complete"
}

#
# Perform daily aggregations
#
perform_daily_aggregations() {
    log "Performing daily aggregations..."

    local yesterday=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)

    # Get list of metrics from yesterday's hourly rollups
    local hourly_file="$METRICS_ROLLUP_DIR/hourly-${yesterday}.jsonl"

    if [[ ! -f "$hourly_file" ]]; then
        log "No hourly rollup found for $yesterday"
        return 0
    fi

    # Get unique metric names
    local metric_names=$(cat "$hourly_file" | jq -r '.metric_name' | sort -u)

    # Create daily rollup for each metric
    while IFS= read -r metric_name; do
        if [[ -n "$metric_name" ]]; then
            log "Creating daily rollup for $metric_name"
            create_daily_rollup "$metric_name" "$yesterday" || true
        fi
    done <<< "$metric_names"

    log "Daily aggregations complete"
}

#
# Perform cleanup
#
perform_cleanup() {
    log "Performing cleanup (30 day retention)..."
    cleanup_old_metrics 30
    log "Cleanup complete"
}

#
# Main daemon loop
#
main_daemon_loop() {
    log "Metrics Aggregator Daemon started (PID: $$)"

    local last_hourly_check=0
    local last_daily_check=0
    local last_cleanup=0

    while true; do
        local now=$(date +%s)

        # Check if we're at the start of a new hour
        local current_hour=$((now - now % 3600))
        if [[ $current_hour -gt $last_hourly_check ]]; then
            perform_hourly_aggregations
            last_hourly_check=$current_hour
        fi

        # Check if we're at the start of a new day
        local current_day=$(date +%Y-%m-%d)
        local current_day_ts=$(date -d "$current_day" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$current_day" +%s)
        if [[ $current_day_ts -gt $last_daily_check ]]; then
            perform_daily_aggregations
            last_cleanup=$current_day_ts
        fi

        # Cleanup weekly
        if [[ $((now - last_cleanup)) -gt 604800 ]]; then
            perform_cleanup
            last_cleanup=$now
        fi

        # Sleep until next check
        sleep $AGGREGATION_INTERVAL
    done
}

#
# Start daemon
#
start_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local existing_pid=$(cat "$PID_FILE")
        if kill -0 "$existing_pid" 2>/dev/null; then
            echo "Metrics aggregator daemon already running (PID: $existing_pid)"
            return 0
        fi
    fi

    echo "Starting metrics aggregator daemon..."

    # Start in background
    nohup bash -c "$(declare -f main_daemon_loop perform_hourly_aggregations perform_daily_aggregations perform_cleanup log); main_daemon_loop" </dev/null >>"$LOG_FILE" 2>&1 &

    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"

    echo "Metrics aggregator daemon started (PID: $daemon_pid)"
    echo "Logs: $LOG_FILE"
}

#
# Stop daemon
#
stop_daemon() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo "Metrics aggregator daemon not running"
        return 0
    fi

    local daemon_pid=$(cat "$PID_FILE")

    if kill -0 "$daemon_pid" 2>/dev/null; then
        echo "Stopping metrics aggregator daemon (PID: $daemon_pid)..."
        kill "$daemon_pid"
        rm -f "$PID_FILE"
        echo "Daemon stopped"
    else
        echo "Daemon process not found, cleaning up..."
        rm -f "$PID_FILE"
    fi
}

#
# Get daemon status
#
get_status() {
    if [[ -f "$PID_FILE" ]]; then
        local daemon_pid=$(cat "$PID_FILE")
        if kill -0 "$daemon_pid" 2>/dev/null; then
            echo "Metrics aggregator daemon is running (PID: $daemon_pid)"
            return 0
        else
            echo "PID file exists but process is not running"
            return 1
        fi
    else
        echo "Metrics aggregator daemon is not running"
        return 1
    fi
}

#
# Main command dispatcher
#
case "${1:-start}" in
    "start")
        start_daemon
        ;;
    "stop")
        stop_daemon
        ;;
    "restart")
        stop_daemon
        sleep 1
        start_daemon
        ;;
    "status")
        get_status
        ;;
    "logs")
        tail -f "$LOG_FILE"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
