#!/usr/bin/env bash
#
# Unit Tests for Event Streaming Infrastructure
# Part of Q2 Week 13-14: Event Streaming Infrastructure
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test configuration
export EVENT_STREAM_DIR="$PROJECT_ROOT/coordination/observability/events/.test"
export EVENT_BUFFER_DIR="$PROJECT_ROOT/coordination/observability/events/.test/.buffer"
export ENABLE_VALIDATION="true"
export ENABLE_BUFFERING="false"  # Disable for tests

# Source the event emitter
source "$PROJECT_ROOT/coordination/observability/lib/event-emitter.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#
# Test framework functions
#
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -n "$value" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist: $file}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -f "$file" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message"
        return 1
    fi
}

assert_json_valid() {
    local json="$1"
    local message="${2:-JSON should be valid}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$json" | jq empty 2>/dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message"
        echo "  Invalid JSON: $json"
        return 1
    fi
}

assert_json_has_field() {
    local json="$1"
    local field="$2"
    local message="${3:-JSON should have field: $field}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$json" | jq -e ".$field" >/dev/null 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message"
        return 1
    fi
}

#
# Setup and teardown
#
setup() {
    echo ""
    echo "=== Setting up test environment ==="
    rm -rf "$EVENT_STREAM_DIR"
    mkdir -p "$EVENT_STREAM_DIR" "$EVENT_BUFFER_DIR"

    # Reset trace context
    export TRACE_ID=""
    export SPAN_ID=""
    export PARENT_SPAN_ID=""
}

teardown() {
    echo ""
    echo "=== Cleaning up test environment ==="
    rm -rf "$EVENT_STREAM_DIR"
}

#
# Test: Event ID generation
#
test_event_id_generation() {
    echo ""
    echo "=== Test: Event ID Generation ==="

    local event_id=$(generate_event_id)

    assert_not_empty "$event_id" "Event ID should not be empty"
    [[ "$event_id" =~ ^evt-[0-9]+-[a-f0-9]+$ ]] && \
        echo "✓ PASS: Event ID matches pattern" || \
        echo "✗ FAIL: Event ID does not match pattern"
}

#
# Test: Trace ID generation
#
test_trace_id_generation() {
    echo ""
    echo "=== Test: Trace ID Generation ==="

    local trace_id=$(generate_trace_id)

    assert_not_empty "$trace_id" "Trace ID should not be empty"
    [[ "$trace_id" =~ ^trace-[0-9]+-[a-f0-9]+$ ]] && \
        echo "✓ PASS: Trace ID matches pattern" || \
        echo "✗ FAIL: Trace ID does not match pattern"
}

#
# Test: Span ID generation
#
test_span_id_generation() {
    echo ""
    echo "=== Test: Span ID Generation ==="

    local span_id=$(generate_span_id)

    assert_not_empty "$span_id" "Span ID should not be empty"
    [[ "$span_id" =~ ^span-[a-f0-9]+$ ]] && \
        echo "✓ PASS: Span ID matches pattern" || \
        echo "✗ FAIL: Span ID does not match pattern"
}

#
# Test: Basic event emission
#
test_basic_event_emission() {
    echo ""
    echo "=== Test: Basic Event Emission ==="

    emit_event "task_created" "task" '{"task_id":"test-123","priority":"high"}' "info"

    local stream_file="$EVENT_STREAM_DIR/events-$(date +%Y-%m-%d).jsonl"
    assert_file_exists "$stream_file" "Event stream file should be created"

    local event=$(tail -1 "$stream_file")
    assert_json_valid "$event" "Emitted event should be valid JSON"
    assert_json_has_field "$event" "event_id" "Event should have event_id"
    assert_json_has_field "$event" "timestamp" "Event should have timestamp"
    assert_json_has_field "$event" "event_type" "Event should have event_type"
    assert_json_has_field "$event" "category" "Event should have category"
    assert_json_has_field "$event" "trace_id" "Event should have trace_id"
}

