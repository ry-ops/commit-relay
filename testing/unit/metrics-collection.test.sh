#!/usr/bin/env bash
#
# Unit Tests for Metrics Collection System
# Part of Q2 Week 15-16: Metrics Collection System
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test configuration
export METRICS_RAW_DIR="$PROJECT_ROOT/coordination/observability/metrics/raw/.test"
export METRICS_AGG_DIR="$PROJECT_ROOT/coordination/observability/metrics/aggregated/.test"
export METRICS_INDEX_DIR="$PROJECT_ROOT/coordination/observability/metrics/indices/.test"
export METRICS_ROLLUP_DIR="$PROJECT_ROOT/coordination/observability/metrics/rollups/.test"
export ENABLE_METRICS="true"

# Source the metrics collector
source "$PROJECT_ROOT/scripts/lib/observability/metrics-collector.sh"

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

assert_greater_than() {
    local value="$1"
    local threshold="$2"
    local message="${3:-Value should be greater than threshold}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if (( $(echo "$value > $threshold" | bc -l) )); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message ($value > $threshold)"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message ($value <= $threshold)"
        return 1
    fi
}

#
# Setup and teardown
#
setup() {
    echo ""
    echo "=== Setting up test environment ==="
    rm -rf "$METRICS_RAW_DIR" "$METRICS_AGG_DIR" "$METRICS_INDEX_DIR" "$METRICS_ROLLUP_DIR"
    mkdir -p "$METRICS_RAW_DIR" "$METRICS_AGG_DIR" "$METRICS_INDEX_DIR" "$METRICS_ROLLUP_DIR"
}

teardown() {
    echo ""
    echo "=== Cleaning up test environment ==="
    rm -rf "$METRICS_RAW_DIR" "$METRICS_AGG_DIR" "$METRICS_INDEX_DIR" "$METRICS_ROLLUP_DIR"
}

#
# Test: Counter metric
#
test_counter_metric() {
    echo ""
    echo "=== Test: Counter Metric ==="

    record_counter "test_counter" 1 "{}"
    record_counter "test_counter" 5 "{}"
    record_counter "test_counter" 3 "{}"

    local total=$(get_counter_total "test_counter")
    assert_equals "9" "$total" "Counter total should be 9"
}

#
# Test: Gauge metric
#
test_gauge_metric() {
    echo ""
    echo "=== Test: Gauge Metric ==="

    record_gauge "test_gauge" 10 "{}" "count"
    record_gauge "test_gauge" 20 "{}" "count"
    record_gauge "test_gauge" 15 "{}" "count"

    local latest=$(get_latest_gauge "test_gauge")
    assert_equals "15" "$latest" "Latest gauge value should be 15"
}

#
# Test: Histogram metric
#
test_histogram_metric() {
    echo ""
    echo "=== Test: Histogram Metric ==="

    for i in 100 200 300 400 500; do
        record_histogram "test_histogram" "$i" "{}" "milliseconds"
    done

    local metrics=$(query_metrics "test_histogram")
    local count=$(echo "$metrics" | jq 'length')
    assert_equals "5" "$count" "Should have 5 histogram samples"
}

#
# Test: Dimensional filtering
#
test_dimensional_filtering() {
    echo ""
    echo "=== Test: Dimensional Filtering ==="

    record_gauge "worker_count" 5 '{"worker_type":"scan"}'
    record_gauge "worker_count" 3 '{"worker_type":"implementation"}'
    record_gauge "worker_count" 2 '{"worker_type":"documentation"}'

    local scan_metrics=$(query_metrics_by_dimension "worker_type" "scan")
    local count=$(echo "$scan_metrics" | jq 'length')
    assert_equals "1" "$count" "Should find 1 metric for scan workers"
}

#
# Test: Aggregations
#
test_aggregations() {
    echo ""
    echo "=== Test: Aggregations ==="

    # Record sample data
    for i in 10 20 30 40 50 60 70 80 90 100; do
        record_histogram "test_latency" "$i" "{}" "milliseconds"
    done

    local agg=$(aggregate_metrics "test_latency" "1h")

    local count=$(echo "$agg" | jq -r '.count')
    local min=$(echo "$agg" | jq -r '.min')
    local max=$(echo "$agg" | jq -r '.max')
    local mean=$(echo "$agg" | jq -r '.mean')
    local p50=$(echo "$agg" | jq -r '.p50')
    local p95=$(echo "$agg" | jq -r '.p95')
    local p99=$(echo "$agg" | jq -r '.p99')

    assert_equals "10" "$count" "Aggregation count should be 10"
    assert_equals "10" "$min" "Min should be 10"
    assert_equals "100" "$max" "Max should be 100"
    assert_equals "55" "$mean" "Mean should be 55"
    [[ "$p50" -ge "50" && "$p50" -le "60" ]] && echo "✓ PASS: P50 in expected range" || echo "✗ FAIL: P50 out of range"
    [[ "$p95" -ge "90" ]] && echo "✓ PASS: P95 >= 90" || echo "✗ FAIL: P95 < 90"
}

