#!/usr/bin/env bash
#
# Observability Query Engine
# Part of Q2 Week 20: Query Engine & Dashboards
#
# SQL-like query language for events, metrics, traces, and anomalies
#
# Usage:
#   obs-query "SELECT * FROM events WHERE type='task' LIMIT 10"
#   obs-query "SELECT master, SUM(tokens) FROM metrics GROUP BY master"
#   obs-query "SELECT task_id, duration_ms FROM traces ORDER BY duration_ms DESC LIMIT 5"
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Query cache configuration
readonly CACHE_DIR="${CACHE_DIR:-coordination/observability/query-cache}"
readonly CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-300}"  # 5 minutes
readonly ENABLE_CACHE="${ENABLE_CACHE:-true}"

# Data directories
readonly EVENTS_DIR="coordination/observability/events"
readonly METRICS_DIR="coordination/observability/metrics"
readonly TRACES_DIR="coordination/observability/traces"
readonly ANOMALIES_DIR="coordination/observability/anomalies"

# Initialize cache
mkdir -p "$CACHE_DIR"

#
# Parse time expression (e.g., "now-1h", "now-7d")
#
parse_time_expression() {
    local expr="$1"

    if [[ "$expr" == "now" ]]; then
        date +%s
        return 0
    fi

    if [[ "$expr" =~ ^now-([0-9]+)([smhd])$ ]]; then
        local value="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        local seconds=0

        case "$unit" in
            s) seconds=$value ;;
            m) seconds=$((value * 60)) ;;
            h) seconds=$((value * 3600)) ;;
            d) seconds=$((value * 86400)) ;;
        esac

        echo $(($(date +%s) - seconds))
        return 0
    fi

    # If it's just a number, return it
    if [[ "$expr" =~ ^[0-9]+$ ]]; then
        echo "$expr"
        return 0
    fi

    echo "0"
}

#
# Generate cache key from query
#
generate_cache_key() {
    local query="$1"
    echo -n "$query" | md5sum | cut -d' ' -f1
}

#
# Check cache for query result
#
check_cache() {
    local query="$1"

    if [[ "$ENABLE_CACHE" != "true" ]]; then
        return 1
    fi

    local cache_key=$(generate_cache_key "$query")
    local cache_file="$CACHE_DIR/${cache_key}.json"

    if [[ -f "$cache_file" ]]; then
        local cache_time=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        local now=$(date +%s)
        local age=$((now - cache_time))

        if [[ $age -lt $CACHE_TTL_SECONDS ]]; then
            cat "$cache_file"
            return 0
        else
            rm -f "$cache_file"
        fi
    fi

    return 1
}

#
# Save query result to cache
#
save_cache() {
    local query="$1"
    local result="$2"

    if [[ "$ENABLE_CACHE" != "true" ]]; then
        return 0
    fi

    local cache_key=$(generate_cache_key "$query")
    local cache_file="$CACHE_DIR/${cache_key}.json"

    echo "$result" > "$cache_file"
}

#
# Parse SELECT clause
#
parse_select() {
    local select_clause="$1"

    # Handle SELECT *
    if [[ "$select_clause" == "*" ]]; then
        echo "."
        return 0
    fi

    # Handle aggregations and field selections
    # This is a simplified parser - real implementation would be more robust
    echo "$select_clause"
}

#
# Parse WHERE clause into jq filter
#
parse_where() {
    local where_clause="$1"

    if [[ -z "$where_clause" ]]; then
        echo "true"
        return 0
    fi

    # Convert SQL-like WHERE to jq filter
    # Simple conversions:
    # type='task' -> .type == "task"
    # timestamp > now-1h -> .timestamp > <calculated_value>
    # status='failed' -> .status == "failed"

    local jq_filter="$where_clause"

    # Replace single quotes with double quotes
    jq_filter=$(echo "$jq_filter" | sed "s/'//g")

    # Handle time expressions
    if [[ "$jq_filter" =~ now-[0-9]+[smhd] ]]; then
        local time_expr=$(echo "$jq_filter" | grep -o 'now-[0-9]*[smhd]')
        local time_value=$(parse_time_expression "$time_expr")
        jq_filter=$(echo "$jq_filter" | sed "s/timestamp > $time_expr/.timestamp > $time_value/")
        jq_filter=$(echo "$jq_filter" | sed "s/timestamp < $time_expr/.timestamp < $time_value/")
        jq_filter=$(echo "$jq_filter" | sed "s/timestamp >= $time_expr/.timestamp >= $time_value/")
        jq_filter=$(echo "$jq_filter" | sed "s/timestamp <= $time_expr/.timestamp <= $time_value/")
    fi

    # Convert field comparisons
    jq_filter=$(echo "$jq_filter" | sed 's/\([a-z_]*\) *= *\([a-z0-9_]*\)/.\1 == "\2"/g')
    jq_filter=$(echo "$jq_filter" | sed 's/\([a-z_]*\) *!= *\([a-z0-9_]*\)/.\1 != "\2"/g')

    # Handle AND/OR
    jq_filter=$(echo "$jq_filter" | sed 's/ AND / and /g')
    jq_filter=$(echo "$jq_filter" | sed 's/ OR / or /g')

    echo "$jq_filter"
}