#
# Test: Event validation
#
test_event_validation() {
    echo ""
    echo "=== Test: Event Validation ==="

    # Valid event
    local valid_event='{"event_id":"evt-123","timestamp":"2025-11-19T00:00:00Z","event_type":"task_created","category":"task","source":"test"}'
    validate_event "$valid_event" && \
        echo "✓ PASS: Valid event passes validation" || \
        echo "✗ FAIL: Valid event failed validation"

    # Invalid event (missing required field)
    local invalid_event='{"event_id":"evt-123","timestamp":"2025-11-19T00:00:00Z"}'
    ! validate_event "$invalid_event" 2>/dev/null && \
        echo "✓ PASS: Invalid event fails validation" || \
        echo "✗ FAIL: Invalid event passed validation"
}

#
# Test: Trace context
#
test_trace_context() {
    echo ""
    echo "=== Test: Trace Context ==="

    # Clear trace context
    export TRACE_ID=""
    export SPAN_ID=""

    emit_event "task_created" "task" '{"task_id":"test-456"}' "info"

    local stream_file="$EVENT_STREAM_DIR/events-$(date +%Y-%m-%d).jsonl"
    local event=$(tail -1 "$stream_file")

    local trace_id=$(echo "$event" | jq -r '.trace_id')
    assert_not_empty "$trace_id" "Trace ID should be auto-generated"

    # Emit another event in same trace
    emit_event "task_started" "task" '{"task_id":"test-456"}' "info"

    local event2=$(tail -1 "$stream_file")
    local trace_id2=$(echo "$event2" | jq -r '.trace_id')

    assert_equals "$trace_id" "$trace_id2" "Events in same context should share trace ID"
}

#
# Test: Span hierarchy
#
test_span_hierarchy() {
    echo ""
    echo "=== Test: Span Hierarchy ==="

    # Clear context
    export TRACE_ID=""
    export SPAN_ID=""
    export PARENT_SPAN_ID=""

    emit_event "task_created" "task" '{"task_id":"test-789"}' "info"

    local stream_file="$EVENT_STREAM_DIR/events-$(date +%Y-%m-%d).jsonl"
    local parent_event=$(tail -1 "$stream_file")
    local parent_span=$(echo "$parent_event" | jq -r '.span_id')

    # Start child span
    start_span "child_operation"

    emit_event "worker_spawned" "worker" '{"worker_id":"worker-001"}' "info"

    local child_event=$(tail -1 "$stream_file")
    local child_span=$(echo "$child_event" | jq -r '.span_id')
    local child_parent=$(echo "$child_event" | jq -r '.parent_span_id')

    assert_not_empty "$child_parent" "Child span should have parent_span_id"
    [[ "$child_span" != "$parent_span" ]] && \
        echo "✓ PASS: Child span differs from parent" || \
        echo "✗ FAIL: Child span same as parent"
}

#
# Test: Event enrichment
#
test_event_enrichment() {
    echo ""
    echo "=== Test: Event Enrichment ==="

    emit_event "system_start" "system" '{"version":"1.0.0"}' "info"

    local stream_file="$EVENT_STREAM_DIR/events-$(date +%Y-%m-%d).jsonl"
    local event=$(tail -1 "$stream_file")

    assert_json_has_field "$event" "context.hostname" "Event should have hostname"
    assert_json_has_field "$event" "context.pid" "Event should have PID"
}

#
# Test: Convenience wrappers
#
test_convenience_wrappers() {
    echo ""
    echo "=== Test: Convenience Wrappers ==="

    # Task event
    emit_task_event "task_completed" "task-999" '{"duration_ms":1500}' "info"

    local stream_file="$EVENT_STREAM_DIR/events-$(date +%Y-%m-%d).jsonl"
    local task_event=$(tail -1 "$stream_file")

    local task_id=$(echo "$task_event" | jq -r '.data.task_id')
    assert_equals "task-999" "$task_id" "Task event should include task_id"

    # Worker event
    emit_worker_event "worker_started" "worker-888" '{"worker_type":"implementation"}' "info"

    local worker_event=$(tail -1 "$stream_file")
    local worker_id=$(echo "$worker_event" | jq -r '.data.worker_id')
    assert_equals "worker-888" "$worker_id" "Worker event should include worker_id"

    # Error event
    emit_error_event "Test error message" "TEST_ERROR" '{"context":"unit test"}'

    local error_event=$(tail -1 "$stream_file")
    local error_msg=$(echo "$error_event" | jq -r '.data.error_message')
    assert_equals "Test error message" "$error_msg" "Error event should include error message"
}

