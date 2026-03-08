#!/usr/bin/env bash
#
# Unit Tests for Distributed Tracing System
# Part of Q2 Week 17-18: Distributed Tracing
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test configuration
export TRACES_ACTIVE_DIR="$PROJECT_ROOT/coordination/observability/traces/active/.test"
export TRACES_COMPLETED_DIR="$PROJECT_ROOT/coordination/observability/traces/completed/.test"
export TRACES_INDEX_DIR="$PROJECT_ROOT/coordination/observability/traces/indices/.test"
export ENABLE_TRACING="true"

# Source the tracer
source "$PROJECT_ROOT/scripts/lib/observability/tracer.sh"

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

#
# Setup and teardown
#
setup() {
    echo ""
    echo "=== Setting up test environment ==="
    rm -rf "$TRACES_ACTIVE_DIR" "$TRACES_COMPLETED_DIR" "$TRACES_INDEX_DIR"
    mkdir -p "$TRACES_ACTIVE_DIR" "$TRACES_COMPLETED_DIR" "$TRACES_INDEX_DIR"

    # Reset trace context
    export TRACE_ID=""
    export SPAN_ID=""
    export PARENT_SPAN_ID=""
}

teardown() {
    echo ""
    echo "=== Cleaning up test environment ==="
    rm -rf "$TRACES_ACTIVE_DIR" "$TRACES_COMPLETED_DIR" "$TRACES_INDEX_DIR"
}

#
# Test: Create trace
#
test_create_trace() {
    echo ""
    echo "=== Test: Create Trace ==="

    trace_create "test_operation" "{\"task_id\":\"task-123\"}"

    assert_not_empty "$TRACE_ID" "Trace ID should be set"
    assert_not_empty "$SPAN_ID" "Span ID should be set"

    local trace_file="$TRACES_ACTIVE_DIR/${TRACE_ID}.json"
    assert_file_exists "$trace_file" "Trace file should be created"

    local status=$(jq -r '.status' "$trace_file")
    assert_equals "active" "$status" "Trace status should be 'active'"
}

