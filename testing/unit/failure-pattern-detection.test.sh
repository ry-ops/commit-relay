#!/bin/bash
# testing/unit/failure-pattern-detection.test.sh
# Unit tests for Failure Pattern Detection System
# Phase 4.4 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/failure-pattern-detection.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_start() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Test $TESTS_RUN: $1 ... "
}

test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}"
    [ -n "${1:-}" ] && echo "  Error: $1"
}

setup_test_env() {
    # Create test directories
    mkdir -p "$COMMIT_RELAY_HOME/coordination/patterns"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/events"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$(date +%Y-%m-%d)"

    # Backup existing files
    [ -f "$PATTERN_DB" ] && mv "$PATTERN_DB" "${PATTERN_DB}.backup"
    [ -f "$PATTERN_INDEX" ] && mv "$PATTERN_INDEX" "${PATTERN_INDEX}.backup"

    # Create test event files
    TEST_ZOMBIE_EVENTS="$COMMIT_RELAY_HOME/coordination/events/zombie-cleanup-events.jsonl"
    TEST_RESTART_EVENTS="$COMMIT_RELAY_HOME/coordination/events/worker-restart-events.jsonl"

    # Create sample events
    cat > "$TEST_ZOMBIE_EVENTS" <<'EOFEVENTS'
{"event_type":"zombie_detected","worker_id":"test-worker-001","timestamp":"2025-11-18T10:00:00-0600","data":{}}
{"event_type":"zombie_detected","worker_id":"test-worker-002","timestamp":"2025-11-18T10:05:00-0600","data":{}}
{"event_type":"zombie_detected","worker_id":"test-worker-003","timestamp":"2025-11-18T10:10:00-0600","data":{}}
{"event_type":"worker_presumed_dead","worker_id":"test-worker-004","timestamp":"2025-11-18T10:15:00-0600","data":{}}
EOFEVENTS

    cat > "$TEST_RESTART_EVENTS" <<'EOFEVENTS'
{"event_type":"worker_restart_abandoned","worker_id":"test-worker-001","timestamp":"2025-11-18T10:20:00-0600","data":{}}
{"event_type":"circuit_breaker_tripped","worker_id":"test-worker-005","timestamp":"2025-11-18T10:25:00-0600","data":{}}
EOFEVENTS

    # Create test worker specs
    cat > "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$(date +%Y-%m-%d)/test-worker-001.json" <<'EOFSPEC'
{
  "worker_id": "test-worker-001",
  "worker_type": "scan-worker",
  "task_id": "task-001",
  "status": "zombie"
}
EOFSPEC
}

cleanup_test_env() {
    # Remove test files
    rm -f "$TEST_ZOMBIE_EVENTS" "$TEST_RESTART_EVENTS"
    rm -f "$PATTERN_DB" "$PATTERN_INDEX"
    rm -rf "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$(date +%Y-%m-%d)/test-worker-"*

    # Restore backups
    [ -f "${PATTERN_DB}.backup" ] && mv "${PATTERN_DB}.backup" "$PATTERN_DB"
    [ -f "${PATTERN_INDEX}.backup" ] && mv "${PATTERN_INDEX}.backup" "$PATTERN_INDEX"
}

echo ""
echo "==========================================="
echo "  Failure Pattern Detection Unit Tests"
echo "==========================================="
echo ""

setup_test_env

# Test 1
test_start "Pattern detection library loads"
if [ -f "$COMMIT_RELAY_HOME/scripts/lib/failure-pattern-detection.sh" ]; then
    test_pass
else
    test_fail "Library file not found"
fi

# Test 2
test_start "Configuration file exists and is valid"
if [ -f "$PATTERN_POLICY_FILE" ] && jq empty "$PATTERN_POLICY_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Configuration file invalid or missing"
fi

# Test 3
test_start "generate_pattern_id creates unique IDs"
id1=$(generate_pattern_id "resource" "out_of_memory" "scan-worker")
id2=$(generate_pattern_id "resource" "out_of_memory" "scan-worker")
id3=$(generate_pattern_id "systemic" "timeout" "scan-worker")

if [ "$id1" = "$id2" ] && [ "$id1" != "$id3" ]; then
    test_pass
else
    test_fail "IDs not consistent or not unique"
fi

# Test 4
test_start "classify_failure categorizes events correctly"
zombie_event='{"event_type":"zombie_detected","worker_id":"test-001"}'
classification=$(classify_failure "$zombie_event")

if [[ "$classification" =~ ^resource: ]]; then
    test_pass
else
    test_fail "Expected resource:*, got: $classification"
fi

# Test 5
test_start "extract_failure_signature creates signature"
event='{"event_type":"zombie_detected","worker_id":"test-worker-001","timestamp":"2025-11-18T10:00:00-0600"}'
signature=$(extract_failure_signature "$event")

