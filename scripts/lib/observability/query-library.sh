#!/usr/bin/env bash
#
# Pre-Built Query Library
# Part of Q2 Week 20: Query Engine & Dashboards
#
# Collection of useful observability queries
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source the query engine
if [[ -f "$PROJECT_ROOT/scripts/obs-query.sh" ]]; then
    OBS_QUERY="$PROJECT_ROOT/scripts/obs-query.sh"
else
    echo "Error: obs-query.sh not found" >&2
    exit 1
fi

#
# Query 1: Recent Failed Tasks
#
query_failed_tasks() {
    local timeframe="${1:-1h}"
    echo "=== Recent Failed Tasks (last $timeframe) ===" >&2
    "$OBS_QUERY" "SELECT * FROM events WHERE type=task_failed AND timestamp > now-$timeframe LIMIT 20"
}

#
# Query 2: Slowest Traces
#
query_slowest_traces() {
    local limit="${1:-10}"
    echo "=== Slowest Traces (top $limit) ===" >&2
    "$OBS_QUERY" "SELECT * FROM traces ORDER BY duration_ms DESC LIMIT $limit"
}

#
# Query 3: Critical Anomalies
#
query_critical_anomalies() {
    echo "=== Critical Anomalies (Active) ===" >&2
    "$OBS_QUERY" "SELECT * FROM anomalies WHERE severity=critical AND status=active"
}

#
# Query 4: Worker Activity
#
query_worker_activity() {
    local timeframe="${1:-1h}"
    echo "=== Worker Activity (last $timeframe) ===" >&2
    "$OBS_QUERY" "SELECT * FROM events WHERE category=worker AND timestamp > now-$timeframe LIMIT 50"
}

#
# Query 5: High Severity Anomalies
#
query_high_severity_anomalies() {
    echo "=== High Severity Anomalies ===" >&2
    "$OBS_QUERY" "SELECT * FROM anomalies WHERE severity=high OR severity=critical LIMIT 20"
}

#
# Query 6: Recent System Errors
#
query_system_errors() {
    local timeframe="${1:-1h}"
    echo "=== System Errors (last $timeframe) ===" >&2
    "$OBS_QUERY" "SELECT * FROM events WHERE category=error AND timestamp > now-$timeframe LIMIT 30"
}

#
# Query 7: Task Success Rate
#
query_task_metrics() {
    echo "=== Task Metrics ===" >&2
    "$OBS_QUERY" "SELECT * FROM metrics WHERE metric_name=task_success_rate LIMIT 20"
}

#
# Query 8: Token Usage Spikes
#
query_token_anomalies() {
    echo "=== Token Usage Anomalies ===" >&2
    "$OBS_QUERY" "SELECT * FROM anomalies WHERE type=token_usage_spike LIMIT 10"
}

#
# Query 9: Recent Traces (Last Hour)
#
query_recent_traces() {
    local timeframe="${1:-1h}"
    echo "=== Recent Traces (last $timeframe) ===" >&2
    "$OBS_QUERY" "SELECT * FROM traces WHERE timestamp > now-$timeframe LIMIT 15"
}

#
# Query 10: Master Routing Events
#
query_routing_events() {
    local timeframe="${1:-1h}"
    echo "=== Routing Events (last $timeframe) ===" >&2
    "$OBS_QUERY" "SELECT * FROM events WHERE type=task_routed AND timestamp > now-$timeframe LIMIT 25"
}

#
# Query 11: Active Anomalies Summary
#
query_anomaly_summary() {
    echo "=== Active Anomalies Summary ===" >&2
    "$OBS_QUERY" "SELECT * FROM anomalies WHERE status=active LIMIT 50"
}

#
# Query 12: Queue Depth Anomalies
#
query_queue_anomalies() {
    echo "=== Queue Depth Anomalies ===" >&2
    "$OBS_QUERY" "SELECT * FROM anomalies WHERE type=queue_depth_explosion LIMIT 10"
}

#
# List all available queries
#
list_queries() {
    cat <<EOF
Pre-Built Query Library
========================

Available Queries:

1.  query_failed_tasks [timeframe]         - Recent failed tasks (default: 1h)
2.  query_slowest_traces [limit]           - Slowest traces (default: top 10)
3.  query_critical_anomalies               - Critical active anomalies
4.  query_worker_activity [timeframe]      - Worker events (default: 1h)
5.  query_high_severity_anomalies          - High/Critical anomalies
6.  query_system_errors [timeframe]        - System errors (default: 1h)
7.  query_task_metrics                     - Task success rate metrics
8.  query_token_anomalies                  - Token usage spikes
9.  query_recent_traces [timeframe]        - Recent traces (default: 1h)
10. query_routing_events [timeframe]       - Task routing events (default: 1h)
11. query_anomaly_summary                  - All active anomalies
12. query_queue_anomalies                  - Queue depth explosions

Usage:
  source scripts/lib/observability/query-library.sh
  query_failed_tasks
  query_slowest_traces 5
  query_critical_anomalies

Examples:
  # Get failed tasks from last 30 minutes
  query_failed_tasks 30m

  # Get top 20 slowest traces
  query_slowest_traces 20

  # Get all critical anomalies
  query_critical_anomalies

EOF
}

# Export functions
export -f query_failed_tasks
export -f query_slowest_traces
export -f query_critical_anomalies
export -f query_worker_activity
export -f query_high_severity_anomalies
export -f query_system_errors
export -f query_task_metrics
export -f query_token_anomalies
export -f query_recent_traces
export -f query_routing_events
export -f query_anomaly_summary
export -f query_queue_anomalies
export -f list_queries

# Show help if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    list_queries
fi