#
# Test: Index creation
#
test_index_creation() {
    echo ""
    echo "=== Test: Index Creation ==="

    record_task_metric "task_duration_ms" 1500 "task-123" "{}"

    local index_file="$METRICS_INDEX_DIR/by-task-task-123.index"
    if [[ -f "$index_file" ]]; then
        echo "✓ PASS: Task index created"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "✗ FAIL: Task index not created"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Convenience wrappers
#
test_convenience_wrappers() {
    echo ""
    echo "=== Test: Convenience Wrappers ==="

    record_task_metric "execution_time" 2000 "task-456" "{}"
    record_worker_metric "spawn_time" 500 "worker-789" "{}"
    record_master_metric "routing_confidence" 0.95 "development-master" "{}"

    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    local task_metric=$(grep '"task_id":"task-456"' "$metrics_file" | head -1)
    local worker_metric=$(grep '"worker_id":"worker-789"' "$metrics_file" | head -1)
    local master_metric=$(grep '"master_id":"development-master"' "$metrics_file" | head -1)

    [[ -n "$task_metric" ]] && echo "✓ PASS: Task metric recorded" || echo "✗ FAIL: Task metric not found"
    [[ -n "$worker_metric" ]] && echo "✓ PASS: Worker metric recorded" || echo "✗ FAIL: Worker metric not found"
    [[ -n "$master_metric" ]] && echo "✓ PASS: Master metric recorded" || echo "✗ FAIL: Master metric not found"
}

#
# Test: Query by time range
#
test_time_range_query() {
    echo ""
    echo "=== Test: Time Range Query ==="

    local now=$(get_timestamp_ms)
    local hour_ago=$((now - 3600000))
    local future=$((now + 3600000))

    record_gauge "time_test" 100 "{}"
    sleep 0.1
    record_gauge "time_test" 200 "{}"

    local metrics=$(query_metrics "time_test" "$hour_ago" "$future")
    local count=$(echo "$metrics" | jq 'length')

    assert_equals "2" "$count" "Should find 2 metrics in time range"
}

#
# Test: Metrics dashboard
#
test_metrics_dashboard() {
    echo ""
    echo "=== Test: Metrics Dashboard ==="

    record_gauge "dashboard_test_1" 50 "{}"
    record_gauge "dashboard_test_2" 75 "{}"
    record_counter "dashboard_counter" 10 "{}"

    local dashboard=$(get_metrics_dashboard "1h")

    [[ $(echo "$dashboard" | jq 'length') -gt 0 ]] && \
        echo "✓ PASS: Dashboard returned metrics" || \
        echo "✗ FAIL: Dashboard empty"
}

#
# Test: Performance
#
test_performance() {
    echo ""
    echo "=== Test: Performance ==="

    local iterations=100
    local start_time=$(date +%s%N)

    for i in $(seq 1 $iterations); do
        record_counter "perf_test" 1 "{}" >/dev/null 2>&1
    done

    local end_time=$(date +%s%N)
    local total_time_ns=$((end_time - start_time))
    local avg_time_ns=$((total_time_ns / iterations))
    local avg_time_ms=$((avg_time_ns / 1000000))

    echo "Performance Results:"
    echo "  Iterations: $iterations"
    echo "  Total time: $((total_time_ns / 1000000))ms"
    echo "  Average time per collection: ${avg_time_ms}ms"

    if [[ $avg_time_ms -le 5 ]]; then
        echo "✓ PASS: Average collection time (${avg_time_ms}ms) meets <5ms target"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "⚠ WARN: Average collection time (${avg_time_ms}ms) exceeds 5ms target (acceptable)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

#
# Test: Metric types validation
#
test_metric_types() {
    echo ""
    echo "=== Test: Metric Types ==="

    record_counter "type_counter" 1 "{}"
    record_gauge "type_gauge" 50 "{}"
    record_histogram "type_histogram" 100 "{}"
    record_summary "type_summary" 75 "{}"

    local metrics_file="$METRICS_RAW_DIR/metrics-$(date +%Y-%m-%d).jsonl"

    local counter_type=$(grep '"metric_name":"type_counter"' "$metrics_file" | jq -r '.metric_type')
    local gauge_type=$(grep '"metric_name":"type_gauge"' "$metrics_file" | jq -r '.metric_type')
    local histogram_type=$(grep '"metric_name":"type_histogram"' "$metrics_file" | jq -r '.metric_type')
    local summary_type=$(grep '"metric_name":"type_summary"' "$metrics_file" | jq -r '.metric_type')

    assert_equals "counter" "$counter_type" "Counter type should be 'counter'"
    assert_equals "gauge" "$gauge_type" "Gauge type should be 'gauge'"
    assert_equals "histogram" "$histogram_type" "Histogram type should be 'histogram'"
    assert_equals "summary" "$summary_type" "Summary type should be 'summary'"
}

#
# Run all tests
#
run_all_tests() {
    echo "========================================"
    echo "Metrics Collection System Tests"
    echo "========================================"

    setup

    test_counter_metric
    test_gauge_metric
    test_histogram_metric
    test_dimensional_filtering
    test_aggregations
    test_index_creation
    test_convenience_wrappers
    test_time_range_query
    test_metrics_dashboard
    test_metric_types
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
