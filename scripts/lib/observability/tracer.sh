#!/usr/bin/env bash
#
# Distributed Tracer Library
# Part of Q2 Week 17-18: Distributed Tracing
#
# Usage:
#   source scripts/lib/observability/tracer.sh
#   trace_start "my_operation"
#   # ... do work ...
#   trace_end "ok"
#

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

readonly TRACES_ACTIVE_DIR="${TRACES_ACTIVE_DIR:-coordination/observability/traces/active}"
readonly TRACES_COMPLETED_DIR="${TRACES_COMPLETED_DIR:-coordination/observability/traces/completed}"
readonly TRACES_INDEX_DIR="${TRACES_INDEX_DIR:-coordination/observability/traces/indices}"
readonly ENABLE_TRACING="${ENABLE_TRACING:-true}"

# Initialize directories
mkdir -p "$TRACES_ACTIVE_DIR" "$TRACES_COMPLETED_DIR" "$TRACES_INDEX_DIR"

# Source event emitter for trace context functions
TRACER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$TRACER_SCRIPT_DIR/../observability/lib/event-emitter.sh" ]]; then
    source "$TRACER_SCRIPT_DIR/../observability/lib/event-emitter.sh" 2>/dev/null || true
fi

# Span stack for nested spans (stored in temp file)
readonly SPAN_STACK_FILE="/tmp/commit-relay-span-stack-$$.txt"
touch "$SPAN_STACK_FILE"

#
# Generate a trace ID (if not already defined by event-emitter)
#
if ! declare -f generate_trace_id >/dev/null; then
    generate_trace_id() {
        local timestamp=$(date +%s%N | cut -b1-13)
        local random=$(openssl rand -hex 6)
        echo "trace-${timestamp}-${random}"
    }
fi

#
# Generate a span ID (if not already defined by event-emitter)
#
if ! declare -f generate_span_id >/dev/null; then
    generate_span_id() {
        local random=$(openssl rand -hex 6)
        echo "span-${random}"
    }
fi

#
# Get current timestamp in milliseconds
#
get_timestamp_ms() {
    date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000))
}

#
# Push span to stack
#
push_span() {
    local span_id="$1"
    echo "$span_id" >> "$SPAN_STACK_FILE"
}

#
# Pop span from stack
#
pop_span() {
    if [[ -f "$SPAN_STACK_FILE" && -s "$SPAN_STACK_FILE" ]]; then
        local last_span=$(tail -1 "$SPAN_STACK_FILE")
        sed -i '$ d' "$SPAN_STACK_FILE" 2>/dev/null || sed -i '' -e '$ d' "$SPAN_STACK_FILE" 2>/dev/null
        echo "$last_span"
    else
        echo ""
    fi
}

#
# Get current span (peek stack)
#
get_current_span() {
    if [[ -f "$SPAN_STACK_FILE" && -s "$SPAN_STACK_FILE" ]]; then
        tail -1 "$SPAN_STACK_FILE"
    else
        echo ""
    fi
}

#
# Start a new trace (creates root span)
#
trace_create() {
    local operation_name="${1:-root_operation}"
    local attributes="${2:-{}}"

    if [[ "$ENABLE_TRACING" != "true" ]]; then
        return 0
    fi

    # Generate trace ID if not set
    if [[ -z "${TRACE_ID:-}" ]]; then
        export TRACE_ID=$(generate_trace_id)
    fi

    # Create root span
    export SPAN_ID=$(generate_span_id)
    export PARENT_SPAN_ID=""

    # Start the span
    trace_start "$operation_name" "$attributes" "internal"

    # Create trace metadata
    local start_time=$(get_timestamp_ms)
    local trace_file="$TRACES_ACTIVE_DIR/${TRACE_ID}.json"

    jq -n \
        --arg trace_id "$TRACE_ID" \
        --arg root_span_id "$SPAN_ID" \
        --arg start_time "$start_time" \
        --argjson attributes "$attributes" \
        '{
            trace_id: $trace_id,
            root_span_id: $root_span_id,
            start_time: ($start_time | tonumber),
            status: "active",
            span_count: 1,
            error_count: 0,
            attributes: $attributes,
            spans: []
        }' > "$trace_file"

    # Index by trace ID
    echo "$start_time:$TRACE_ID" >> "$TRACES_INDEX_DIR/by-time.index"

    # Index by attributes if present
    local task_id=$(echo "$attributes" | jq -r '.task_id // empty')
    if [[ -n "$task_id" ]]; then
        echo "$TRACE_ID" >> "$TRACES_INDEX_DIR/by-task-${task_id}.index"
    fi
}

