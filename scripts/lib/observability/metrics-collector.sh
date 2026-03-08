#!/usr/bin/env bash
#
# Metrics Collector Library for Unified Observability
# Part of Q2 Week 15-16: Metrics Collection System
#
# Usage:
#   source scripts/lib/observability/metrics-collector.sh
#   record_counter "tasks_completed" 1 '{"master_id":"development-master"}'
#   record_gauge "active_workers" 5 '{"worker_type":"scan"}'
#   record_histogram "task_duration_ms" 1500 '{"task_type":"implementation"}'
#

set -euo pipefail

# Configuration
readonly METRICS_RAW_DIR="${METRICS_RAW_DIR:-coordination/observability/metrics/raw}"
readonly METRICS_AGG_DIR="${METRICS_AGG_DIR:-coordination/observability/metrics/aggregated}"
readonly METRICS_INDEX_DIR="${METRICS_INDEX_DIR:-coordination/observability/metrics/indices}"
readonly METRICS_ROLLUP_DIR="${METRICS_ROLLUP_DIR:-coordination/observability/metrics/rollups}"
readonly ENABLE_METRICS="${ENABLE_METRICS:-true}"
readonly METRICS_BUFFER_SIZE="${METRICS_BUFFER_SIZE:-1000}"
readonly METRICS_FLUSH_INTERVAL="${METRICS_FLUSH_INTERVAL:-60}"

# Initialize directories
mkdir -p "$METRICS_RAW_DIR" "$METRICS_AGG_DIR" "$METRICS_INDEX_DIR" "$METRICS_ROLLUP_DIR"

# Cache
readonly CACHED_SOURCE="$(basename "${BASH_SOURCE[1]}" .sh 2>/dev/null || echo "unknown")"

#
# Generate metric ID
#
generate_metric_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 3)
    echo "metric-${timestamp}-${random}"
}

#
# Get current timestamp in milliseconds
#
get_timestamp_ms() {
    date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000))
}

#
# Record a metric (internal function)
#
record_metric() {
    if [[ "$ENABLE_METRICS" != "true" ]]; then
        return 0
    fi

    local metric_name="$1"
    local metric_type="$2"
    local value="$3"
    local unit="${4:-count}"
    local dimensions="${5:-{}}"
    local source="${6:-$CACHED_SOURCE}"

    local start_time=$(date +%s%N)

    local metric_id=$(generate_metric_id)
    local timestamp=$(get_timestamp_ms)

    # Parse dimensions safely
    local dims_json="$dimensions"
    if ! echo "$dims_json" | jq empty 2>/dev/null; then
        dims_json="{}"
    fi

    # Build metric JSON
    local metric_json=$(jq -n \
        --arg metric_id "$metric_id" \
        --arg timestamp "$timestamp" \
        --arg metric_name "$metric_name" \
        --arg metric_type "$metric_type" \
        --arg value "$value" \
        --arg unit "$unit" \
        --arg source "$source" \
        --argjson dimensions "$dims_json" \
        '{
            metric_id: $metric_id,
            timestamp: ($timestamp | tonumber),
            metric_name: $metric_name,
            metric_type: $metric_type,
            value: ($value | tonumber),
            unit: $unit,
            dimensions: $dimensions,
            metadata: {
                source: $source
            }
        }' 2>/dev/null || echo "{}")

    # Write to raw metrics file (daily partitioned)
    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"
    echo "$metric_json" >> "$metrics_file"

    # Update index asynchronously
    update_metric_index "$metric_name" "$timestamp" "$dimensions" &

    # Calculate overhead
    local end_time=$(date +%s%N)
    local duration_ns=$((end_time - start_time))
    local duration_ms=$((duration_ns / 1000000))

    if [[ $duration_ms -gt 5 ]]; then
        echo "Warning: Metric collection took ${duration_ms}ms (exceeds 5ms target)" >&2
    fi

    return 0
}

#
# Record a COUNTER metric
# Counters are cumulative values that only increase (e.g., total requests, errors)
#
record_counter() {
    local metric_name="$1"
    local increment="${2:-1}"
    local dimensions="${3:-{}}"

    record_metric "$metric_name" "counter" "$increment" "count" "$dimensions"
}

#
# Record a GAUGE metric
# Gauges are point-in-time values that can go up or down (e.g., active workers, queue depth)
#
record_gauge() {
    local metric_name="$1"
    local value="$2"
    local dimensions="${3:-{}}"
    local unit="${4:-count}"

    record_metric "$metric_name" "gauge" "$value" "$unit" "$dimensions"
}

#
# Record a HISTOGRAM metric
# Histograms track distributions of values (e.g., response times, sizes)
#
record_histogram() {
    local metric_name="$1"
    local value="$2"
    local dimensions="${3:-{}}"
    local unit="${4:-milliseconds}"

    record_metric "$metric_name" "histogram" "$value" "$unit" "$dimensions"
}

#
# Record a SUMMARY metric (pre-computed percentiles)
#
record_summary() {
    local metric_name="$1"
    local value="$2"
    local dimensions="${3:-{}}"
    local unit="${4:-milliseconds}"

    record_metric "$metric_name" "summary" "$value" "$unit" "$dimensions"
}

