#!/usr/bin/env bash
#
# Distributed Tracing Library - Simplified Interface
# Part of Q2 Observability Infrastructure
#
# Provides a simplified interface with start_span/end_span functions
# that wrap the underlying tracer.sh functionality.
#
# Usage:
#   source scripts/lib/observability/trace.sh
#   start_span "my_operation" '{"task_id":"task-123"}'
#   # ... do work ...
#   end_span "ok"
#
# For nested spans:
#   start_span "parent_operation"
#   start_span "child_operation"
#   end_span "ok"  # ends child
#   end_span "ok"  # ends parent

set -euo pipefail

# Configuration
readonly TRACE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the underlying tracer
source "$TRACE_SCRIPT_DIR/tracer.sh"

# Ensure trace directories exist
readonly TRACE_DATA_DIR="${TRACE_DATA_DIR:-coordination/observability/traces}"
readonly TRACE_EVENTS_DIR="${TRACE_EVENTS_DIR:-coordination/observability/events}"
readonly TRACE_METRICS_DIR="${TRACE_METRICS_DIR:-coordination/observability/metrics}"

mkdir -p "$TRACE_DATA_DIR" "$TRACE_EVENTS_DIR" "$TRACE_METRICS_DIR"

# Standard span types for domain-specific tracing
readonly SPAN_TYPE_WORKER_EXECUTION="worker_execution"
readonly SPAN_TYPE_TASK_PROCESSING="task_processing"
readonly SPAN_TYPE_MASTER_HANDOFF="master_handoff"
readonly SPAN_TYPE_RAG_RETRIEVAL="rag_retrieval"
readonly SPAN_TYPE_MOE_ROUTING="moe_routing"
readonly SPAN_TYPE_VALIDATION="validation"
readonly SPAN_TYPE_GOVERNANCE_CHECK="governance_check"
readonly SPAN_TYPE_HANDOFF="handoff"
readonly SPAN_TYPE_LEARNING_CYCLE="learning_cycle"
readonly SPAN_TYPE_EMBEDDING_GENERATION="embedding_generation"
readonly SPAN_TYPE_VECTOR_SEARCH="vector_search"
readonly SPAN_TYPE_DAEMON_OPERATION="daemon_operation"
readonly SPAN_TYPE_API_REQUEST="api_request"
readonly SPAN_TYPE_GIT_OPERATION="git_operation"
readonly SPAN_TYPE_REASONING="reasoning"

#
# start_span - Begin a new span
#
# Args:
#   $1 - span_name: Name of the operation being traced
#   $2 - attributes: JSON object of attributes (optional)
#   $3 - kind: Span kind - internal, client, server, producer, consumer (optional)
#
# Example:
#   start_span "process_task" '{"task_id":"task-123","priority":"high"}'
#
start_span() {
    local span_name="${1:-unnamed_span}"
    local attributes="${2:-{}}"
    local kind="${3:-internal}"

    # Validate JSON
    if ! echo "$attributes" | jq empty 2>/dev/null; then
        attributes="{}"
    fi

    # Add standard attributes
    local enhanced_attrs=$(echo "$attributes" | jq \
        --arg hostname "$(hostname)" \
        --arg pid "$$" \
        '. + {
            "host.name": $hostname,
            "process.pid": $pid
        }')

    # Call underlying tracer
    trace_start "$span_name" "$enhanced_attrs" "$kind"

    # Return the span ID for reference
    echo "${SPAN_ID:-}"
}

#
# end_span - End the current span
#
# Args:
#   $1 - status: ok, error, or unset (optional, defaults to ok)
#   $2 - error_message: Error message if status is error (optional)
#
# Example:
#   end_span "ok"
#   end_span "error" "Connection timeout"
#
end_span() {
    local status="${1:-ok}"
    local error_message="${2:-}"

    trace_end "$status" "$error_message"
}

#
# add_span_event - Add an event to the current span
#
# Args:
#   $1 - event_name: Name of the event
#   $2 - attributes: JSON object of event attributes (optional)
#
# Example:
#   add_span_event "retry_attempt" '{"attempt":2,"reason":"timeout"}'
#
add_span_event() {
    local event_name="$1"
    local attributes="${2:-{}}"

    trace_event "$event_name" "$attributes"
}

#
# set_span_attribute - Add an attribute to the current span
#
# Args:
#   $1 - key: Attribute key
#   $2 - value: Attribute value
#
set_span_attribute() {
    local key="$1"
    local value="$2"

    # Add as an event since we can't modify span attributes after creation
    trace_event "attribute_set" "{\"$key\": \"$value\"}"
}

#
# set_span_status - Set the status of the current span
#
# Args:
#   $1 - status: ok, error
#   $2 - description: Status description (optional)
#
set_span_status() {
    local status="$1"
    local description="${2:-}"

    trace_event "status_set" "{\"status\": \"$status\", \"description\": \"$description\"}"
}