#
# Start a new span within current trace
#
trace_start() {
    local span_name="${1:-unnamed_span}"
    local attributes="${2:-{}}"
    local kind="${3:-internal}"

    if [[ "$ENABLE_TRACING" != "true" ]]; then
        return 0
    fi

    # Ensure we have a trace
    if [[ -z "${TRACE_ID:-}" ]]; then
        trace_create "$span_name" "$attributes"
        return 0
    fi

    local start_time=$(get_timestamp_ms)
    local parent_span_id=$(get_current_span)

    # Generate new span ID
    local new_span_id=$(generate_span_id)

    # Create span file
    local span_file="$TRACES_ACTIVE_DIR/${TRACE_ID}-${new_span_id}.span"

    jq -n \
        --arg span_id "$new_span_id" \
        --arg trace_id "$TRACE_ID" \
        --arg parent_span_id "${parent_span_id:-null}" \
        --arg name "$span_name" \
        --arg start_time "$start_time" \
        --arg kind "$kind" \
        --argjson attributes "$attributes" \
        '{
            span_id: $span_id,
            trace_id: $trace_id,
            parent_span_id: (if $parent_span_id == "null" then null else $parent_span_id end),
            name: $name,
            start_time: ($start_time | tonumber),
            kind: $kind,
            status: "active",
            attributes: $attributes,
            events: []
        }' > "$span_file"

    # Update context
    export PARENT_SPAN_ID="$parent_span_id"
    export SPAN_ID="$new_span_id"

    # Push to stack
    push_span "$new_span_id"

    # Update trace span count
    local trace_file="$TRACES_ACTIVE_DIR/${TRACE_ID}.json"
    if [[ -f "$trace_file" ]]; then
        jq '.span_count += 1' "$trace_file" > "${trace_file}.tmp" && mv "${trace_file}.tmp" "$trace_file"
    fi
}

#
# Add an event to the current span
#
trace_event() {
    local event_name="$1"
    local event_attributes="${2:-{}}"

    if [[ "$ENABLE_TRACING" != "true" || -z "${SPAN_ID:-}" ]]; then
        return 0
    fi

    local timestamp=$(get_timestamp_ms)
    local span_file="$TRACES_ACTIVE_DIR/${TRACE_ID}-${SPAN_ID}.span"

    if [[ -f "$span_file" ]]; then
        local event_json=$(jq -n \
            --arg timestamp "$timestamp" \
            --arg name "$event_name" \
            --argjson attributes "$event_attributes" \
            '{
                timestamp: ($timestamp | tonumber),
                name: $name,
                attributes: $attributes
            }')

        jq --argjson event "$event_json" '.events += [$event]' "$span_file" > "${span_file}.tmp" && \
            mv "${span_file}.tmp" "$span_file"
    fi
}

