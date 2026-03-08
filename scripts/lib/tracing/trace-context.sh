#!/bin/bash
# Trace Context Propagation for Bash Scripts
# Simplified OpenTelemetry context in shell

# Generate trace ID (128-bit hex)
generate_trace_id() {
    printf '%032x' $((RANDOM << 48 | RANDOM << 32 | RANDOM << 16 | RANDOM))
}

# Generate span ID (64-bit hex)
generate_span_id() {
    printf '%016x' $((RANDOM << 16 | RANDOM))
}

# Start trace
start_trace() {
    local operation_name="$1"

    export TRACE_ID="${TRACE_ID:-$(generate_trace_id)}"
    export PARENT_SPAN_ID="${SPAN_ID:-}"
    export SPAN_ID="$(generate_span_id)"
    export SPAN_NAME="$operation_name"
    export SPAN_START=$(date +%s%N)

    echo "$SPAN_ID"
}

# End trace
end_trace() {
    local span_id="$1"
    local status="${2:-ok}"

    if [ -z "$SPAN_START" ]; then
        return
    fi

    local span_end=$(date +%s%N)
    local duration=$(( (span_end - SPAN_START) / 1000000 )) # Convert to ms

    # Write span to traces file
    local traces_dir="coordination/traces"
    mkdir -p "$traces_dir"

    local date=$(date +%Y-%m-%d)
    local trace_file="$traces_dir/traces-$date.jsonl"

    cat >> "$trace_file" <<EOF
{"traceId":"$TRACE_ID","spanId":"$span_id","parentSpanId":"${PARENT_SPAN_ID:-}","name":"$SPAN_NAME","startTime":$SPAN_START,"duration":$duration,"status":"$status","timestamp":"$(date -Iseconds)"}
EOF

    # Clear span context (restore parent if exists)
    export SPAN_ID="$PARENT_SPAN_ID"
}

# Add trace event
trace_event() {
    local event_name="$1"
    local event_attrs="${2:-{}}"

    if [ -n "$SPAN_ID" ]; then
        local traces_dir="coordination/traces"
        local date=$(date +%Y-%m-%d)
        local events_file="$traces_dir/events-$date.jsonl"

        cat >> "$events_file" <<EOF
{"traceId":"$TRACE_ID","spanId":"$SPAN_ID","event":"$event_name","attributes":$event_attrs,"timestamp":"$(date -Iseconds)"}
EOF
    fi
}

# Export for use in other scripts
export -f generate_trace_id
export -f generate_span_id
export -f start_trace
export -f end_trace
export -f trace_event
