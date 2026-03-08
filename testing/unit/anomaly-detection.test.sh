#!/usr/bin/env bash
#
# Unit Tests for Anomaly Detection System
# Part of Q2 Week 19: Anomaly Detection
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test configuration
export ANOMALIES_ACTIVE_DIR="$PROJECT_ROOT/coordination/observability/anomalies/active/.test"
export ANOMALIES_RESOLVED_DIR="$PROJECT_ROOT/coordination/observability/anomalies/resolved/.test"
export ANOMALIES_BASELINES_DIR="$PROJECT_ROOT/coordination/observability/anomalies/baselines/.test"
export ANOMALIES_INDEX_DIR="$PROJECT_ROOT/coordination/observability/anomalies/indices/.test"
export ENABLE_ANOMALY_DETECTION="true"

# Source the detector
source "$PROJECT_ROOT/scripts/lib/observability/anomaly-detector.sh"

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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Should contain value}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$haystack" | grep -q "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✓ PASS: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "✗ FAIL: $message"
        echo "  Expected to find: $needle"
        echo "  In: $haystack"
        return 1
    fi
}

#
# Setup and teardown
#
setup() {
    echo ""
    echo "=== Setting up test environment ==="
    rm -rf "$ANOMALIES_ACTIVE_DIR" "$ANOMALIES_RESOLVED_DIR" "$ANOMALIES_BASELINES_DIR" "$ANOMALIES_INDEX_DIR"
    mkdir -p "$ANOMALIES_ACTIVE_DIR" "$ANOMALIES_RESOLVED_DIR" "$ANOMALIES_BASELINES_DIR" "$ANOMALIES_INDEX_DIR"
}

teardown() {
    echo ""
    echo "=== Cleaning up test environment ==="
    rm -rf "$ANOMALIES_ACTIVE_DIR" "$ANOMALIES_RESOLVED_DIR" "$ANOMALIES_BASELINES_DIR" "$ANOMALIES_INDEX_DIR"
}

#
# Test: Generate anomaly ID
#
test_generate_anomaly_id() {
    echo ""
    echo "=== Test: Generate Anomaly ID ==="

    local id1=$(generate_anomaly_id)
    local id2=$(generate_anomaly_id)

    assert_contains "$id1" "anomaly-" "ID should contain 'anomaly-' prefix"

    [[ "$id1" != "$id2" ]] && \
        echo "✓ PASS: Generated IDs are unique" || \
        echo "✗ FAIL: IDs are not unique"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "$id1" != "$id2" ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))
}

#
# Test: Classify anomaly type
#
test_classify_anomaly_type() {
    echo ""
    echo "=== Test: Classify Anomaly Type ==="

    local type1=$(classify_anomaly_type "task_success_rate" "-2.5")
    assert_equals "success_rate_drop" "$type1" "Negative deviation on success_rate should be drop"

    local type2=$(classify_anomaly_type "token_usage_total" "3.0")
    assert_equals "token_usage_spike" "$type2" "Positive deviation on token should be spike"

    local type3=$(classify_anomaly_type "task_queue_depth" "4.0")
    assert_equals "queue_depth_explosion" "$type3" "Positive deviation on queue should be explosion"

    local type4=$(classify_anomaly_type "routing_confidence_avg" "-1.5")
    assert_equals "routing_confidence_degradation" "$type4" "Negative deviation on confidence should be degradation"

    local type5=$(classify_anomaly_type "worker_failure_rate" "2.0")
    assert_equals "worker_failure_clustering" "$type5" "Positive deviation on failure should be clustering"
}

#
# Test: Calculate severity
#
test_calculate_severity() {
    echo ""
    echo "=== Test: Calculate Severity ==="

    local sev1=$(calculate_severity "2.5")
    assert_equals "low" "$sev1" "2.5 sigma should be low"

    local sev2=$(calculate_severity "3.5")
    assert_equals "medium" "$sev2" "3.5 sigma should be medium"

    local sev3=$(calculate_severity "4.5")
    assert_equals "high" "$sev3" "4.5 sigma should be high"

    local sev4=$(calculate_severity "5.5")
    assert_equals "critical" "$sev4" "5.5 sigma should be critical"

    # Test negative deviation
    local sev5=$(calculate_severity "-4.0")
    assert_equals "high" "$sev5" "-4.0 sigma should be high"
}

#
# Test: Generate suggested actions
#
test_generate_suggested_actions() {
    echo ""
    echo "=== Test: Generate Suggested Actions ==="

    local actions1=$(generate_suggested_actions "success_rate_drop")
    assert_contains "$actions1" "task failures" "Should suggest checking task failures"

    local actions2=$(generate_suggested_actions "token_usage_spike")
    assert_contains "$actions2" "token" "Should mention token in actions"

    local actions3=$(generate_suggested_actions "queue_depth_explosion")
    assert_contains "$actions3" "workers" "Should suggest scaling workers"
}