#
# get_current_trace_id - Get the current trace ID
#
get_current_trace_id() {
    echo "${TRACE_ID:-}"
}

#
# get_current_span_id - Get the current span ID
#
get_current_span_id() {
    echo "${SPAN_ID:-}"
}

#
# with_span - Execute a command within a span
#
# Args:
#   $1 - span_name: Name of the span
#   $@ - command: Command to execute
#
# Example:
#   with_span "build_project" make build
#
with_span() {
    local span_name="$1"
    shift

    start_span "$span_name"

    local exit_code=0
    "$@" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        end_span "ok"
    else
        end_span "error" "Command exited with code $exit_code"
    fi

    return $exit_code
}

#
# create_trace_context - Create a trace context for propagation
#
# Returns:
#   JSON object with trace_id, span_id, and parent_span_id
#
create_trace_context() {
    jq -n \
        --arg trace_id "${TRACE_ID:-}" \
        --arg span_id "${SPAN_ID:-}" \
        --arg parent_span_id "${PARENT_SPAN_ID:-}" \
        '{
            trace_id: $trace_id,
            span_id: $span_id,
            parent_span_id: $parent_span_id
        }'
}

#
# inject_trace_context - Inject trace context into worker spec
#
# Args:
#   $1 - worker_spec_json: JSON worker spec to inject into
#
# Returns:
#   Worker spec with trace context added
#
inject_trace_context() {
    local worker_spec="$1"

    local trace_context=$(create_trace_context)

    echo "$worker_spec" | jq --argjson ctx "$trace_context" \
        '.trace_context = $ctx'
}

#
# extract_trace_context - Extract and set trace context from worker spec
#
# Args:
#   $1 - worker_spec_json: JSON worker spec to extract from
#
extract_trace_context() {
    local worker_spec="$1"

    export TRACE_ID=$(echo "$worker_spec" | jq -r '.trace_context.trace_id // empty')
    export PARENT_SPAN_ID=$(echo "$worker_spec" | jq -r '.trace_context.span_id // empty')
}

#
# emit_trace_metric - Emit a metric tied to the current trace
#
# Args:
#   $1 - metric_name: Name of the metric
#   $2 - value: Metric value
#   $3 - dimensions: Additional dimensions (optional)
#
emit_trace_metric() {
    local metric_name="$1"
    local value="$2"
    local dimensions="${3:-{}}"

    # Add trace context to dimensions
    local enhanced_dims=$(echo "$dimensions" | jq \
        --arg trace_id "${TRACE_ID:-}" \
        --arg span_id "${SPAN_ID:-}" \
        '. + {
            trace_id: $trace_id,
            span_id: $span_id
        }')

    # Source metrics collector if available
    if [[ -f "$TRACE_SCRIPT_DIR/metrics-collector.sh" ]]; then
        source "$TRACE_SCRIPT_DIR/metrics-collector.sh"
        record_histogram "$metric_name" "$value" "$enhanced_dims"
    fi
}

#
# trace_worker_execution - High-level function to trace worker execution
#
# Args:
#   $1 - worker_id: Worker ID
#   $2 - task_id: Task ID
#   $3 - worker_type: Type of worker
#
# Returns:
#   Trace ID
#
trace_worker_execution() {
    local worker_id="$1"
    local task_id="$2"
    local worker_type="${3:-unknown}"

    local attributes=$(jq -n \
        --arg worker_id "$worker_id" \
        --arg task_id "$task_id" \
        --arg worker_type "$worker_type" \
        '{
            worker_id: $worker_id,
            task_id: $task_id,
            worker_type: $worker_type
        }')

    trace_create "worker_execution" "$attributes"
    echo "$TRACE_ID"
}

#
# trace_task_processing - High-level function to trace task processing
#
# Args:
#   $1 - task_id: Task ID
#   $2 - task_type: Type of task
#   $3 - priority: Task priority
#
# Returns:
#   Trace ID
#
trace_task_processing() {
    local task_id="$1"
    local task_type="${2:-unknown}"
    local priority="${3:-medium}"

    local attributes=$(jq -n \
        --arg task_id "$task_id" \
        --arg task_type "$task_type" \
        --arg priority "$priority" \
        '{
            task_id: $task_id,
            task_type: $task_type,
            priority: $priority
        }')

    trace_create "task_processing" "$attributes"
    echo "$TRACE_ID"
}

#
# trace_master_handoff - Trace a handoff between masters
#
# Args:
#   $1 - from_master: Source master
#   $2 - to_master: Destination master
#   $3 - task_id: Task being handed off
#
trace_master_handoff() {
    local from_master="$1"
    local to_master="$2"
    local task_id="$3"

    start_span "master_handoff" "{
        \"from_master\": \"$from_master\",
        \"to_master\": \"$to_master\",
        \"task_id\": \"$task_id\"
    }" "producer"
}

#
# Chain-of-Thought Reasoning Traces
#