#
# Query events
#
query_events() {
    local where_filter="$1"
    local limit="${2:-100}"

    # Find all event JSONL files
    local event_files=$(find "$EVENTS_DIR" -name "*.jsonl" 2>/dev/null | head -10)

    if [[ -z "$event_files" ]]; then
        echo "[]"
        return 0
    fi

    # Query events
    local results="[]"
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local file_results=$(cat "$file" | jq -s "map(select($where_filter)) | .[:$limit]" 2>/dev/null || echo "[]")
            results=$(echo "$results" | jq ". + $file_results" 2>/dev/null || echo "[]")
        fi
    done <<< "$event_files"

    echo "$results" | jq ".[:$limit]"
}

#
# Query metrics
#
query_metrics() {
    local where_filter="$1"
    local limit="${2:-100}"

    # Find metric snapshot files
    local metric_files=$(find "$METRICS_DIR" -name "*.json" -o -name "*.jsonl" 2>/dev/null | head -10)

    if [[ -z "$metric_files" ]]; then
        echo "[]"
        return 0
    fi

    local results="[]"
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            # Handle both single JSON and JSONL
            if [[ "$file" == *.jsonl ]]; then
                local file_results=$(cat "$file" | jq -s "map(select($where_filter)) | .[:$limit]" 2>/dev/null || echo "[]")
            else
                local file_results=$(cat "$file" | jq "select($where_filter) | [.]" 2>/dev/null || echo "[]")
            fi
            results=$(echo "$results" | jq ". + $file_results" 2>/dev/null || echo "[]")
        fi
    done <<< "$metric_files"

    echo "$results" | jq ".[:$limit]"
}

#
# Query traces
#
query_traces() {
    local where_filter="$1"
    local limit="${2:-100}"

    # Find completed trace files
    local trace_files=$(find "$TRACES_DIR/completed" -name "*.json" 2>/dev/null | head -20)

    if [[ -z "$trace_files" ]]; then
        echo "[]"
        return 0
    fi

    local results="[]"
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local file_result=$(cat "$file" | jq "select($where_filter) | [.]" 2>/dev/null || echo "[]")
            results=$(echo "$results" | jq ". + $file_result" 2>/dev/null || echo "[]")
        fi
    done <<< "$trace_files"

    echo "$results" | jq ".[:$limit]"
}

#
# Query anomalies
#
query_anomalies() {
    local where_filter="$1"
    local limit="${2:-100}"

    # Find anomaly files (both active and resolved)
    local anomaly_files=$(find "$ANOMALIES_DIR/active" "$ANOMALIES_DIR/resolved" -name "*.json" 2>/dev/null | head -20)

    if [[ -z "$anomaly_files" ]]; then
        echo "[]"
        return 0
    fi

    local results="[]"
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local file_result=$(cat "$file" | jq "select($where_filter) | [.]" 2>/dev/null || echo "[]")
            results=$(echo "$results" | jq ". + $file_result" 2>/dev/null || echo "[]")
        fi
    done <<< "$anomaly_files"

    echo "$results" | jq ".[:$limit]"
}

#
# Apply GROUP BY aggregation
#
apply_group_by() {
    local data="$1"
    local group_field="$2"
    local agg_expr="$3"

    # Simple GROUP BY implementation
    echo "$data" | jq "group_by(.$group_field) | map({
        key: .[0].$group_field,
        count: length,
        values: .
    })"
}

#
# Apply ORDER BY
#
apply_order_by() {
    local data="$1"
    local order_field="$2"
    local order_dir="${3:-ASC}"

    if [[ "$order_dir" == "DESC" ]]; then
        echo "$data" | jq "sort_by(.$order_field) | reverse"
    else
        echo "$data" | jq "sort_by(.$order_field)"
    fi
}