#
# Test: Record anomaly
#
test_record_anomaly() {
    echo ""
    echo "=== Test: Record Anomaly ==="

    local anomaly_id=$(record_anomaly \
        "test_metric" \
        "150" \
        "100" \
        "10" \
        "5.0" \
        "50" \
        "three_sigma" \
        "{\"test\":true}")

    assert_not_empty "$anomaly_id" "Should return anomaly ID"

    local anomaly_file="$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json"
    assert_file_exists "$anomaly_file" "Anomaly file should be created"

    # Check anomaly content
    local type=$(jq -r '.type' "$anomaly_file")
    assert_not_empty "$type" "Anomaly type should be set"

    local severity=$(jq -r '.severity' "$anomaly_file")
    assert_equals "critical" "$severity" "5.0 sigma should be critical"

    local status=$(jq -r '.status' "$anomaly_file")
    assert_equals "active" "$status" "New anomaly should be active"

    local description=$(jq -r '.description' "$anomaly_file")
    assert_contains "$description" "test_metric" "Description should mention metric name"
}

#
# Test: Create baseline with mock data
#
test_create_baseline() {
    echo ""
    echo "=== Test: Create Baseline ==="

    # Create mock baseline data manually
    local metric_name="test_baseline_metric"
    local baseline_file="$ANOMALIES_BASELINES_DIR/${metric_name}.baseline"

    jq -n \
        --arg metric_name "$metric_name" \
        '{
            metric_name: $metric_name,
            window_start: (now * 1000 | floor) - 604800000,
            window_end: (now * 1000 | floor),
            updated_at: (now * 1000 | floor),
            sample_count: 100,
            mean: 100,
            stddev: 10,
            min: 70,
            max: 130,
            p50: 100,
            p95: 120,
            p99: 125
        }' > "$baseline_file"

    assert_file_exists "$baseline_file" "Baseline file should be created"

    # Test get_baseline
    local baseline=$(get_baseline "$metric_name" 48)
    local mean=$(echo "$baseline" | jq -r '.mean')
    assert_equals "100" "$mean" "Baseline mean should be 100"
}

#
# Test: Three-sigma detection
#
test_three_sigma_detection() {
    echo ""
    echo "=== Test: Three-Sigma Detection ==="

    # Create baseline
    local metric_name="test_sigma_metric"
    local baseline_file="$ANOMALIES_BASELINES_DIR/${metric_name}.baseline"

    jq -n \
        --arg metric_name "$metric_name" \
        '{
            metric_name: $metric_name,
            window_start: (now * 1000 | floor) - 604800000,
            window_end: (now * 1000 | floor),
            updated_at: (now * 1000 | floor),
            sample_count: 100,
            mean: 100,
            stddev: 10,
            min: 70,
            max: 130,
            p50: 100,
            p95: 120,
            p99: 125
        }' > "$baseline_file"

    # Test normal value (within 3 sigma)
    local result=$(detect_three_sigma "$metric_name" "110" 3)
    local is_anomaly=$(echo "$result" | head -1)
    assert_equals "false" "$is_anomaly" "110 should not be anomaly (within 1 sigma)"

    # Test anomalous value (beyond 3 sigma)
    result=$(detect_three_sigma "$metric_name" "140" 3)
    is_anomaly=$(echo "$result" | head -1)
    assert_equals "true" "$is_anomaly" "140 should be anomaly (4 sigma)"

    # Test very anomalous value (beyond 5 sigma)
    result=$(detect_three_sigma "$metric_name" "160" 3)
    is_anomaly=$(echo "$result" | head -1)
    assert_equals "true" "$is_anomaly" "160 should be anomaly (6 sigma)"
}

#
# Test: Resolve anomaly
#
test_resolve_anomaly() {
    echo ""
    echo "=== Test: Resolve Anomaly ==="

    # Create test anomaly
    local anomaly_id=$(record_anomaly \
        "test_resolve_metric" \
        "150" \
        "100" \
        "10" \
        "5.0" \
        "50" \
        "three_sigma" \
        "{}")

    # Verify it's active
    local active_file="$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json"
    assert_file_exists "$active_file" "Active anomaly should exist"

    # Resolve it
    resolve_anomaly "$anomaly_id" "Test resolution"

    # Verify it moved to resolved
    local resolved_file="$ANOMALIES_RESOLVED_DIR/${anomaly_id}.json"
    assert_file_exists "$resolved_file" "Resolved anomaly should exist"

    # Verify active file is gone
    [[ ! -f "$active_file" ]] && \
        echo "✓ PASS: Active file removed" || \
        echo "✗ FAIL: Active file still exists"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ ! -f "$active_file" ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

    # Check status
    local status=$(jq -r '.status' "$resolved_file")
    assert_equals "resolved" "$status" "Status should be 'resolved'"

    local notes=$(jq -r '.resolution_notes' "$resolved_file")
    assert_contains "$notes" "Test resolution" "Should have resolution notes"
}