#
# Update metric index for fast querying
#
update_metric_index() {
    local metric_name="$1"
    local timestamp="$2"
    local dimensions="$3"

    local index_file="$METRICS_INDEX_DIR/${metric_name}.index"

    # Simple index: metric_name -> list of timestamps
    echo "$timestamp" >> "$index_file"

    # Dimensional indices (if dimensions provided)
    if [[ "$dimensions" != "{}" ]]; then
        local task_id=$(echo "$dimensions" | jq -r '.task_id // empty')
        if [[ -n "$task_id" ]]; then
            echo "$timestamp:$metric_name" >> "$METRICS_INDEX_DIR/by-task-${task_id}.index"
        fi

        local worker_id=$(echo "$dimensions" | jq -r '.worker_id // empty')
        if [[ -n "$worker_id" ]]; then
            echo "$timestamp:$metric_name" >> "$METRICS_INDEX_DIR/by-worker-${worker_id}.index"
        fi

        local master_id=$(echo "$dimensions" | jq -r '.master_id // empty')
        if [[ -n "$master_id" ]]; then
            echo "$timestamp:$metric_name" >> "$METRICS_INDEX_DIR/by-master-${master_id}.index"
        fi
    fi
}

#
# Query metrics by name
#
query_metrics() {
    local metric_name="$1"
    local since_ts="${2:-0}"
    local until_ts="${3:-9999999999999}"

    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        echo "[]"
        return
    fi

    cat "$metrics_file" | jq -s --arg name "$metric_name" \
                                --arg since "$since_ts" \
                                --arg until "$until_ts" \
                                'map(select(.metric_name == $name and .timestamp >= ($since | tonumber) and .timestamp <= ($until | tonumber)))'
}

#
# Query metrics by dimension
#
query_metrics_by_dimension() {
    local dimension_key="$1"
    local dimension_value="$2"
    local since_ts="${3:-0}"

    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        echo "[]"
        return
    fi

    cat "$metrics_file" | jq -s --arg key "$dimension_key" \
                                --arg value "$dimension_value" \
                                --arg since "$since_ts" \
                                "map(select(.dimensions.\"$dimension_key\" == \"$dimension_value\" and .timestamp >= ($since | tonumber)))"
}