#
# End the current span
#
trace_end() {
    local status="${1:-ok}"
    local error_message="${2:-}"

    if [[ "$ENABLE_TRACING" != "true" || -z "${SPAN_ID:-}" ]]; then
        return 0
    fi

    local end_time=$(get_timestamp_ms)
    local span_file="$TRACES_ACTIVE_DIR/${TRACE_ID}-${SPAN_ID}.span"

    if [[ -f "$span_file" ]]; then
        # Calculate duration
        local start_time=$(jq -r '.start_time' "$span_file")
        local duration_ms=$((end_time - start_time))

        # Update span
        jq \
            --arg status "$status" \
            --arg end_time "$end_time" \
            --arg duration_ms "$duration_ms" \
            --arg error_message "$error_message" \
            '.status = $status |
             .end_time = ($end_time | tonumber) |
             .duration_ms = ($duration_ms | tonumber) |
             (if $error_message != "" then .attributes.error_message = $error_message else . end)' \
            "$span_file" > "${span_file}.tmp" && mv "${span_file}.tmp" "$span_file"

        # Update trace error count if error
        if [[ "$status" == "error" ]]; then
            local trace_file="$TRACES_ACTIVE_DIR/${TRACE_ID}.json"
            if [[ -f "$trace_file" ]]; then
                jq '.error_count += 1' "$trace_file" > "${trace_file}.tmp" && mv "${trace_file}.tmp" "$trace_file"
            fi
        fi

        # Add span to trace
        add_span_to_trace "$TRACE_ID" "$span_file"
    fi

    # Pop from stack and restore parent
    local popped_span=$(pop_span)
    export SPAN_ID=$(get_current_span)

    # If no more spans, mark trace as complete
    if [[ -z "$SPAN_ID" ]]; then
        trace_complete
    fi
}

#
# Add completed span to trace
#
add_span_to_trace() {
    local trace_id="$1"
    local span_file="$2"

    local trace_file="$TRACES_ACTIVE_DIR/${trace_id}.json"

    if [[ -f "$trace_file" && -f "$span_file" ]]; then
        local span_data=$(cat "$span_file")
        jq --argjson span "$span_data" '.spans += [$span]' "$trace_file" > "${trace_file}.tmp" && \
            mv "${trace_file}.tmp" "$trace_file"
    fi
}

#
# Mark trace as complete
#
trace_complete() {
    if [[ -z "${TRACE_ID:-}" ]]; then
        return 0
    fi

    local trace_file="$TRACES_ACTIVE_DIR/${TRACE_ID}.json"

    if [[ ! -f "$trace_file" ]]; then
        return 0
    fi

    local end_time=$(get_timestamp_ms)
    local start_time=$(jq -r '.start_time' "$trace_file")
    local duration_ms=$((end_time - start_time))
    local error_count=$(jq -r '.error_count' "$trace_file")

    local final_status="completed"
    if [[ $error_count -gt 0 ]]; then
        final_status="error"
    fi

    # Update trace
    jq \
        --arg status "$final_status" \
        --arg end_time "$end_time" \
        --arg duration_ms "$duration_ms" \
        '.status = $status |
         .end_time = ($end_time | tonumber) |
         .duration_ms = ($duration_ms | tonumber)' \
        "$trace_file" > "${trace_file}.tmp" && mv "${trace_file}.tmp" "$trace_file"

    # Move to completed
    mv "$trace_file" "$TRACES_COMPLETED_DIR/"

    # Clean up span files
    rm -f "$TRACES_ACTIVE_DIR/${TRACE_ID}"-*.span

    # Index by day for easy cleanup
    local day=$(date +%Y-%m-%d)
    echo "$TRACE_ID" >> "$TRACES_INDEX_DIR/by-day-${day}.index"

    # Clear trace context
    export TRACE_ID=""
    export SPAN_ID=""
    export PARENT_SPAN_ID=""
}

#
# Get a trace by ID
#
trace_get() {
    local trace_id="$1"

    # Check active first
    if [[ -f "$TRACES_ACTIVE_DIR/${trace_id}.json" ]]; then
        cat "$TRACES_ACTIVE_DIR/${trace_id}.json"
        return 0
    fi

    # Check completed
    if [[ -f "$TRACES_COMPLETED_DIR/${trace_id}.json" ]]; then
        cat "$TRACES_COMPLETED_DIR/${trace_id}.json"
        return 0
    fi

    echo "{}"
    return 1
}