worker_type=$(echo "$signature" | jq -r '.worker_type')
if [ "$worker_type" = "scan-worker" ]; then
    test_pass
else
    test_fail "Signature extraction failed, worker_type: $worker_type"
fi

# Test 6
test_start "calculate_signature_similarity computes similarity"
sig1='{"event_type":"zombie_detected","worker_type":"scan-worker"}'
sig2='{"event_type":"zombie_detected","worker_type":"scan-worker"}'
sig3='{"event_type":"zombie_detected","worker_type":"fix-worker"}'

similarity_same=$(calculate_signature_similarity "$sig1" "$sig2")
similarity_diff=$(calculate_signature_similarity "$sig1" "$sig3")

if (( $(echo "$similarity_same > $similarity_diff" | bc -l) )); then
    test_pass
else
    test_fail "Similarity calculation incorrect: same=$similarity_same, diff=$similarity_diff"
fi

# Test 7
test_start "collect_recent_events retrieves events"
events=$(collect_recent_events 24)
event_count=$(echo "$events" | grep -c . || echo "0")

if [ "$event_count" -ge 4 ]; then
    test_pass
else
    test_fail "Expected >= 4 events, got: $event_count"
fi

# Test 8
test_start "detect_frequent_patterns finds patterns"
events=$(collect_recent_events 24)
patterns=$(detect_frequent_patterns "$events" 2>&1)
pattern_count=$(echo "$patterns" | grep "pattern_" | grep -c . || echo "0")

if [ "$pattern_count" -ge 1 ]; then
    test_pass
else
    test_fail "Expected >= 1 pattern, got: $pattern_count"
fi

# Test 9
test_start "update_pattern creates pattern in database"
test_pattern='{"pattern_id":"test_pattern_001","category":"resource","type":"timeout","signature":{},"frequency":{"total_occurrences":1},"confidence":0.8,"severity":"medium","created_at":"2025-11-18T10:00:00-0600","updated_at":"2025-11-18T10:00:00-0600"}'

update_pattern "$test_pattern" 2>/dev/null

if grep -q "test_pattern_001" "$PATTERN_DB"; then
    test_pass
else
    test_fail "Pattern not found in database"
fi

# Test 10
test_start "update_pattern increments occurrence count"
update_pattern "$test_pattern" 2>/dev/null

occurrences=$(grep "test_pattern_001" "$PATTERN_DB" | jq -r '.frequency.total_occurrences')

if [ "$occurrences" -eq 2 ]; then
    test_pass
else
    test_fail "Expected 2 occurrences, got: $occurrences"
fi

# Test 11
test_start "find_matching_pattern finds existing pattern"
test_event='{"event_type":"worker_restart_abandoned","worker_id":"test-worker-001","timestamp":"2025-11-18T10:00:00-0600"}'

# First create a pattern
pattern_to_match='{"pattern_id":"test_pattern_match","category":"systemic","type":"max_retries_exceeded","signature":{"event_type":"worker_restart_abandoned","worker_type":"scan-worker"},"frequency":{"total_occurrences":1},"confidence":0.8,"severity":"high","created_at":"2025-11-18T10:00:00-0600","updated_at":"2025-11-18T10:00:00-0600"}'
update_pattern "$pattern_to_match" 2>/dev/null

# Try to find it
matched_id=$(find_matching_pattern "$test_event" 2>/dev/null || echo "")

if [ -n "$matched_id" ]; then
    test_pass
else
    test_fail "Failed to find matching pattern"
fi

# Test 12
test_start "update_pattern_index creates index"
update_pattern_index 2>/dev/null

if [ -f "$PATTERN_INDEX" ] && jq empty "$PATTERN_INDEX" 2>/dev/null; then
    test_pass
else
    test_fail "Pattern index not created or invalid"
fi

# Test 13
test_start "emit_pattern_event creates event log"
emit_pattern_event "pattern_detected" "test_pattern_001" '{"test": true}' 2>/dev/null

PATTERN_EVENTS_LOG="$COMMIT_RELAY_HOME/coordination/events/failure-pattern-events.jsonl"
if [ -f "$PATTERN_EVENTS_LOG" ] && grep -q "pattern_detected" "$PATTERN_EVENTS_LOG"; then
    test_pass
else
    test_fail "Event not logged"
fi

# Test 14
test_start "analyze_patterns runs end-to-end"
pattern_count=$(analyze_patterns 2>&1 | tail -1)

if [[ "$pattern_count" =~ ^[0-9]+$ ]]; then
    test_pass
else
    test_fail "Pattern analysis failed: $pattern_count"
fi

cleanup_test_env

echo ""
echo "==========================================="
echo "  Test Summary"
echo "==========================================="
echo ""
echo "Total Tests:  $TESTS_RUN"
echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}Some tests failed!${NC}"
    exit 1
fi