#
# Test: Event querying
#
test_event_querying() {
    echo ""
    echo "=== Test: Event Querying ==="

    # Emit multiple events
    emit_event "task_created" "task" '{"task_id":"query-1"}' "info"
    emit_event "worker_spawned" "worker" '{"worker_id":"worker-1"}' "info"
    emit_event "error_occurred" "error" '{"error":"test"}' "error"

    # Query by category
    local task_events=$(query_events "task")
    local task_count=$(echo "$task_events" | jq 'length')
    [[ $task_count -gt 0 ]] && \
        echo "✓ PASS: Can query events by category" || \
        echo "✗ FAIL: Cannot query events by category"

    # Query by type
    local worker_events=$(query_events "" "worker_spawned")
    local worker_count=$(echo "$worker_events" | jq 'length')
    [[ $worker_count -gt 0 ]] && \
        echo "✓ PASS: Can query events by type" || \
        echo "✗ FAIL: Cannot query events by type"
}

#
# Test: Event statistics
#
test_event_statistics() {
    echo ""
    echo "=== Test: Event Statistics ==="

    # Emit various events
    emit_event "task_created" "task" '{}' "info"
    emit_event "task_started" "task" '{}' "info"
    emit_event "worker_spawned" "worker" '{}' "info"
    emit_event "error_occurred" "error" '{}' "error"

    local stats=$(get_event_stats)

    assert_json_valid "$stats" "Stats should be valid JSON"
    assert_json_has_field "$stats" "total" "Stats should have total count"
    assert_json_has_field "$stats" "by_category" "Stats should have category breakdown"
    assert_json_has_field "$stats" "by_severity" "Stats should have severity breakdown"
}

#
# Test: Performance (event emission overhead)
#
test_performance() {
    echo ""
    echo "=== Test: Performance ==="

    local iterations=100
    local start_time=$(date +%s%N)

    for i in $(seq 1 $iterations); do
        emit_event "performance_test" "system" "{\"iteration\":$i}" "debug" >/dev/null 2>&1
    done

    local end_time=$(date +%s%N)
    local total_time_ns=$((end_time - start_time))
    local avg_time_ns=$((total_time_ns / iterations))
    local avg_time_ms=$((avg_time_ns / 1000000))

    echo "Performance Results:"
    echo "  Iterations: $iterations"
    echo "  Total time: $((total_time_ns / 1000000))ms"
    echo "  Average time per emission: ${avg_time_ms}ms"

    if [[ $avg_time_ms -le 10 ]]; then
        echo "✓ PASS: Average emission time (${avg_time_ms}ms) meets <10ms target"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "✗ FAIL: Average emission time (${avg_time_ms}ms) exceeds 10ms target"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Run all tests
#
run_all_tests() {
    echo "========================================"
    echo "Event Streaming Infrastructure Tests"
    echo "========================================"

    setup

    test_event_id_generation
    test_trace_id_generation
    test_span_id_generation
    test_basic_event_emission
    test_event_validation
    test_trace_context
    test_span_hierarchy
    test_event_enrichment
    test_convenience_wrappers
    test_event_querying
    test_event_statistics
    test_performance

    teardown

    echo ""
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Tests Run:    $TESTS_RUN"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✓ ALL TESTS PASSED"
        return 0
    else
        echo "✗ SOME TESTS FAILED"
        return 1
    fi
}

# Run tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