#
# Execute query
#
execute_query() {
    local query="$1"

    # Check cache first
    local cached_result=$(check_cache "$query")
    if [[ -n "$cached_result" && "$cached_result" != "" ]]; then
        echo "$cached_result"
        return 0
    fi

    # Parse query
    # Extract components using regex
    local from_clause=""
    local where_clause=""
    local limit_clause="100"
    local order_by_clause=""
    local group_by_clause=""

    # Extract FROM
    if [[ "$query" =~ FROM[[:space:]]+([a-z]+) ]]; then
        from_clause="${BASH_REMATCH[1]}"
    else
        echo "{\"error\": \"No FROM clause found\"}"
        return 1
    fi

    # Extract WHERE (capture until GROUP BY, ORDER BY, or LIMIT)
    if [[ "$query" =~ WHERE[[:space:]]+(.+) ]]; then
        where_clause="${BASH_REMATCH[1]}"
        # Remove trailing clauses
        where_clause=$(echo "$where_clause" | sed 's/GROUP BY.*//' | sed 's/ORDER BY.*//' | sed 's/LIMIT.*//' | sed 's/[[:space:]]*$//')
    fi

    # Extract LIMIT
    if [[ "$query" =~ LIMIT[[:space:]]+([0-9]+) ]]; then
        limit_clause="${BASH_REMATCH[1]}"
    fi

    # Extract ORDER BY
    if [[ "$query" =~ ORDER[[:space:]]+BY[[:space:]]+([a-z_]+) ]]; then
        order_by_clause="${BASH_REMATCH[1]}"
    fi

    # Convert WHERE to jq filter
    local jq_filter=$(parse_where "$where_clause")

    # Execute query based on source
    local results=""
    case "$from_clause" in
        events)
            results=$(query_events "$jq_filter" "$limit_clause")
            ;;
        metrics)
            results=$(query_metrics "$jq_filter" "$limit_clause")
            ;;
        traces)
            results=$(query_traces "$jq_filter" "$limit_clause")
            ;;
        anomalies)
            results=$(query_anomalies "$jq_filter" "$limit_clause")
            ;;
        *)
            echo "{\"error\": \"Unknown source: $from_clause\"}"
            return 1
            ;;
    esac

    # Apply ORDER BY if specified
    if [[ -n "$order_by_clause" ]]; then
        local order_dir="ASC"
        [[ "$query" =~ DESC ]] && order_dir="DESC"
        results=$(apply_order_by "$results" "$order_by_clause" "$order_dir")
    fi

    # Cache results
    save_cache "$query" "$results"

    echo "$results"
}

#
# Main CLI
#
main() {
    local query="${1:-}"

    if [[ -z "$query" ]]; then
        cat <<EOF
Observability Query Engine

Usage: $0 "<query>"

Query Syntax:
  SELECT <fields> FROM <source> [WHERE <conditions>] [ORDER BY <field> [ASC|DESC]] [LIMIT <n>]

Sources:
  - events      Query event stream
  - metrics     Query metrics data
  - traces      Query distributed traces
  - anomalies   Query detected anomalies

Examples:
  # Recent failed tasks
  $0 "SELECT * FROM events WHERE type=task AND status=failed LIMIT 10"

  # Slow traces
  $0 "SELECT * FROM traces ORDER BY duration_ms DESC LIMIT 5"

  # Critical anomalies
  $0 "SELECT * FROM anomalies WHERE severity=critical"

  # Recent events (last hour)
  $0 "SELECT * FROM events WHERE timestamp > now-1h"

Options:
  --no-cache    Disable query result caching
  --clear-cache Clear the query cache

EOF
        return 0
    fi

    # Handle special commands
    case "$query" in
        --clear-cache)
            rm -rf "$CACHE_DIR"/*
            echo "Cache cleared"
            return 0
            ;;
        --no-cache)
            export ENABLE_CACHE="false"
            return 0
            ;;
    esac

    # Execute query
    local start_time_raw=$(date +%s%3N 2>/dev/null)
    if [[ "$start_time_raw" =~ N$ ]]; then
        start_time=$(($(date +%s) * 1000))
    else
        start_time="$start_time_raw"
    fi

    local results=$(execute_query "$query")

    local end_time_raw=$(date +%s%3N 2>/dev/null)
    if [[ "$end_time_raw" =~ N$ ]]; then
        end_time=$(($(date +%s) * 1000))
    else
        end_time="$end_time_raw"
    fi

    local duration=$((end_time - start_time))

    # Output results with metadata
    echo "$results" | jq -c \
        --arg query "$query" \
        --arg duration "$duration" \
        '{
            results: .,
            metadata: {
                query: $query,
                result_count: (. | length),
                query_time_ms: ($duration | tonumber),
                cached: false
            }
        }'
}

# Execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
