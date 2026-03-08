#!/bin/bash
# testing/unit/zombie-cleanup.test.sh
# Unit tests for Zombie Worker Cleanup System
# Phase 4.2 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/zombie-cleanup.sh"

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
    TEST_WORKER_ID="test-zombie-worker-001"
    TEST_TASK_ID="task-zombie-test-001"
    TEST_WORKER_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${TEST_WORKER_ID}.json"
    TEST_WORKER_DIR="$COMMIT_RELAY_HOME/agents/workers/$TEST_WORKER_ID"

    mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/active"
    mkdir -p "$TEST_WORKER_DIR/logs"

    # Create test worker spec
    cat > "$TEST_WORKER_SPEC" <<'EOFSPEC'
{
  "worker_id": "test-zombie-worker-001",
  "worker_type": "test-worker",
  "parent_master": "development",
  "task_id": "task-zombie-test-001",
  "status": "running",
  "created_at": "2025-11-18T14:00:00-0600",
  "created_by": "test-suite",
  "resources": {
    "token_allocation": 100000
  },
  "execution": {
    "started_at": "2025-11-18T14:00:00-0600",
    "tokens_used": 25000
  },
  "heartbeat": {
    "last_heartbeat": "2025-11-18T14:00:00-0600",
    "heartbeat_sequence": 5,
    "health": {
      "status": "healthy",
      "health_score": 100
    },
    "missed_count": 0
  }
}
EOFSPEC
}

cleanup_test_env() {
    rm -rf "$TEST_WORKER_DIR"
    rm -f "$TEST_WORKER_SPEC"
    rm -f "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie"/*/"${TEST_WORKER_ID}.json" 2>/dev/null || true
    rm -f /tmp/zombie-cleanup-count-* 2>/dev/null || true
}

echo ""
echo "==========================================="
echo "  Zombie Cleanup System Unit Tests"
echo "==========================================="
echo ""

setup_test_env

# Test 1
test_start "Zombie cleanup library loads"
if [ -f "$COMMIT_RELAY_HOME/scripts/lib/zombie-cleanup.sh" ]; then
    test_pass
else
    test_fail "Library file not found"
fi

# Test 2
test_start "is_worker_zombie detects old heartbeat"
# Set heartbeat to 350 seconds ago
old_time=$(date -v-350S +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -d "350 seconds ago" +%Y-%m-%dT%H:%M:%S%z)
jq --arg t "$old_time" '.heartbeat.last_heartbeat = $t' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"

if is_worker_zombie "$TEST_WORKER_ID"; then
    test_pass
else
    test_fail "Failed to detect zombie worker"
fi

# Test 3
test_start "is_worker_zombie ignores recent heartbeat"
# Set heartbeat to 30 seconds ago
recent_time=$(date -v-30S +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -d "30 seconds ago" +%Y-%m-%dT%H:%M:%S%z)
jq --arg t "$recent_time" '.heartbeat.last_heartbeat = $t' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"

if ! is_worker_zombie "$TEST_WORKER_ID"; then
    test_pass
else
    test_fail "False positive: detected zombie for recent heartbeat"
fi

# Test 4
test_start "return_worker_tokens calculates correctly"
# Set old heartbeat again for remaining tests
old_time=$(date -v-350S +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -d "350 seconds ago" +%Y-%m-%dT%H:%M:%S%z)
jq --arg t "$old_time" '.heartbeat.last_heartbeat = $t' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"

# Create test token budget
TOKEN_BUDGET="$COMMIT_RELAY_HOME/coordination/token-budget.json"
echo '{"total_budget": 500000, "total_used": 125000}' > "$TOKEN_BUDGET"

return_worker_tokens "$TEST_WORKER_ID" >/dev/null 2>&1

# Should have returned 75000 tokens (100000 - 25000)
used=$(jq -r '.total_used' "$TOKEN_BUDGET")
if [ "$used" = "50000" ]; then
    test_pass
else
    test_fail "Expected 50000 used tokens, got: $used"
fi

# Test 5
test_start "archive_worker_logs creates archive"
# Create some test logs
echo "Test log line 1" > "$TEST_WORKER_DIR/logs/stdout.log"
echo "Test log line 2" > "$TEST_WORKER_DIR/logs/stderr.log"

archive_worker_logs "$TEST_WORKER_ID" >/dev/null 2>&1

ARCHIVE_DATE=$(date +%Y-%m-%d)
ARCHIVE_DIR="$COMMIT_RELAY_HOME/agents/logs/zombie-workers/$ARCHIVE_DATE"

if [ -d "$ARCHIVE_DIR/${TEST_WORKER_ID}-logs" ]; then
    test_pass
else
    test_fail "Archive directory not created"
fi

# Test 6
test_start "cleanup_worker_state moves spec to zombie dir"
cleanup_worker_state "$TEST_WORKER_ID" >/dev/null 2>&1

ZOMBIE_DATE=$(date +%Y-%m-%d)
ZOMBIE_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$ZOMBIE_DATE/${TEST_WORKER_ID}.json"

if [ -f "$ZOMBIE_SPEC" ]; then
    test_pass
else
    test_fail "Zombie spec not found at $ZOMBIE_SPEC"
fi

# Test 7
test_start "cleanup_worker_state adds cleanup metadata"
status=$(jq -r '.status' "$ZOMBIE_SPEC")
cleanup_obj=$(jq -r '.cleanup' "$ZOMBIE_SPEC")

if [ "$status" = "zombie" ] && [ "$cleanup_obj" != "null" ]; then
    test_pass
else
    test_fail "Status: $status, cleanup: $cleanup_obj"
fi

# Test 8
test_start "cleanup_worker_state sets automated flag"
automated=$(jq -r '.cleanup.automated' "$ZOMBIE_SPEC")

if [ "$automated" = "true" ]; then
    test_pass
else
    test_fail "Automated flag not set correctly"
fi

# Test 9
test_start "check_cleanup_rate_limit prevents storms"
# Clean up rate limit file
rm -f /tmp/zombie-cleanup-count-* 2>/dev/null

# Test 5 cleanups should work
success_count=0
for i in {1..5}; do
    if check_cleanup_rate_limit; then
        ((success_count++))
    fi
done

# 6th should fail
if ! check_cleanup_rate_limit; then
    if [ $success_count -eq 5 ]; then
        test_pass
    else
        test_fail "Expected 5 successful, got $success_count"
    fi
else
    test_fail "Rate limit not enforced"
fi

# Test 10
test_start "emit_zombie_event creates event log"
emit_zombie_event "test_event" "$TEST_WORKER_ID" '{"test": true}' >/dev/null 2>&1

EVENTS_LOG="$COMMIT_RELAY_HOME/coordination/events/zombie-cleanup-events.jsonl"
if [ -f "$EVENTS_LOG" ] && grep -q "test_event" "$EVENTS_LOG"; then
    test_pass
else
    test_fail "Event not logged"
fi

# Test 11
test_start "Configuration file exists and is valid JSON"
CONFIG_FILE="$COMMIT_RELAY_HOME/coordination/config/zombie-cleanup-policy.json"
if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Config file invalid or missing"
fi

# Test 12
test_start "Configuration has required fields"
enabled=$(jq -r '.enabled' "$CONFIG_FILE")
threshold=$(jq -r '.detection.zombie_threshold_seconds' "$CONFIG_FILE")

if [ "$enabled" != "null" ] && [ "$threshold" != "null" ]; then
    test_pass
else
    test_fail "Missing required config fields"
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
