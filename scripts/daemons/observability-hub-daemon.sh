#!/bin/bash
# scripts/daemons/observability-hub-daemon.sh
# ObservabilityHub Daemon - Real-time event aggregation and correlation
#
# Purpose:
# - Aggregate events from all-events.jsonl
# - Build correlation indices (by trace_id, worker_id, task_id)
# - Generate real-time summaries
# - Detect patterns and anomalies
#
# Usage:
#   ./observability-hub-daemon.sh start
#   ./observability-hub-daemon.sh stop
#   ./observability-hub-daemon.sh status

set -eo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

# Daemon configuration
DAEMON_NAME="observability-hub"
PID_FILE="/tmp/commit-relay-${DAEMON_NAME}.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/${DAEMON_NAME}.log"
ERROR_LOG="$COMMIT_RELAY_HOME/agents/logs/system/${DAEMON_NAME}-error.log"

# Event configuration
EVENT_FILE="$COMMIT_RELAY_HOME/coordination/observability/events/all-events.jsonl"
STREAM_DIR="$COMMIT_RELAY_HOME/coordination/observability/stream"
INDICES_DIR="$COMMIT_RELAY_HOME/coordination/observability/indices"

# Processing interval (seconds)
PROCESSING_INTERVAL=10

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$STREAM_DIR" 2>/dev/null || true
mkdir -p "$INDICES_DIR" 2>/dev/null || true

# Logging functions
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] $*" | tee -a "$ERROR_LOG"
}

# Track last processed position
POSITION_FILE="$STREAM_DIR/last-processed-position.txt"
get_last_position() {
    if [ -f "$POSITION_FILE" ]; then
        cat "$POSITION_FILE"
    else
        echo "0"
    fi
}

update_position() {
    echo "$1" > "$POSITION_FILE"
}

# Build correlation index for trace_id
build_trace_index() {
    log "Building trace_id correlation index..."

    local index_file="$INDICES_DIR/by-trace-id.json"
    local temp_file="${index_file}.tmp"

    # Group events by trace_id
    if [ -f "$EVENT_FILE" ]; then
        jq -s 'group_by(.trace_id) | map({
            trace_id: .[0].trace_id,
            event_count: length,
            first_event: .[0].timestamp,
            last_event: .[-1].timestamp,
            components: [.[].component] | unique,
            statuses: [.[].status] | unique,
            has_errors: (map(select(.status == "error" or .status == "failed")) | length > 0)
        })' "$EVENT_FILE" > "$temp_file" 2>/dev/null && mv "$temp_file" "$index_file"
    fi
}