# Directory for reasoning traces
readonly REASONING_TRACES_DIR="${REASONING_TRACES_DIR:-coordination/observability/reasoning-traces}"
mkdir -p "$REASONING_TRACES_DIR" 2>/dev/null || true

#
# start_reasoning_trace - Begin a chain-of-thought reasoning trace
#
# Args:
#   $1 - task_id: Task being reasoned about
#   $2 - context: Initial context for reasoning
#
# Returns:
#   Reasoning trace ID
#
start_reasoning_trace() {
    local task_id="$1"
    local context="${2:-}"

    local reasoning_id="reason-$(date +%s)-$$-$RANDOM"
    local timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    # Create reasoning trace file
    local trace_file="$REASONING_TRACES_DIR/${reasoning_id}.jsonl"

    # Record initial context
    jq -nc \
        --arg id "$reasoning_id" \
        --arg task_id "$task_id" \
        --arg timestamp "$timestamp" \
        --arg trace_id "${TRACE_ID:-}" \
        --arg context "$context" \
        '{
            reasoning_id: $id,
            task_id: $task_id,
            trace_id: $trace_id,
            started_at: $timestamp,
            type: "start",
            context: $context,
            steps: []
        }' > "$trace_file"

    # Export for use in subsequent calls
    export REASONING_ID="$reasoning_id"
    export REASONING_FILE="$trace_file"

    echo "$reasoning_id"
}

#
# add_reasoning_step - Add a reasoning step to the current trace
#
# Args:
#   $1 - step_type: Type of reasoning (observation, hypothesis, analysis, conclusion, decision)
#   $2 - content: The reasoning content
#   $3 - confidence: Confidence level (0-100, optional)
#
add_reasoning_step() {
    local step_type="$1"
    local content="$2"
    local confidence="${3:-}"

    if [[ -z "${REASONING_FILE:-}" ]] || [[ ! -f "$REASONING_FILE" ]]; then
        return 1
    fi

    local timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
    local step_id="step-$RANDOM"

    # Create step JSON
    local step_json
    if [[ -n "$confidence" ]]; then
        step_json=$(jq -nc \
            --arg id "$step_id" \
            --arg type "$step_type" \
            --arg content "$content" \
            --arg timestamp "$timestamp" \
            --argjson confidence "$confidence" \
            '{
                step_id: $id,
                type: $type,
                content: $content,
                confidence: $confidence,
                timestamp: $timestamp
            }')
    else
        step_json=$(jq -nc \
            --arg id "$step_id" \
            --arg type "$step_type" \
            --arg content "$content" \
            --arg timestamp "$timestamp" \
            '{
                step_id: $id,
                type: $type,
                content: $content,
                timestamp: $timestamp
            }')
    fi

    # Append to trace file
    echo "$step_json" >> "$REASONING_FILE"

    # Also add as span event if in a trace
    if [[ -n "${SPAN_ID:-}" ]]; then
        add_span_event "reasoning_step" "$step_json"
    fi
}

#
# end_reasoning_trace - End the current reasoning trace
#
# Args:
#   $1 - outcome: Final outcome (success, partial, failed)
#   $2 - conclusion: Final conclusion
#
end_reasoning_trace() {
    local outcome="${1:-success}"
    local conclusion="${2:-}"

    if [[ -z "${REASONING_FILE:-}" ]] || [[ ! -f "$REASONING_FILE" ]]; then
        return 1
    fi

    local timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    # Add end marker
    jq -nc \
        --arg timestamp "$timestamp" \
        --arg outcome "$outcome" \
        --arg conclusion "$conclusion" \
        '{
            type: "end",
            ended_at: $timestamp,
            outcome: $outcome,
            conclusion: $conclusion
        }' >> "$REASONING_FILE"

    # Clear exports
    unset REASONING_ID
    unset REASONING_FILE
}

#
# get_reasoning_trace - Get the full reasoning trace as JSON
#
# Args:
#   $1 - reasoning_id: ID of the reasoning trace
#
# Returns:
#   JSON array of reasoning steps
#
get_reasoning_trace() {
    local reasoning_id="$1"
    local trace_file="$REASONING_TRACES_DIR/${reasoning_id}.jsonl"

    if [[ ! -f "$trace_file" ]]; then
        echo "[]"
        return 1
    fi

    jq -s '.' "$trace_file"
}

# Export functions
export -f start_span
export -f end_span
export -f add_span_event
export -f set_span_attribute
export -f set_span_status
export -f get_current_trace_id
export -f get_current_span_id
export -f with_span
export -f create_trace_context
export -f inject_trace_context
export -f extract_trace_context
export -f emit_trace_metric
export -f trace_worker_execution
export -f trace_task_processing
export -f trace_master_handoff
export -f start_reasoning_trace
export -f add_reasoning_step
export -f end_reasoning_trace
export -f get_reasoning_trace