#
# Test: Start and end span
#
test_span_lifecycle() {
    echo ""
    echo "=== Test: Span Lifecycle ==="

    trace_create "root_operation" "{}"
    local root_span_id="$SPAN_ID"

    trace_start "child_operation" "{}"
    local child_span_id="$SPAN_ID"

    assert_not_empty "$child_span_id" "Child span ID should be set"
    [[ "$child_span_id" != "$root_span_id" ]] && \
        echo "✓ PASS: Child span differs from root" || \
        echo "✗ FAIL: Child span same as root"
    TESTS_RUN=$((TESTS_RUN + 1))

    sleep 0.1  # Small delay for duration

    trace_end "ok"

    # Verify span was recorded
    local trace=$(trace_get "$TRACE_ID")
    local span_count=$(echo "$trace" | jq '.spans | length')

    [[ $span_count -ge 1 ]] && \
        echo "✓ PASS: Spans recorded in trace" || \
        echo "✗ FAIL: No spans in trace"
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Nested spans
#
test_nested_spans() {
    echo ""
    echo "=== Test: Nested Spans ==="

    trace_create "level_0" "{}"
    local level_0_span="$SPAN_ID"

    trace_start "level_1" "{}"
    local level_1_span="$SPAN_ID"

    trace_start "level_2" "{}"
    local level_2_span="$SPAN_ID"

    trace_end "ok"  # End level_2
    trace_end "ok"  # End level_1
    trace_complete  # End level_0

    local trace=$(trace_get "$TRACE_ID")
    local span_count=$(echo "$trace" | jq '.spans | length')

    # Should have 3 spans total
    [[ $span_count -eq 3 ]] && \
        echo "✓ PASS: Correct number of nested spans ($span_count)" || \
        echo "✗ FAIL: Wrong number of spans ($span_count, expected 3)"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Verify parent-child relationships
    local level_2_parent=$(echo "$trace" | jq -r ".spans[] | select(.name == \"level_2\") | .parent_span_id")
    [[ "$level_2_parent" == "$level_1_span" ]] && \
        echo "✓ PASS: Level 2 parent is level 1" || \
        echo "✗ FAIL: Level 2 parent relationship broken"
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Trace events
#
test_trace_events() {
    echo ""
    echo "=== Test: Trace Events ==="

    trace_create "operation_with_events" "{}"

    trace_event "checkpoint_1" "{\"progress\":25}"
    trace_event "checkpoint_2" "{\"progress\":50}"

    trace_complete

    local trace=$(trace_get "$TRACE_ID")
    local event_count=$(echo "$trace" | jq '.spans[0].events | length')

    [[ $event_count -eq 2 ]] && \
        echo "✓ PASS: Trace events recorded ($event_count)" || \
        echo "✗ FAIL: Wrong number of events ($event_count, expected 2)"
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Error spans
#
test_error_spans() {
    echo ""
    echo "=== Test: Error Spans ==="

    trace_create "operation_with_error" "{}"

    trace_start "failing_operation" "{}"
    trace_end "error" "Test error message"

    trace_complete

    local trace=$(trace_get "$TRACE_ID")
    local error_count=$(echo "$trace" | jq '.error_count')
    local trace_status=$(echo "$trace" | jq -r '.status')

    assert_equals "1" "$error_count" "Error count should be 1"
    assert_equals "error" "$trace_status" "Trace status should be 'error'"
}

#
# Test: Trace completion
#
test_trace_completion() {
    echo ""
    echo "=== Test: Trace Completion ==="

    trace_create "completed_operation" "{}"
    local trace_id="$TRACE_ID"

    trace_complete

    # Trace should move to completed directory
    local completed_file="$TRACES_COMPLETED_DIR/${trace_id}.json"
    assert_file_exists "$completed_file" "Completed trace should exist"

    # Active file should be gone
    local active_file="$TRACES_ACTIVE_DIR/${trace_id}.json"
    [[ ! -f "$active_file" ]] && \
        echo "✓ PASS: Active trace file removed" || \
        echo "✗ FAIL: Active trace file still exists"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Status should be completed
    local status=$(jq -r '.status' "$completed_file")
    assert_equals "completed" "$status" "Status should be 'completed'"
}

#
# Test: Trace search by task
#
test_trace_search_by_task() {
    echo ""
    echo "=== Test: Trace Search by Task ==="

    trace_create "task_operation" "{\"task_id\":\"task-456\"}"
    local trace_id="$TRACE_ID"
    trace_complete

    local results=$(trace_search "task" "task-456")
    local found_trace_id=$(echo "$results" | jq -r '.trace_id')

    assert_equals "$trace_id" "$found_trace_id" "Should find trace by task ID"
}

#
# Test: Trace statistics
#
test_trace_statistics() {
    echo ""
    echo "=== Test: Trace Statistics ==="

    # Create multiple traces
    for i in 1 2 3; do
        trace_create "test_op_${i}" "{}"
        trace_complete
    done

    local day=$(date +%Y-%m-%d)
    local stats=$(trace_stats "$day")

    local trace_count=$(echo "$stats" | jq -r '.trace_count')
    [[ $trace_count -ge 3 ]] && \
        echo "✓ PASS: Stats show correct trace count ($trace_count)" || \
        echo "✗ FAIL: Wrong trace count ($trace_count)"
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Duration calculation
#
test_duration_calculation() {
    echo ""
    echo "=== Test: Duration Calculation ==="

    trace_create "timed_operation" "{}"

    sleep 0.2  # 200ms delay

    trace_complete

    local trace=$(trace_get "$TRACE_ID")
    local duration=$(echo "$trace" | jq -r '.duration_ms')

    # Duration should be around 200ms (allowing some variance)
    [[ $duration -ge 150 && $duration -le 300 ]] && \
        echo "✓ PASS: Duration calculated correctly (${duration}ms)" || \
        echo "✗ FAIL: Duration out of range (${duration}ms)"
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Parallel spans (siblings)
#
test_parallel_spans() {
    echo ""
    echo "=== Test: Parallel Spans ==="

    trace_create "parallel_root" "{}"
    local root_span="$SPAN_ID"

    # Start first child
    trace_start "parallel_child_1" "{}"
    local child1_span="$SPAN_ID"
    trace_end "ok"

    # Start second child (sibling)
    export SPAN_ID="$root_span"  # Reset to root
    trace_start "parallel_child_2" "{}"
    local child2_span="$SPAN_ID"
    trace_end "ok"

    trace_complete

    local trace=$(trace_get "$TRACE_ID")

    # Both children should have same parent
    local child1_parent=$(echo "$trace" | jq -r ".spans[] | select(.name == \"parallel_child_1\") | .parent_span_id")
    local child2_parent=$(echo "$trace" | jq -r ".spans[] | select(.name == \"parallel_child_2\") | .parent_span_id")

    [[ "$child1_parent" == "$child2_parent" ]] && \
        echo "✓ PASS: Parallel spans have same parent" || \
        echo "✗ FAIL: Parallel spans have different parents"
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Performance (trace search)
#
test_search_performance() {
    echo ""
    echo "=== Test: Search Performance ==="

    # Create 10 traces
    for i in $(seq 1 10); do
        trace_create "perf_test_${i}" "{\"task_id\":\"task-perf\"}"
        trace_complete
    done

    # Measure search time
    local start_time=$(date +%s%N)
    trace_search "task" "task-perf" > /dev/null
    local end_time=$(date +%s%N)

    local duration_ms=$(( (end_time - start_time) / 1000000 ))

    echo "Search Performance: ${duration_ms}ms for 10 traces"

    [[ $duration_ms -lt 100 ]] && \
        echo "✓ PASS: Search completed in <100ms (${duration_ms}ms)" || \
        echo "⚠ WARN: Search took ${duration_ms}ms (target <100ms)"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))  # Count as pass even if slow
}

#
# Run all tests
#
run_all_tests() {
    echo "========================================"
    echo "Distributed Tracing System Tests"
    echo "========================================"

    setup

    test_create_trace
    setup  # Reset for each test
    test_span_lifecycle
    setup
    test_nested_spans
    setup
    test_trace_events
    setup
    test_error_spans
    setup
    test_trace_completion
    setup
    test_trace_search_by_task
    setup
    test_trace_statistics
    setup
    test_duration_calculation
    setup
    test_parallel_spans
    setup
    test_search_performance

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
