#!/bin/bash
# testing/unit/auto-fix.test.sh
# Unit tests for Auto-Fix Framework
# Phase 4.5 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/auto-fix.sh"

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
    mkdir -p "$COMMIT_RELAY_HOME/coordination/auto-fix"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/patterns"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/events"
    mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/templates"

    # Backup existing files
    [ -f "$FIX_HISTORY_FILE" ] && mv "$FIX_HISTORY_FILE" "${FIX_HISTORY_FILE}.backup"
    [ -f "$FIX_STATE_FILE" ] && mv "$FIX_STATE_FILE" "${FIX_STATE_FILE}.backup"
    [ -f "$PATTERN_DB" ] && mv "$PATTERN_DB" "${PATTERN_DB}.backup"

    # Create test pattern
    cat > "$PATTERN_DB" <<'EOFPATTERN'
{"pattern_id":"test_pattern_oom","category":"resource","type":"out_of_memory","signature":{"event_type":"zombie_detected","worker_type":"scan-worker","error_code":"OOM_KILLED"},"frequency":{"total_occurrences":5,"last_24h":3},"confidence":0.95,"severity":"high","created_at":"2025-11-18T10:00:00-0600","updated_at":"2025-11-18T15:00:00-0600"}
{"pattern_id":"test_pattern_timeout","category":"systemic","type":"timeout","signature":{"event_type":"task_timeout","worker_type":"implementation-worker"},"frequency":{"total_occurrences":4,"last_24h":4},"confidence":0.88,"severity":"medium","created_at":"2025-11-18T12:00:00-0600","updated_at":"2025-11-18T15:30:00-0600"}
EOFPATTERN

    # Create test worker spec
    cat > "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json" <<'EOFSPEC'
{
  "worker_type": "scan-worker",
  "resources": {
    "memory_limit_mb": 2048,
    "cpu_limit": 1.0
  },
  "timeouts": {
    "task_timeout_seconds": 1800
  },
  "heartbeat": {
    "interval_seconds": 60,
    "timeout_seconds": 180
  }
}
EOFSPEC
}

cleanup_test_env() {
    # Remove test files
    rm -f "$FIX_HISTORY_FILE" "$FIX_STATE_FILE" "$FIX_EVENTS_LOG"
    rm -f "$PATTERN_DB"
    rm -f "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json"
    rm -f "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json.backup."*

    # Restore backups
    [ -f "${FIX_HISTORY_FILE}.backup" ] && mv "${FIX_HISTORY_FILE}.backup" "$FIX_HISTORY_FILE"
    [ -f "${FIX_STATE_FILE}.backup" ] && mv "${FIX_STATE_FILE}.backup" "$FIX_STATE_FILE"
    [ -f "${PATTERN_DB}.backup" ] && mv "${PATTERN_DB}.backup" "$PATTERN_DB"
}

echo ""
echo "==========================================="
echo "  Auto-Fix Framework Unit Tests"
echo "==========================================="
echo ""

setup_test_env

# Test 1
test_start "Auto-fix library loads"
if [ -f "$COMMIT_RELAY_HOME/scripts/lib/auto-fix.sh" ]; then
    test_pass
else
    test_fail "Library file not found"
fi

# Test 2
test_start "Fix registry file exists and is valid"
if [ -f "$FIX_REGISTRY_FILE" ] && jq empty "$FIX_REGISTRY_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Registry file invalid or missing"
fi

# Test 3
test_start "Fix policy file exists and is valid"
if [ -f "$FIX_POLICY_FILE" ] && jq empty "$FIX_POLICY_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Policy file invalid or missing"
fi

# Test 4
test_start "load_fix_registry returns valid JSON"
registry=$(load_fix_registry 2>/dev/null)
if echo "$registry" | jq empty 2>/dev/null; then
    test_pass
else
    test_fail "Registry loading failed"
fi

# Test 5
test_start "get_fix_by_id retrieves fix"
fix=$(get_fix_by_id "fix_increase_memory_for_oom" 2>/dev/null || echo "")
if [ -n "$fix" ] && echo "$fix" | jq -e '.fix_id == "fix_increase_memory_for_oom"' >/dev/null 2>&1; then
    test_pass
else
    test_fail "Fix retrieval failed"
fi