#
# Test: Mark false positive
#
test_mark_false_positive() {
    echo ""
    echo "=== Test: Mark False Positive ==="

    # Create test anomaly
    local anomaly_id=$(record_anomaly \
        "test_fp_metric" \
        "150" \
        "100" \
        "10" \
        "5.0" \
        "50" \
        "three_sigma" \
        "{}")

    # Mark as false positive
    mark_false_positive "$anomaly_id" "Testing FP"

    # Verify it's in resolved
    local resolved_file="$ANOMALIES_RESOLVED_DIR/${anomaly_id}.json"
    assert_file_exists "$resolved_file" "False positive should be in resolved"

    # Check resolution notes
    local notes=$(jq -r '.resolution_notes' "$resolved_file")
    assert_contains "$notes" "False positive" "Notes should mention false positive"
}

#
# Test: Get anomaly statistics
#
test_anomaly_statistics() {
    echo ""
    echo "=== Test: Anomaly Statistics ==="

    # Create multiple anomalies
    local id1=$(record_anomaly "metric1" "150" "100" "10" "5.0" "50" "three_sigma" "{}")
    local id2=$(record_anomaly "metric2" "160" "100" "10" "6.0" "60" "three_sigma" "{}")
    local id3=$(record_anomaly "metric3" "140" "100" "10" "4.0" "40" "three_sigma" "{}")

    # Resolve one
    resolve_anomaly "$id1" "Resolved"

    # Mark one as false positive
    mark_false_positive "$id2" "FP"

    # Get stats
    local stats=$(get_anomaly_stats "today")

    local total=$(echo "$stats" | jq -r '.total_anomalies')
    [[ $total -eq 3 ]] && \
        echo "✓ PASS: Total anomalies correct ($total)" || \
        echo "✗ FAIL: Total anomalies wrong ($total, expected 3)"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ $total -eq 3 ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

    local active=$(echo "$stats" | jq -r '.active_anomalies')
    [[ $active -eq 1 ]] && \
        echo "✓ PASS: Active anomalies correct ($active)" || \
        echo "✗ FAIL: Active anomalies wrong ($active, expected 1)"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ $active -eq 1 ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

    local fp=$(echo "$stats" | jq -r '.false_positives')
    [[ $fp -eq 1 ]] && \
        echo "✓ PASS: False positives correct ($fp)" || \
        echo "✗ FAIL: False positives wrong ($fp, expected 1)"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ $fp -eq 1 ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))
}

#
# Test: Anomaly indexing
#
test_anomaly_indexing() {
    echo ""
    echo "=== Test: Anomaly Indexing ==="

    # Create anomaly
    local anomaly_id=$(record_anomaly \
        "test_index_metric" \
        "150" \
        "100" \
        "10" \
        "5.0" \
        "50" \
        "three_sigma" \
        "{}")

    # Check day index
    local day=$(date +%Y-%m-%d)
    local day_index="$ANOMALIES_INDEX_DIR/by-day-${day}.index"
    assert_file_exists "$day_index" "Day index should exist"

    # Check if anomaly ID is in index
    local in_index=$(grep -c "$anomaly_id" "$day_index" || true)
    [[ $in_index -gt 0 ]] && \
        echo "✓ PASS: Anomaly indexed by day" || \
        echo "✗ FAIL: Anomaly not in day index"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ $in_index -gt 0 ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))
}

#
# Test: Multiple anomalies and clustering
#
test_multiple_anomalies() {
    echo ""
    echo "=== Test: Multiple Anomalies ==="

    # Create 5 anomalies with different severities
    local id1=$(record_anomaly "metric1" "105" "100" "10" "0.5" "5" "three_sigma" "{}")  # low
    local id2=$(record_anomaly "metric2" "135" "100" "10" "3.5" "35" "three_sigma" "{}")  # medium
    local id3=$(record_anomaly "metric3" "145" "100" "10" "4.5" "45" "three_sigma" "{}")  # high
    local id4=$(record_anomaly "metric4" "155" "100" "10" "5.5" "55" "three_sigma" "{}")  # critical
    local id5=$(record_anomaly "metric5" "165" "100" "10" "6.5" "65" "three_sigma" "{}")  # critical

    # Get stats
    local stats=$(get_anomaly_stats "today")

    local by_severity_critical=$(echo "$stats" | jq -r '.by_severity.critical')
    [[ $by_severity_critical -ge 2 ]] && \
        echo "✓ PASS: Critical severity count correct ($by_severity_critical)" || \
        echo "✗ FAIL: Critical severity count wrong ($by_severity_critical)"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ $by_severity_critical -ge 2 ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

    local total=$(echo "$stats" | jq -r '.total_anomalies')
    [[ $total -ge 5 ]] && \
        echo "✓ PASS: Total anomalies tracked ($total)" || \
        echo "✗ FAIL: Total anomalies wrong ($total)"
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ $total -ge 5 ]] && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))
}

#
# Run all tests
#
run_all_tests() {
    echo "========================================"
    echo "Anomaly Detection System Tests"
    echo "========================================"

    setup

    test_generate_anomaly_id
    setup
    test_classify_anomaly_type
    setup
    test_calculate_severity
    setup
    test_generate_suggested_actions
    setup
    test_record_anomaly
    setup
    test_create_baseline
    setup
    test_three_sigma_detection
    setup
    test_resolve_anomaly
    setup
    test_mark_false_positive
    setup
    test_anomaly_statistics
    setup
    test_anomaly_indexing
    setup
    test_multiple_anomalies

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
