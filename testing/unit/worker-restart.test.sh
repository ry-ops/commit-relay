#!/bin/bash
# testing/unit/worker-restart.test.sh
# Unit tests for Worker Automatic Restart System
# Phase 4.3 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/worker-restart.sh"

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
    TEST_WORKER_ID="test-restart-worker-001"
    TEST_TASK_ID="task-restart-test-001"
    TEST_WORKER_TYPE="implementation-worker"

    # Create test directories
    mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$(date +%Y-%m-%d)"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/restart/queue"

    # Create test zombie spec
    ZOMBIE_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$(date +%Y-%m-%d)/${TEST_WORKER_ID}.json"
    cat > "$ZOMBIE_SPEC" <<'EOFSPEC'
{
  "worker_id": "test-restart-worker-001",
  "worker_type": "implementation-worker",
  "parent_master": "development-master",
  "task_id": "task-restart-test-001",
  "status": "zombie",
  "created_at": "2025-11-18T14:00:00-0600",
  "created_by": "test-suite",
  "resources": {
    "token_allocation": 50000
  },
  "execution": {
    "started_at": "2025-11-18T14:00:00-0600",
    "tokens_used": 15000
  },
  "cleanup": {
    "cleaned_at": "2025-11-18T15:00:00-0600",
    "reason": "No heartbeat for >300s",
    "automated": true
  },
  "restart": {
    "restart_attempt": 0
  }
}
EOFSPEC

    # Create test token budget
    echo '{"total_budget": 500000, "total_used": 100000}' > "$COMMIT_RELAY_HOME/coordination/token-budget.json"

    # Initialize circuit breaker file
    echo '{}' > "$COMMIT_RELAY_HOME/coordination/restart/circuit-breakers.json"
}

cleanup_test_env() {
    rm -rf "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$(date +%Y-%m-%d)/${TEST_WORKER_ID}"* 2>/dev/null || true
    rm -rf "$COMMIT_RELAY_HOME/coordination/restart/queue/${TEST_WORKER_ID}"* 2>/dev/null || true
    rm -f "$COMMIT_RELAY_HOME/coordination/restart/circuit-breakers.json" 2>/dev/null || true
    rm -f /tmp/restart-rate-limit-* 2>/dev/null || true
}

echo ""
echo "===========================================" echo "  Worker Restart System Unit Tests"
echo "==========================================="
echo ""

setup_test_env

# Test 1
test_start "Restart library loads"
if [ -f "$COMMIT_RELAY_HOME/scripts/lib/worker-restart.sh" ]; then
    test_pass
else
    test_fail "Library file not found"
fi

# Test 2
test_start "Configuration file exists and is valid"
if [ -f "$RESTART_POLICY_FILE" ] && jq empty "$RESTART_POLICY_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Configuration file invalid or missing"
fi

# Test 3
test_start "get_max_retries returns correct values"
max_retries=$(get_max_retries "implementation-worker")
if [ "$max_retries" = "2" ]; then
    test_pass
else
    test_fail "Expected 2, got: $max_retries"
fi

# Test 4
test_start "calculate_restart_delay exponential backoff"
delay1=$(calculate_restart_delay 1)
delay2=$(calculate_restart_delay 2)
delay3=$(calculate_restart_delay 3)

if [ "$delay1" = "30" ] && [ "$delay2" = "60" ] && [ "$delay3" = "120" ]; then
    test_pass
else
    test_fail "Delays: $delay1, $delay2, $delay3 (expected 30, 60, 120)"
fi

# Test 5
test_start "calculate_restart_delay caps at max"
delay10=$(calculate_restart_delay 10)
if [ "$delay10" = "300" ]; then
    test_pass
else
    test_fail "Expected 300, got: $delay10"
fi

# Test 6
test_start "check_circuit_breaker allows when not tripped"
if check_circuit_breaker "$TEST_WORKER_TYPE"; then
    test_pass
else
    test_fail "Circuit breaker incorrectly blocking"
fi

# Test 7
test_start "trip_circuit_breaker activates breaker"
trip_circuit_breaker "$TEST_WORKER_TYPE" "test_reason"

is_active=$(jq -r --arg type "$TEST_WORKER_TYPE" '.[$type].active' "$CIRCUIT_BREAKER_FILE")
if [ "$is_active" = "true" ]; then
    test_pass
else
    test_fail "Circuit breaker not activated"
fi

# Test 8
test_start "check_circuit_breaker blocks when tripped"
if ! check_circuit_breaker "$TEST_WORKER_TYPE"; then
    test_pass
else
    test_fail "Circuit breaker not blocking"
fi

# Test 9
test_start "reset_circuit_breaker deactivates breaker"
reset_circuit_breaker "$TEST_WORKER_TYPE" "test_reset"