# Test 6
test_start "match_fixes_for_pattern finds matching fixes"
matches=$(match_fixes_for_pattern "test_pattern_oom" 2>/dev/null || echo "[]")
match_count=$(echo "$matches" | jq 'length')

if [ "$match_count" -ge 1 ]; then
    test_pass
else
    test_fail "Expected >= 1 match, got: $match_count"
fi

# Test 7
test_start "validate_fix_safety returns safety assessment"
safety=$(validate_fix_safety "fix_increase_memory_for_oom" "test_pattern_oom" 2>/dev/null || echo "")

if echo "$safety" | jq -e '.safety_score' >/dev/null 2>&1; then
    test_pass
else
    test_fail "Safety validation failed"
fi

# Test 8
test_start "validate_fix_safety marks high safety fixes as auto-apply"
safety=$(validate_fix_safety "fix_increase_memory_for_oom" "test_pattern_oom" 2>/dev/null)
can_auto=$(echo "$safety" | jq -r '.can_auto_apply')

if [ "$can_auto" = "true" ]; then
    test_pass
else
    test_fail "High safety fix not marked for auto-apply: $can_auto"
fi

# Test 9
test_start "check_fix_prerequisites validates pattern confidence"
if check_fix_prerequisites "fix_increase_memory_for_oom" "test_pattern_oom" 2>/dev/null; then
    test_pass
else
    test_fail "Prerequisites check failed"
fi

# Test 10
test_start "check_rate_limits allows fixes within limits"
if check_rate_limits "fix_increase_memory_for_oom" "resource" "scan-worker" 2>/dev/null; then
    test_pass
else
    test_fail "Rate limit check failed unexpectedly"
fi

# Test 11
test_start "execute_fix_action modifies worker spec"
action='{"type":"modify_worker_spec","field":"resources.memory_limit_mb","operation":"multiply","value":1.5,"max_value":8192}'
context='{"worker_type":"scan-worker","pattern_id":"test_pattern_oom"}'

backup=$(execute_fix_action "$action" "$context" 2>/dev/null || echo "")

if [ -n "$backup" ] && [ -f "$backup" ]; then
    # Check if spec was modified
    new_value=$(jq -r '.resources.memory_limit_mb' "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json")
    # Convert to integer for comparison (handles floating point from bc)
    new_value_int=$(echo "$new_value" | cut -d. -f1)
    if [ "$new_value_int" = "3072" ]; then
        test_pass
    else
        test_fail "Spec not modified correctly: $new_value != 3072"
    fi
else
    test_fail "Action execution failed, no backup created"
fi

# Test 12
test_start "execute_fix creates history entry"
# Reset spec first
cp "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json.backup."* \
   "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json" 2>/dev/null || true

backup_info=$(execute_fix "fix_increase_memory_for_oom" "test_pattern_oom" 2>/dev/null || echo "[]")

if grep -q "fix_increase_memory_for_oom" "$FIX_HISTORY_FILE" 2>/dev/null; then
    test_pass
else
    test_fail "Fix not recorded in history"
fi

# Test 13
test_start "rollback_fix restores previous configuration"
if [ -n "$backup_info" ] && [ "$backup_info" != "[]" ]; then
    rollback_fix "fix_increase_memory_for_oom" "$backup_info" 2>/dev/null

    restored_value=$(jq -r '.resources.memory_limit_mb' "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json")
    if [ "$restored_value" = "2048" ]; then
        test_pass
    else
        test_fail "Rollback failed: $restored_value != 2048"
    fi
else
    test_fail "No backup info available for rollback"
fi

# Test 14
test_start "emit_fix_event creates event log"
emit_fix_event "test_event" "test_fix_001" '{"test": true}' 2>/dev/null

if [ -f "$FIX_EVENTS_LOG" ] && grep -q "test_event" "$FIX_EVENTS_LOG"; then
    test_pass
else
    test_fail "Event not logged"
fi

# Test 15
test_start "apply_auto_fix runs end-to-end"
# Reset environment
rm -f "$FIX_HISTORY_FILE"
cp "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json.backup."* \
   "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json" 2>/dev/null || true

applied_fix=$(apply_auto_fix "test_pattern_oom" 2>&1 || echo "")

if [[ "$applied_fix" =~ fix_ ]]; then
    test_pass
else
    test_fail "Auto-fix application failed: $applied_fix"
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