# Build correlation index for worker_id
build_worker_index() {
    log "Building worker_id correlation index..."

    local index_file="$INDICES_DIR/by-worker-id.json"
    local temp_file="${index_file}.tmp"

    # Group events by worker_id (from component_id or metadata)
    if [ -f "$EVENT_FILE" ]; then
        jq -s '
            map(select(
                (.component_id // "" | type == "string" and startswith("worker-")) or
                ((.metadata // {}).worker_id // "" | type == "string" and startswith("worker-"))
            ))
            | group_by(.component_id // (.metadata.worker_id // "unknown"))
            | map({
                worker_id: (.[0].component_id // .[0].metadata.worker_id // "unknown"),
                event_count: length,
                first_seen: .[0].timestamp,
                last_seen: .[-1].timestamp,
                event_types: [.[].event_type] | unique,
                has_errors: (map(select(.status == "error" or .status == "failed")) | length > 0)
            })
        ' "$EVENT_FILE" > "$temp_file" 2>/dev/null && mv "$temp_file" "$index_file"
    fi
}

# Build correlation index for task_id
build_task_index() {
    log "Building task_id correlation index..."

    local index_file="$INDICES_DIR/by-task-id.json"
    local temp_file="${index_file}.tmp"

    # Group events by task_id (from metadata)
    if [ -f "$EVENT_FILE" ]; then
        jq -s '
            map(select((.metadata // {}).task_id != null))
            | group_by((.metadata // {}).task_id)
            | map({
                task_id: (.[0].metadata.task_id // "unknown"),
                event_count: length,
                first_event: .[0].timestamp,
                last_event: .[-1].timestamp,
                workers: [.[] | select((.component_id // "" | type == "string" and startswith("worker-"))) | .component_id] | unique,
                statuses: [.[].status] | unique
            })
        ' "$EVENT_FILE" > "$temp_file" 2>/dev/null && mv "$temp_file" "$index_file"
    fi
}

# Generate real-time summary
generate_summary() {
    log "Generating observability summary..."

    local summary_file="$STREAM_DIR/current-summary.json"
    local temp_file="${summary_file}.tmp"

    if [ ! -f "$EVENT_FILE" ]; then
        return 0
    fi

    # Calculate summary statistics
    local total_events=$(wc -l < "$EVENT_FILE" 2>/dev/null | tr -d ' ')
    local error_count=$(grep -c '"status":"error"' "$EVENT_FILE" 2>/dev/null | tr -d ' ')
    local failed_count=$(grep -c '"status":"failed"' "$EVENT_FILE" 2>/dev/null | tr -d ' ')

    # Get recent events (last 100)
    local recent_events=$(tail -100 "$EVENT_FILE" | jq -s 'length')

    # Get unique trace_ids (last 1000 events)
    local active_traces=$(tail -1000 "$EVENT_FILE" 2>/dev/null | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')

    # Get unique components
    local active_components=$(tail -1000 "$EVENT_FILE" 2>/dev/null | jq -r '.component' | sort -u | wc -l | tr -d ' ')

    # Build summary JSON
    cat > "$temp_file" <<EOF
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "statistics": {
    "total_events": $total_events,
    "error_count": $error_count,
    "failed_count": $failed_count,
    "recent_events_100": $recent_events,
    "active_traces_1000": $active_traces,
    "active_components_1000": $active_components
  },
  "health": {
    "status": $(if [ $error_count -gt 10 ] || [ $failed_count -gt 10 ]; then echo '"degraded"'; else echo '"healthy"'; fi),
    "error_rate": $(echo "scale=4; ($error_count + $failed_count) / $total_events" | bc 2>/dev/null || echo 0)
  }
}
EOF

    mv "$temp_file" "$summary_file"
}

# Process new events
process_events() {
    if [ ! -f "$EVENT_FILE" ]; then
        return 0
    fi

    local last_pos=$(get_last_position)
    local current_size=$(wc -l < "$EVENT_FILE" 2>/dev/null | tr -d ' ')

    if [ "$current_size" -gt "$last_pos" ]; then
        local new_events=$((current_size - last_pos))
        log "Processing $new_events new events (from line $((last_pos + 1)) to $current_size)"

        # Update indices
        build_trace_index
        build_worker_index
        build_task_index

        # Update summary
        generate_summary

        # Update position
        update_position "$current_size"

        log "Processed $new_events events successfully"
    fi
}

# Main daemon loop
daemon_loop() {
    log "ObservabilityHub daemon started (PID: $$)"
    log "Monitoring: $EVENT_FILE"
    log "Processing interval: ${PROCESSING_INTERVAL}s"

    # Initial processing
    process_events

    while true; do
        sleep "$PROCESSING_INTERVAL"
        process_events
    done
}

# Start daemon
start_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Daemon already running (PID: $pid)"
            return 1
        else
            # Stale PID file
            rm -f "$PID_FILE"
        fi
    fi

    echo "Starting ObservabilityHub daemon..."

    # Start daemon in background
    nohup bash "$0" _loop > "$LOG_FILE" 2> "$ERROR_LOG" &
    local pid=$!

    echo "$pid" > "$PID_FILE"

    sleep 1

    if ps -p "$pid" > /dev/null 2>&1; then
        echo "✅ ObservabilityHub daemon started (PID: $pid)"
        echo "   Logs: $LOG_FILE"
        echo "   Errors: $ERROR_LOG"
        return 0
    else
        echo "❌ Failed to start daemon"
        cat "$ERROR_LOG"
        return 1
    fi
}

# Stop daemon
stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Daemon not running (no PID file)"
        return 0
    fi

    local pid=$(cat "$PID_FILE")

    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Stopping ObservabilityHub daemon (PID: $pid)..."
        kill "$pid"

        # Wait for graceful shutdown
        for i in {1..10}; do
            if ! ps -p "$pid" > /dev/null 2>&1; then
                rm -f "$PID_FILE"
                echo "✅ Daemon stopped"
                return 0
            fi
            sleep 1
        done

        # Force kill if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "Force killing daemon..."
            kill -9 "$pid"
        fi

        rm -f "$PID_FILE"
        echo "✅ Daemon stopped (forced)"
    else
        echo "Daemon not running (stale PID file)"
        rm -f "$PID_FILE"
    fi

    return 0
}

# Show daemon status
show_status() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "✅ ObservabilityHub daemon is RUNNING (PID: $pid)"

            # Show statistics
            if [ -f "$STREAM_DIR/current-summary.json" ]; then
                echo ""
                echo "Current Statistics:"
                jq -r '
                    "  Total events: \(.statistics.total_events)",
                    "  Errors: \(.statistics.error_count)",
                    "  Failed: \(.statistics.failed_count)",
                    "  Active traces: \(.statistics.active_traces_1000)",
                    "  Health: \(.health.status)"
                ' "$STREAM_DIR/current-summary.json"
            fi

            # Show recent log
            if [ -f "$LOG_FILE" ]; then
                echo ""
                echo "Recent activity (last 5 lines):"
                tail -5 "$LOG_FILE" | sed 's/^/  /'
            fi

            return 0
        else
            echo "❌ Daemon not running (stale PID file)"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo "❌ ObservabilityHub daemon is NOT RUNNING"
        return 1
    fi
}

# Command handling
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
    _loop)
        # Internal: run daemon loop
        daemon_loop
        ;;
    *)
        cat <<EOF
Usage: $0 {start|stop|restart|status}

ObservabilityHub Daemon - Real-time event aggregation and correlation

Commands:
  start    Start the daemon
  stop     Stop the daemon
  restart  Restart the daemon
  status   Show daemon status

Configuration:
  Event file: $EVENT_FILE
  Stream dir: $STREAM_DIR
  Indices dir: $INDICES_DIR
  Processing interval: ${PROCESSING_INTERVAL}s

EOF
        exit 1
        ;;
esac
