#!/bin/bash
# testing/integration/moe-router.test.sh
# Integration tests for MoE Router
# Validates routing logic, confidence scoring, and JSON output format

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

ROUTER="$COMMIT_RELAY_HOME/coordination/masters/coordinator/lib/moe-router.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

echo ""
echo "==========================================="
echo "  MoE Router Integration Tests"
echo "==========================================="
echo ""

# Test 1: Router script exists and is executable
test_start "Router script exists and is executable"
if [ -x "$ROUTER" ]; then
    test_pass
else
    test_fail "Router not found or not executable at $ROUTER"
fi

# Test 2: Router returns valid JSON
test_start "Router returns valid JSON"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-test-001 "Fix bug in authentication" 2>/dev/null)
if echo "$RESULT" | jq empty 2>/dev/null; then
    test_pass
else
    test_fail "Router output is not valid JSON"
fi

# Test 3: JSON has required fields
test_start "JSON output has required top-level fields"
TASK_ID=$(echo "$RESULT" | jq -r '.task_id' 2>/dev/null)
TIMESTAMP=$(echo "$RESULT" | jq -r '.timestamp' 2>/dev/null)
STRATEGY=$(echo "$RESULT" | jq -r '.routing_strategy' 2>/dev/null)
DECISION=$(echo "$RESULT" | jq -r '.decision' 2>/dev/null)

if [ "$TASK_ID" != "null" ] && [ "$TIMESTAMP" != "null" ] && \
   [ "$STRATEGY" != "null" ] && [ "$DECISION" != "null" ]; then
    test_pass
else
    test_fail "Missing required top-level fields"
fi

# Test 4: Decision object has primary_expert field
test_start "Decision object has primary_expert field"
PRIMARY_EXPERT=$(echo "$RESULT" | jq -r '.decision.primary_expert' 2>/dev/null)
if [ "$PRIMARY_EXPERT" != "null" ] && [ -n "$PRIMARY_EXPERT" ]; then
    test_pass
else
    test_fail "Missing or null primary_expert field"
fi

# Test 5: Decision object has primary_confidence field
test_start "Decision object has primary_confidence field"
PRIMARY_CONF=$(echo "$RESULT" | jq -r '.decision.primary_confidence' 2>/dev/null)
if [ "$PRIMARY_CONF" != "null" ] && [ -n "$PRIMARY_CONF" ]; then
    test_pass
else
    test_fail "Missing or null primary_confidence field"
fi

# Test 6: Decision object has scores for all experts
test_start "Decision object has scores for all experts"
DEV_SCORE=$(echo "$RESULT" | jq -r '.decision.scores.development' 2>/dev/null)
SEC_SCORE=$(echo "$RESULT" | jq -r '.decision.scores.security' 2>/dev/null)
INV_SCORE=$(echo "$RESULT" | jq -r '.decision.scores.inventory' 2>/dev/null)

if [ "$DEV_SCORE" != "null" ] && [ "$SEC_SCORE" != "null" ] && [ "$INV_SCORE" != "null" ]; then
    test_pass
else
    test_fail "Missing expert scores"
fi

# Test 7: Development task routes to development
test_start "Development task routes to development"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-dev-001 "Fix bug in user authentication causing login failures" 2>/dev/null)
ROUTED_EXPERT=$(echo "$RESULT" | jq -r '.decision.primary_expert' 2>/dev/null)
if [ "$ROUTED_EXPERT" = "development" ]; then
    test_pass
else
    test_fail "Got: $ROUTED_EXPERT, expected: development"
fi

# Test 8: Security task routes to security
test_start "Security task routes to security"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-sec-001 "Scan repository for CVE-2024-12345 vulnerability" 2>/dev/null)
ROUTED_EXPERT=$(echo "$RESULT" | jq -r '.decision.primary_expert' 2>/dev/null)
if [ "$ROUTED_EXPERT" = "security" ]; then
    test_pass
else
    test_fail "Got: $ROUTED_EXPERT, expected: security"
fi

# Test 9: Inventory task routes to inventory
test_start "Inventory task routes to inventory"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-inv-001 "Document all repositories with dependency versions" 2>/dev/null)
ROUTED_EXPERT=$(echo "$RESULT" | jq -r '.decision.primary_expert' 2>/dev/null)
if [ "$ROUTED_EXPERT" = "inventory" ]; then
    test_pass
else
    test_fail "Got: $ROUTED_EXPERT, expected: inventory"
fi

# Test 10: Feature implementation routes to development
test_start "Feature implementation routes to development"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-feat-001 "Implement new API endpoint for user management" 2>/dev/null)
ROUTED_EXPERT=$(echo "$RESULT" | jq -r '.decision.primary_expert' 2>/dev/null)
if [ "$ROUTED_EXPERT" = "development" ]; then
    test_pass
else
    test_fail "Got: $ROUTED_EXPERT, expected: development"
fi

# Test 11: Security audit routes to security
test_start "Security audit routes to security"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-audit-001 "Comprehensive security audit with vulnerability scanning" 2>/dev/null)
ROUTED_EXPERT=$(echo "$RESULT" | jq -r '.decision.primary_expert' 2>/dev/null)
if [ "$ROUTED_EXPERT" = "security" ]; then
    test_pass
else
    test_fail "Got: $ROUTED_EXPERT, expected: security"
fi

# Test 12: Confidence scores are in valid range (0.0-1.0)
test_start "Confidence scores are in valid range"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-conf-001 "Fix authentication bug" 2>/dev/null)
PRIMARY_CONF=$(echo "$RESULT" | jq -r '.decision.primary_confidence' 2>/dev/null)

if (( $(echo "$PRIMARY_CONF >= 0.0 && $PRIMARY_CONF <= 1.0" | bc -l) )); then
    test_pass
else
    test_fail "Confidence $PRIMARY_CONF not in range [0.0, 1.0]"
fi

# Test 13: High-confidence task has confidence >= 0.7
test_start "High-confidence task has confidence >= 0.7"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" task-highconf-001 "Fix critical security vulnerability CVE-2024-999 in authentication" 2>/dev/null)
PRIMARY_CONF=$(echo "$RESULT" | jq -r '.decision.primary_confidence' 2>/dev/null)

if (( $(echo "$PRIMARY_CONF >= 0.7" | bc -l) )); then
    test_pass
else
    test_fail "Confidence $PRIMARY_CONF < 0.7 for high-confidence task"
fi

# Test 14: Task ID is preserved in routing decision
test_start "Task ID is preserved in routing decision"
TEST_TASK_ID="task-preserve-test-$(date +%s)"
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" "$TEST_TASK_ID" "Test task" 2>/dev/null)
RESULT_TASK_ID=$(echo "$RESULT" | jq -r '.task_id' 2>/dev/null)

if [ "$RESULT_TASK_ID" = "$TEST_TASK_ID" ]; then
    test_pass
else
    test_fail "Task ID mismatch: got $RESULT_TASK_ID, expected $TEST_TASK_ID"
fi

# Test 15: Routing decision is logged to JSONL file
test_start "Routing decision is logged to JSONL file"
ROUTING_LOG="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl"
BEFORE_COUNT=$(wc -l < "$ROUTING_LOG" 2>/dev/null || echo 0)
RESULT=$(GOVERNANCE_BYPASS=true "$ROUTER" "task-log-test-$(date +%s)" "Test logging" 2>/dev/null)
sleep 1
AFTER_COUNT=$(wc -l < "$ROUTING_LOG" 2>/dev/null || echo 0)

if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
    test_pass
else
    test_fail "Routing decision not logged (before: $BEFORE_COUNT, after: $AFTER_COUNT)"
fi

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
