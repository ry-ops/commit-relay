#!/bin/bash
# testing/unit/heartbeat.test.sh
# Comprehensive test suite for Worker Heartbeat System
# Phase 4.1 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh"

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
    TEST_WORKER_ID="test-worker-heartbeat-001"
    TEST_TASK_ID="task-heartbeat-test-001"
    TEST_WORKER_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${TEST_WORKER_ID}.json"

    mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/active"

    cat > "$TEST_WORKER_SPEC" <<'EOFSPEC'
{
  "worker_id": "test-worker-heartbeat-001",
  "worker_type": "test-worker",
  "parent_master": "development",
  "task_id": "task-heartbeat-test-001",
  "status": "running",
  "created_at": "2025-11-18T14:00:00-0600",
  "created_by": "test-suite",
  "resources": {
    "token_allocation": 100000
  },
  "execution": {
    "started_at": "2025-11-18T14:00:00-0600",
    "tokens_used": 25000
  }
}
EOFSPEC
}

cleanup_test_env() {
    rm -f "$TEST_WORKER_SPEC" "${TEST_WORKER_SPEC}.tmp"
}

echo ""
echo "=========================================="
echo "  Heartbeat System Test Suite"
echo "=========================================="
echo ""

setup_test_env

# Test 1
test_start "Heartbeat library loads"
[ -f "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh" ] && test_pass || test_fail

# Test 2
test_start "Initialize heartbeat"
init_heartbeat "$TEST_WORKER_ID" >/dev/null 2>&1 && test_pass || test_fail

# Test 3
test_start "Heartbeat sequence starts at 0"
seq=$(jq -r '.heartbeat.heartbeat_sequence' "$TEST_WORKER_SPEC")
[ "$seq" = "0" ] && test_pass || test_fail "Got: $seq"

# Test 4
test_start "Health status is healthy"
status=$(jq -r '.heartbeat.health.status' "$TEST_WORKER_SPEC")
[ "$status" = "healthy" ] && test_pass || test_fail "Got: $status"

# Test 5
test_start "Emit heartbeat increments sequence"
emit_heartbeat "$TEST_WORKER_ID" "test" >/dev/null 2>&1
seq=$(jq -r '.heartbeat.heartbeat_sequence' "$TEST_WORKER_SPEC")
[ "$seq" = "1" ] && test_pass || test_fail "Got: $seq"

# Test 6
test_start "Heartbeat updates timestamp"
emit_heartbeat "$TEST_WORKER_ID" "test" >/dev/null 2>&1
ts=$(jq -r '.heartbeat.last_heartbeat' "$TEST_WORKER_SPEC")
[ -n "$ts" ] && [ "$ts" != "null" ] && test_pass || test_fail

# Test 7
test_start "CPU usage is recorded"
cpu=$(jq -r '.heartbeat.health.cpu_usage_percent' "$TEST_WORKER_SPEC")
[ -n "$cpu" ] && [ "$cpu" != "null" ] && test_pass || test_fail

# Test 8
test_start "Memory usage is recorded"
mem=$(jq -r '.heartbeat.health.memory_usage_mb' "$TEST_WORKER_SPEC")
[ -n "$mem" ] && [ "$mem" != "null" ] && test_pass || test_fail

# Test 9
test_start "Token metrics are correct"
used=$(jq -r '.heartbeat.health.tokens_used' "$TEST_WORKER_SPEC")
remaining=$(jq -r '.heartbeat.health.tokens_remaining' "$TEST_WORKER_SPEC")
[ "$used" = "25000" ] && [ "$remaining" = "75000" ] && test_pass || test_fail "used: $used, remaining: $remaining"

# Test 10
test_start "Activity description recorded"
emit_heartbeat "$TEST_WORKER_ID" "Processing analysis" >/dev/null 2>&1
activity=$(jq -r '.heartbeat.health.last_activity' "$TEST_WORKER_SPEC")
[ "$activity" = "Processing analysis" ] && test_pass || test_fail

# Test 11
test_start "Health score calculation"
score=$(calculate_health_score 50 256 25000 75000)
[ "$score" -ge 0 ] && [ "$score" -le 100 ] && test_pass || test_fail "Score: $score"

# Test 12
test_start "Health status from score (healthy)"
status=$(get_health_status_from_score 85)
[ "$status" = "healthy" ] && test_pass || test_fail "Got: $status"

# Test 13
test_start "Health status from score (degraded)"
status=$(get_health_status_from_score 65)
[ "$status" = "degraded" ] && test_pass || test_fail "Got: $status"

# Test 14
test_start "Health status from score (unhealthy)"
status=$(get_health_status_from_score 35)
[ "$status" = "unhealthy" ] && test_pass || test_fail "Got: $status"

# Test 15
test_start "Time since heartbeat"
emit_heartbeat "$TEST_WORKER_ID" "test" >/dev/null 2>&1
sleep 2
time_since=$(get_time_since_heartbeat "$TEST_WORKER_ID")
[ "$time_since" -ge 1 ] && [ "$time_since" -le 5 ] && test_pass || test_fail "Got: ${time_since}s"

# Test 16
test_start "Warning detection (65s old)"
old_time=$(date -v-65S +%Y-%m-%dT%H:%M:%S%z)
jq --arg t "$old_time" '.heartbeat.last_heartbeat = $t' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"
is_heartbeat_warning "$TEST_WORKER_ID" && test_pass || test_fail

# Test 17
test_start "Critical detection (125s old)"
old_time=$(date -v-125S +%Y-%m-%dT%H:%M:%S%z)
jq --arg t "$old_time" '.heartbeat.last_heartbeat = $t' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"
is_heartbeat_critical "$TEST_WORKER_ID" && test_pass || test_fail

# Test 18
test_start "Zombie detection (305s old)"
old_time=$(date -v-305S +%Y-%m-%dT%H:%M:%S%z)
jq --arg t "$old_time" '.heartbeat.last_heartbeat = $t' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"
is_heartbeat_zombie "$TEST_WORKER_ID" && test_pass || test_fail

# Test 19
test_start "Heartbeat resets missed count"
jq '.heartbeat.missed_count = 5' "$TEST_WORKER_SPEC" > "${TEST_WORKER_SPEC}.tmp"
mv "${TEST_WORKER_SPEC}.tmp" "$TEST_WORKER_SPEC"
emit_heartbeat "$TEST_WORKER_ID" "test" >/dev/null 2>&1
count=$(jq -r '.heartbeat.missed_count' "$TEST_WORKER_SPEC")
[ "$count" = "0" ] && test_pass || test_fail "Got: $count"

# Test 20
test_start "Health score includes in heartbeat"
emit_heartbeat "$TEST_WORKER_ID" "test" >/dev/null 2>&1
score=$(jq -r '.heartbeat.health.health_score' "$TEST_WORKER_SPEC")
[ -n "$score" ] && [ "$score" != "null" ] && test_pass || test_fail "Got: $score"

cleanup_test_env

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
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