is_active=$(jq -r --arg type "$TEST_WORKER_TYPE" '.[$type].active' "$CIRCUIT_BREAKER_FILE")
if [ "$is_active" = "false" ]; then
    test_pass
else
    test_fail "Circuit breaker not reset"
fi

# Test 10
test_start "check_restart_rate_limit allows initially"
rm -f /tmp/restart-rate-limit-* 2>/dev/null || true

if check_restart_rate_limit "$TEST_WORKER_TYPE"; then
    test_pass
else
    test_fail "Rate limit incorrectly blocking"
fi

# Test 11
test_start "check_restart_rate_limit enforces per-type limit"
# Clean up rate limit file
rm -f /tmp/restart-rate-limit-* 2>/dev/null

# Trigger 3 restarts (per-type limit is 3)
success_count=0
for i in {1..3}; do
    if check_restart_rate_limit "$TEST_WORKER_TYPE"; then
        ((success_count++))
    fi
done

# 4th should fail
if ! check_restart_rate_limit "$TEST_WORKER_TYPE"; then
    if [ $success_count -eq 3 ]; then
        test_pass
    else
        test_fail "Expected 3 successful, got $success_count"
    fi
else
    test_fail "Rate limit not enforced"
fi

# Test 12
test_start "check_token_budget allows when sufficient"
if check_token_budget 50000; then
    test_pass
else
    test_fail "Token budget check failed with sufficient budget"
fi

# Test 13
test_start "check_token_budget blocks when insufficient"
if ! check_token_budget 500000; then
    test_pass
else
    test_fail "Token budget check allowed with insufficient budget"
fi

# Test 14
test_start "should_restart_worker allows eligible worker"
# Reset rate limit for this test
rm -f /tmp/restart-rate-limit-* 2>/dev/null || true

# Update zombie spec to be eligible (attempt 0, max is 2)
jq '.restart.restart_attempt = 0' "$ZOMBIE_SPEC" > "${ZOMBIE_SPEC}.tmp" && mv "${ZOMBIE_SPEC}.tmp" "$ZOMBIE_SPEC"

if should_restart_worker "$TEST_WORKER_ID" 2>/dev/null; then
    test_pass
else
    test_fail "Should have allowed restart"
fi

# Test 15
test_start "should_restart_worker blocks max retries exceeded"
# Set restart attempt to max retries
jq '.restart.restart_attempt = 2' "$ZOMBIE_SPEC" > "${ZOMBIE_SPEC}.tmp" && mv "${ZOMBIE_SPEC}.tmp" "$ZOMBIE_SPEC"

if ! should_restart_worker "$TEST_WORKER_ID" 2>/dev/null; then
    test_pass
else
    test_fail "Should have blocked restart (max retries)"
fi

# Test 16
test_start "restart_worker creates queue entry"
# Reset to eligible state
jq '.restart.restart_attempt = 0' "$ZOMBIE_SPEC" > "${ZOMBIE_SPEC}.tmp" && mv "${ZOMBIE_SPEC}.tmp" "$ZOMBIE_SPEC"
rm -f /tmp/restart-rate-limit-* 2>/dev/null || true

restart_worker "$TEST_WORKER_ID" 2>/dev/null || true

# Check if queue entry was created
QUEUE_ENTRY="$COMMIT_RELAY_HOME/coordination/restart/queue/${TEST_WORKER_ID}-restart-1.json"
if [ -f "$QUEUE_ENTRY" ]; then
    test_pass
else
    test_fail "Queue entry not created"
fi

# Test 17
test_start "queue entry has correct structure"
if [ -f "$QUEUE_ENTRY" ]; then
    new_worker_id=$(jq -r '.new_worker_id' "$QUEUE_ENTRY")
    task_id=$(jq -r '.task_id' "$QUEUE_ENTRY")
    attempt=$(jq -r '.attempt' "$QUEUE_ENTRY")

    if [ "$new_worker_id" = "${TEST_WORKER_ID}-restart-1" ] && \
       [ "$task_id" = "$TEST_TASK_ID" ] && \
       [ "$attempt" = "1" ]; then
        test_pass
    else
        test_fail "Queue entry structure incorrect"
    fi
else
    test_fail "Queue entry not found"
fi

# Test 18
test_start "emit_restart_event creates event log"
emit_restart_event "test_event" "$TEST_WORKER_ID" '{"test": true}' 2>/dev/null || true

EVENTS_LOG="$COMMIT_RELAY_HOME/coordination/events/worker-restart-events.jsonl"
if [ -f "$EVENTS_LOG" ] && grep -q "test_event" "$EVENTS_LOG"; then
    test_pass
else
    test_fail "Event not logged"
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