#
# Calculate aggregations for a metric
#
aggregate_metrics() {
    local metric_name="$1"
    local window="${2:-1h}"  # 1m, 5m, 1h, 1d
    local since_ts="${3:-0}"

    local metrics=$(query_metrics "$metric_name" "$since_ts")

    # Calculate statistics
    echo "$metrics" | jq '{
        metric_name: "'"$metric_name"'",
        window: "'"$window"'",
        count: length,
        sum: (map(.value) | add // 0),
        min: (map(.value) | min // 0),
        max: (map(.value) | max // 0),
        mean: (if length > 0 then (map(.value) | add / length) else 0 end),
        p50: (map(.value) | sort | if length > 0 then .[length * 50 / 100 | floor] else 0 end),
        p95: (map(.value) | sort | if length > 0 then .[length * 95 / 100 | floor] else 0 end),
        p99: (map(.value) | sort | if length > 0 then .[length * 99 / 100 | floor] else 0 end),
        stddev: (
            if length > 1 then
                (. as $data |
                 (map(.value) | add / length) as $mean |
                 (map(.value) | map(. - $mean | . * .) | add / (length - 1) | sqrt))
            else 0 end
        )
    }'
}

#
# Get latest value for a gauge metric
#
get_latest_gauge() {
    local metric_name="$1"
    local dimensions="${2:-{}}"

    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        echo "0"
        return
    fi

    if [[ "$dimensions" == "{}" ]]; then
        cat "$metrics_file" | jq -r "select(.metric_name == \"$metric_name\") | .value" | tail -1
    else
        cat "$metrics_file" | jq -r --argjson dims "$dimensions" \
            'select(.metric_name == "'"$metric_name"'" and .dimensions == $dims) | .value' | tail -1
    fi
}

#
# Get counter total
#
get_counter_total() {
    local metric_name="$1"
    local since_ts="${2:-0}"

    local metrics=$(query_metrics "$metric_name" "$since_ts")
    echo "$metrics" | jq 'map(.value) | add // 0'
}

#
# Record task metrics (convenience wrapper)
#
record_task_metric() {
    local metric_name="$1"
    local value="$2"
    local task_id="$3"
    local additional_dims="${4:-{}}"

    local dimensions=$(echo "$additional_dims" | jq --arg task_id "$task_id" '. + {task_id: $task_id}')
    record_histogram "$metric_name" "$value" "$dimensions"
}

#
# Record worker metrics (convenience wrapper)
#
record_worker_metric() {
    local metric_name="$1"
    local value="$2"
    local worker_id="$3"
    local additional_dims="${4:-{}}"

    local dimensions=$(echo "$additional_dims" | jq --arg worker_id "$worker_id" '. + {worker_id: $worker_id}')
    record_histogram "$metric_name" "$value" "$dimensions"
}

#
# Record master metrics (convenience wrapper)
#
record_master_metric() {
    local metric_name="$1"
    local value="$2"
    local master_id="$3"
    local additional_dims="${4:-{}}"

    local dimensions=$(echo "$additional_dims" | jq --arg master_id "$master_id" '. + {master_id: $master_id}')
    record_histogram "$metric_name" "$value" "$dimensions"
}

#
# Create hourly rollup
#
create_hourly_rollup() {
    local metric_name="$1"
    local hour_timestamp="$2"  # Unix timestamp truncated to hour

    local since_ts=$((hour_timestamp * 1000))
    local until_ts=$(((hour_timestamp + 3600) * 1000))

    local metrics=$(query_metrics "$metric_name" "$since_ts" "$until_ts")
    local aggregates=$(echo "$metrics" | jq '{
        metric_name: "'"$metric_name"'",
        window: "1h",
        timestamp: '"$since_ts"',
        count: length,
        sum: (map(.value) | add // 0),
        min: (map(.value) | min // 0),
        max: (map(.value) | max // 0),
        mean: (if length > 0 then (map(.value) | add / length) else 0 end),
        p50: (map(.value) | sort | if length > 0 then .[length * 50 / 100 | floor] else 0 end),
        p95: (map(.value) | sort | if length > 0 then .[length * 95 / 100 | floor] else 0 end),
        p99: (map(.value) | sort | if length > 0 then .[length * 99 / 100 | floor] else 0 end)
    }')

    local rollup_file="$METRICS_ROLLUP_DIR/hourly-$(date -d @$hour_timestamp +%Y-%m-%d).jsonl"
    echo "$aggregates" >> "$rollup_file"
}

#
# Create daily rollup
#
create_daily_rollup() {
    local metric_name="$1"
    local day="$2"  # YYYY-MM-DD

    local hourly_file="$METRICS_ROLLUP_DIR/hourly-${day}.jsonl"

    if [[ ! -f "$hourly_file" ]]; then
        return 0
    fi

    cat "$hourly_file" | jq -s --arg name "$metric_name" '
        map(select(.metric_name == $name)) |
        {
            metric_name: $name,
            window: "1d",
            day: "'"$day"'",
            count: (map(.count) | add // 0),
            sum: (map(.sum) | add // 0),
            min: (map(.min) | min // 0),
            max: (map(.max) | max // 0),
            mean: (if (map(.count) | add) > 0 then (map(.sum) | add) / (map(.count) | add) else 0 end),
            p95_max: (map(.p95) | max // 0),
            p99_max: (map(.p99) | max // 0)
        }
    ' >> "$METRICS_ROLLUP_DIR/daily-${day}.json"
}

#
# Get metrics dashboard data
#
get_metrics_dashboard() {
    local timeframe="${1:-1h}"

    local now=$(date +%s)
    local since=0

    case "$timeframe" in
        "5m")
            since=$((now - 300))
            ;;
        "1h")
            since=$((now - 3600))
            ;;
        "24h")
            since=$((now - 86400))
            ;;
        "7d")
            since=$((now - 604800))
            ;;
    esac

    local since_ms=$((since * 1000))

    # Collect key metrics
    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    if [[ ! -f "$metrics_file" ]]; then
        echo '{}'
        return
    fi

    cat "$metrics_file" | jq -s --arg since "$since_ms" '
        map(select(.timestamp >= ($since | tonumber))) |
        group_by(.metric_name) |
        map({
            metric: .[0].metric_name,
            type: .[0].metric_type,
            unit: .[0].unit,
            latest: (map(.value) | last),
            count: length,
            min: (map(.value) | min),
            max: (map(.value) | max),
            mean: (map(.value) | add / length),
            p95: (map(.value) | sort | .[length * 95 / 100 | floor])
        }) |
        from_entries
    '
}

#
# Cleanup old metrics (retention policy)
#
cleanup_old_metrics() {
    local retention_days="${1:-30}"

    # Delete raw metrics older than retention period
    find "$METRICS_RAW_DIR" -name "metrics-*.jsonl" -mtime +$retention_days -delete

    # Keep rollups for longer (90 days)
    find "$METRICS_ROLLUP_DIR" -name "hourly-*.jsonl" -mtime +90 -delete
    find "$METRICS_ROLLUP_DIR" -name "daily-*.json" -mtime +365 -delete

    # Cleanup indices
    find "$METRICS_INDEX_DIR" -name "*.index" -mtime +$retention_days -delete
}

# Export functions
export -f record_counter
export -f record_gauge
export -f record_histogram
export -f record_summary
export -f record_task_metric
export -f record_worker_metric
export -f record_master_metric
export -f query_metrics
export -f query_metrics_by_dimension
export -f aggregate_metrics
export -f get_latest_gauge
export -f get_counter_total
export -f get_metrics_dashboard
export -f create_hourly_rollup
export -f create_daily_rollup
export -f cleanup_old_metrics
