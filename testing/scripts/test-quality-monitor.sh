#!/bin/bash
# testing/scripts/test-quality-monitor.sh
# Test suite for data quality monitoring
#
# Tests:
# - JSON syntax validation
# - Schema validation
# - Template variable detection
# - Data freshness checking
# - Referential integrity
# - Quality scoring

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export COMMIT_RELAY_HOME

cd "$COMMIT_RELAY_HOME"

# Load quality monitor
source coordination/governance/lib/quality-monitor.sh

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${BLUE}Test $TESTS_RUN: $test_name${NC}"

    if $test_func; then
        echo -e "${GREEN}✓ PASSED${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    echo ""
}

# Test 1: Valid JSON passes syntax check
test_valid_json() {
    local test_file="/tmp/test-quality-valid-$$.json"
    echo '{"id": "test-123", "status": "active"}' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    local passed=$(echo "$result" | jq -r '.checks.passed')

    rm -f "$test_file"

    [ "$passed" -ge 1 ]
}

# Test 2: Invalid JSON fails syntax check
test_invalid_json() {
    local test_file="/tmp/test-quality-invalid-$$.json"
    echo '{invalid json}' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    local failed=$(echo "$result" | jq -r '.checks.failed')

    rm -f "$test_file"

    [ "$failed" -ge 1 ]
}

# Test 3: Template variables detected
test_template_vars() {
    local test_file="/tmp/test-quality-template-$$.json"
    echo '{"id": "test", "field": , , "other": "value"}' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    local issues=$(echo "$result" | jq -r '.issues[] | select(.check == "template_vars") | .severity')

    rm -f "$test_file"

    [ "$issues" = "error" ]
}

# Test 4: Empty fields detected
test_empty_fields() {
    local test_file="/tmp/test-quality-empty-$$.json"
    echo '{"id": "test", "description": "TODO", "status": ""}' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    local issues=$(echo "$result" | jq -r '.issues[] | select(.check == "completeness") | .severity')

    rm -f "$test_file"

    [ "$issues" = "warning" ]
}

# Test 5: File not found
test_file_not_found() {
    local result=$(check_data_quality "/nonexistent/file.json" "none")
    local error=$(echo "$result" | jq -r '.error')

    [ "$error" = "file_not_found" ]
}

# Test 6: Quality score calculation - perfect file
test_quality_score_perfect() {
    local test_file="/tmp/test-quality-perfect-$$.json"
    echo '{"id": "test-123", "status": "active", "description": "Valid content"}' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    local score=$(echo "$result" | jq -r '.overall_score')

    rm -f "$test_file"

    [ "$score" -ge 90 ]
}

# Test 7: Quality score calculation - poor file
test_quality_score_poor() {
    local test_file="/tmp/test-quality-poor-$$.json"
    echo '{"id": "test", "field": , , "desc": "TODO"}' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    local score=$(echo "$result" | jq -r '.overall_score')

    rm -f "$test_file"

    [ "$score" -lt 70 ]
}

# Test 8: Quality level assignment - excellent
test_quality_level_excellent() {
    local level=$(get_quality_level 98)

    [ "$level" = "excellent" ]
}

# Test 9: Quality level assignment - good
test_quality_level_good() {
    local level=$(get_quality_level 88)

    [ "$level" = "good" ]
}

# Test 10: Quality level assignment - critical
test_quality_level_critical() {
    local level=$(get_quality_level 30)

    [ "$level" = "critical" ]
}

# Test 11: Freshness check - fresh file
test_freshness_fresh() {
    local test_file="/tmp/test-quality-fresh-$$.json"
    echo '{"created_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' > "$test_file"

    local freshness=$(check_freshness "$test_file")

    rm -f "$test_file"

    [ "$freshness" = "ok" ]
}

# Test 12: Check all workers (with no workers)
test_check_all_workers_empty() {
    # Create temporary empty worker specs dir
    local temp_dir="/tmp/test-workers-$$"
    mkdir -p "$temp_dir"

    local old_dir="${COMMIT_RELAY_HOME}"
    export COMMIT_RELAY_HOME="/tmp/test-commit-relay-$$"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/active"

    local result=$(check_all_workers)
    local total=$(echo "$result" | jq -r '.workers_checked')

    # Cleanup
    export COMMIT_RELAY_HOME="$old_dir"
    rm -rf "/tmp/test-commit-relay-$$"

    [ "$total" -eq 0 ]
}

# Test 13: Overall health - healthy
test_overall_health() {
    # This will depend on actual worker specs, so just test it runs
    local health=$(get_overall_health)

    [ -n "$health" ] && ([ "$health" = "healthy" ] || [ "$health" = "degraded" ] || [ "$health" = "unhealthy" ])
}

# Test 14: Quality issue logging
test_quality_issue_logging() {
    local test_file="/tmp/test-quality-log-$$.json"
    echo '{"id": "test", "field": , }' > "$test_file"

    local result=$(check_data_quality "$test_file" "none")
    log_quality_issue "$result" "$test_file"

    local log_file="$COMMIT_RELAY_HOME/coordination/governance/quality-issues.jsonl"
    local logged=$([ -f "$log_file" ] && grep -c "test-quality-log" "$log_file" 2>/dev/null || echo 0)

    rm -f "$test_file"

    [ "$logged" -ge 1 ]
}

# Header
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Quality Monitor Test Suite${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# Run all tests
run_test "Valid JSON passes syntax check" test_valid_json
run_test "Invalid JSON fails syntax check" test_invalid_json
run_test "Template variables detected" test_template_vars
run_test "Empty fields detected" test_empty_fields
run_test "File not found handled" test_file_not_found
run_test "Quality score - perfect file" test_quality_score_perfect
run_test "Quality score - poor file" test_quality_score_poor
run_test "Quality level - excellent" test_quality_level_excellent
run_test "Quality level - good" test_quality_level_good
run_test "Quality level - critical" test_quality_level_critical
run_test "Freshness check - fresh file" test_freshness_fresh
run_test "Check all workers (empty)" test_check_all_workers_empty
run_test "Overall health check" test_overall_health
run_test "Quality issue logging" test_quality_issue_logging

# Summary
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Test Results${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Total tests: $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
echo ""

# Calculate percentage
if [ $TESTS_RUN -gt 0 ]; then
    PASS_RATE=$(echo "scale=1; $TESTS_PASSED * 100 / $TESTS_RUN" | bc)
    echo "  Pass rate: ${PASS_RATE}%"
    echo ""
fi

# Final verdict
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓✓✓ ALL TESTS PASSED${NC}"
    echo -e "${GREEN}Quality monitor is working correctly${NC}"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo -e "${RED}Quality monitor needs investigation${NC}"
    exit 1
fi