#
# Search traces by attributes
#
trace_search() {
    local query_type="${1:-all}"
    local query_value="${2:-}"

    case "$query_type" in
        "task")
            if [[ -f "$TRACES_INDEX_DIR/by-task-${query_value}.index" ]]; then
                while read -r trace_id; do
                    trace_get "$trace_id"
                done < "$TRACES_INDEX_DIR/by-task-${query_value}.index"
            fi
            ;;
        "day")
            if [[ -f "$TRACES_INDEX_DIR/by-day-${query_value}.index" ]]; then
                while read -r trace_id; do
                    trace_get "$trace_id"
                done < "$TRACES_INDEX_DIR/by-day-${query_value}.index"
            fi
            ;;
        "status")
            find "$TRACES_ACTIVE_DIR" "$TRACES_COMPLETED_DIR" -name "*.json" -exec \
                jq -c "select(.status == \"$query_value\")" {} \; 2>/dev/null
            ;;
        "all")
            find "$TRACES_COMPLETED_DIR" -name "*.json" -exec cat {} \; 2>/dev/null
            ;;
        *)
            echo "Unknown query type: $query_type" >&2
            return 1
            ;;
    esac
}

#
# Get trace statistics
#
trace_stats() {
    local timeframe="${1:-today}"

    local day=""
    case "$timeframe" in
        "today")
            day=$(date +%Y-%m-%d)
            ;;
        "yesterday")
            day=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
            ;;
        *)
            day="$timeframe"
            ;;
    esac

    if [[ -f "$TRACES_INDEX_DIR/by-day-${day}.index" ]]; then
        local trace_count=$(wc -l < "$TRACES_INDEX_DIR/by-day-${day}.index" | tr -d ' ')
        local error_count=0
        local total_duration=0

        while read -r trace_id; do
            local trace=$(trace_get "$trace_id")
            local status=$(echo "$trace" | jq -r '.status')
            local duration=$(echo "$trace" | jq -r '.duration_ms // 0')

            [[ "$status" == "error" ]] && error_count=$((error_count + 1))
            total_duration=$((total_duration + duration))
        done < "$TRACES_INDEX_DIR/by-day-${day}.index"

        local avg_duration=0
        [[ $trace_count -gt 0 ]] && avg_duration=$((total_duration / trace_count))

        jq -n \
            --arg day "$day" \
            --arg trace_count "$trace_count" \
            --arg error_count "$error_count" \
            --arg avg_duration_ms "$avg_duration" \
            '{
                day: $day,
                trace_count: ($trace_count | tonumber),
                error_count: ($error_count | tonumber),
                success_rate: (if ($trace_count | tonumber) > 0 then (($trace_count | tonumber) - ($error_count | tonumber)) / ($trace_count | tonumber) else 0 end),
                avg_duration_ms: ($avg_duration_ms | tonumber)
            }'
    else
        jq -n --arg day "$day" '{day: $day, trace_count: 0, error_count: 0, success_rate: 0, avg_duration_ms: 0}'
    fi
}

#
# Cleanup old traces
#
trace_cleanup() {
    local retention_days="${1:-7}"

    # Delete completed traces older than retention
    find "$TRACES_COMPLETED_DIR" -name "*.json" -mtime +$retention_days -delete

    # Cleanup old indices
    find "$TRACES_INDEX_DIR" -name "by-day-*.index" -mtime +$retention_days -delete
}

# Cleanup span stack on exit
trap "rm -f $SPAN_STACK_FILE" EXIT

# Export functions
export -f trace_create
export -f trace_start
export -f trace_end
export -f trace_event
export -f trace_get
export -f trace_search
export -f trace_stats
export -f trace_complete
export -f trace_cleanup
