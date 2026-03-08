#!/bin/bash
# Test Suite for JSON Validation and Repair Utilities
# Tests both bash and Node.js implementations

set -e

# Get project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the validator
source "$COMMIT_RELAY_HOME/scripts/lib/json-validator.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
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
    if [ -n "${1:-}" ]; then
        echo "  Error: $1"
    fi
}

# Test 1: Valid JSON should pass validation
test_start "Valid JSON passes validation"
VALID_JSON='{"id":"test-001","data":"value"}'
if validate_json "$VALID_JSON"; then
    test_pass
else
    test_fail "Valid JSON rejected"
fi

# Test 2: Invalid JSON should fail validation
test_start "Invalid JSON fails validation"
INVALID_JSON='{"id":"test-001","data":"value"'
if ! validate_json "$INVALID_JSON"; then
    test_pass
else
    test_fail "Invalid JSON accepted"
fi

# Test 3: Trailing comma repair
test_start "Repair trailing comma"
JSON_TRAILING_COMMA='{"id":"test-001","data":"value",}'
if result=$(validate_and_repair_json "$JSON_TRAILING_COMMA" 1); then
    if validate_json "$result"; then
        test_pass
    else
        test_fail "Repaired JSON still invalid"
    fi
else
    test_fail "Repair failed"
fi

# Test 4: Missing comma between objects
test_start "Repair missing comma between objects"
JSON_MISSING_COMMA='{"a":1}{"b":2}'
if result=$(validate_and_repair_json "$JSON_MISSING_COMMA" 1); then
    if validate_json "$result"; then
        test_pass
    else
        test_fail "Repaired JSON still invalid"
    fi
else
    test_fail "Repair failed"
fi

# Test 5: Unclosed brace repair
test_start "Repair unclosed brace"
JSON_UNCLOSED='{"id":"test-001","data":"value"'
if result=$(validate_and_repair_json "$JSON_UNCLOSED" 1); then
    if validate_json "$result"; then
        test_pass
    else
        test_fail "Repaired JSON still invalid"
    fi
else
    test_fail "Repair failed"
fi

# Test 6: Unclosed bracket repair
test_start "Repair unclosed bracket"
JSON_UNCLOSED_BRACKET='{"ids":["a","b","c"'
if result=$(validate_and_repair_json "$JSON_UNCLOSED_BRACKET" 1); then
    if validate_json "$result"; then
        test_pass
    else
        test_fail "Repaired JSON still invalid"
    fi
else
    test_fail "Repair failed"
fi

# Test 7: Multiple issues
test_start "Repair multiple issues (trailing comma + unclosed brace)"
JSON_MULTIPLE='{"id":"test-001","data":"value","nested":{"x":1,}'
if result=$(validate_and_repair_json "$JSON_MULTIPLE" 1); then
    if validate_json "$result"; then
        test_pass
    else
        test_fail "Repaired JSON still invalid"
    fi
else
    test_fail "Repair failed"
fi

# Test 8: JSONL file validation (create test file)
test_start "JSONL file validation"
TEST_JSONL="$COMMIT_RELAY_HOME/testing/test-events.jsonl"
cat > "$TEST_JSONL" <<EOF
{"id":"evt-1","type":"test","data":"valid"}
{"id":"evt-2","type":"test","data":"valid"}
{"id":"evt-3","type":"test","data":"valid"}
EOF

if validate_jsonl_file "$TEST_JSONL" 0; then
    test_pass
else
    test_fail "Valid JSONL file rejected"
fi

# Test 9: JSONL file with errors
test_start "JSONL file with errors detected"
cat > "$TEST_JSONL" <<EOF
{"id":"evt-1","type":"test","data":"valid"}
{"id":"evt-2","type":"test","data":"invalid",}
{"id":"evt-3","type":"test","data":"valid"
EOF

if ! validate_jsonl_file "$TEST_JSONL" 0; then
    test_pass
else
    test_fail "Invalid JSONL file accepted"
fi

# Test 10: JSONL file repair
test_start "JSONL file repair"
if repair_jsonl_file "$TEST_JSONL" 0; then
    if validate_jsonl_file "$TEST_JSONL" 0; then
        test_pass
    else
        test_fail "Repaired file still invalid"
    fi
else
    test_fail "File repair failed"
fi

# Cleanup
rm -f "$TEST_JSONL"
rm -f "$TEST_JSONL.backup"*

# Test 11: Node.js validator - Valid JSON
test_start "Node.js validator - Valid JSON"
NODE_TEST_RESULT=$(node -e "
const validator = require('$COMMIT_RELAY_HOME/dashboard/server/utils/json-validator.js');
const result = validator.validateAndRepairJSON('{\"id\":\"test\",\"data\":\"value\"}');
console.log(result.success);
")
if [ "$NODE_TEST_RESULT" = "true" ]; then
    test_pass
else
    test_fail "Node.js validator failed on valid JSON"
fi

# Test 12: Node.js validator - Repair trailing comma
test_start "Node.js validator - Repair trailing comma"
NODE_TEST_RESULT=$(node -e "
const validator = require('$COMMIT_RELAY_HOME/dashboard/server/utils/json-validator.js');
const result = validator.validateAndRepairJSON('{\"id\":\"test\",\"data\":\"value\",}');
console.log(result.success);
")
if [ "$NODE_TEST_RESULT" = "true" ]; then
    test_pass
else
    test_fail "Node.js validator failed to repair trailing comma"
fi

# Test 13: Node.js validator - Repair unclosed brace
test_start "Node.js validator - Repair unclosed brace"
NODE_TEST_RESULT=$(node -e "
const validator = require('$COMMIT_RELAY_HOME/dashboard/server/utils/json-validator.js');
const result = validator.validateAndRepairJSON('{\"id\":\"test\",\"data\":\"value\"');
console.log(result.success);
")
if [ "$NODE_TEST_RESULT" = "true" ]; then
    test_pass
else
    test_fail "Node.js validator failed to repair unclosed brace"
fi

# Test 14: Node.js safeWriteJSON
test_start "Node.js safeWriteJSON"
TEST_FILE="$COMMIT_RELAY_HOME/testing/test-safe-write.jsonl"
NODE_TEST_RESULT=$(node -e "
const validator = require('$COMMIT_RELAY_HOME/dashboard/server/utils/json-validator.js');
const result = validator.safeWriteJSON('$TEST_FILE', {id: 'test', data: 'value'}, false);
console.log(result.success);
")
if [ "$NODE_TEST_RESULT" = "true" ] && [ -f "$TEST_FILE" ]; then
    test_pass
    rm -f "$TEST_FILE"
else
    test_fail "Node.js safeWriteJSON failed"
fi

# Test 15: emit-event.sh integration
test_start "emit-event.sh with valid data"
if "$COMMIT_RELAY_HOME/scripts/emit-event.sh" test_event '{"test":"data"}' test-suite 2>/dev/null; then
    test_pass
else
    test_fail "emit-event.sh failed with valid data"
fi

# Test 16: Complex nested JSON
test_start "Complex nested JSON validation"
COMPLEX_JSON='{"id":"test","nested":{"level1":{"level2":{"level3":"value"}}},"array":[1,2,3]}'
if validate_json "$COMPLEX_JSON"; then
    test_pass
else
    test_fail "Complex JSON rejected"
fi

# Test 17: Real-world dashboard event structure
test_start "Dashboard event structure validation"
DASHBOARD_EVENT=$(cat <<EOF
{
  "id": "evt-1762553454-12345",
  "timestamp": "2025-11-11T14:00:00Z",
  "type": "task_created",
  "data": {
    "task_id": "task-001",
    "title": "Test Task",
    "priority": "high"
  },
  "source": "coordinator"
}
EOF
)
if validate_json "$DASHBOARD_EVENT"; then
    test_pass
else
    test_fail "Dashboard event structure rejected"
fi

# Test 18: Known problematic pattern from dashboard-events.jsonl
test_start "Known problematic pattern (missing comma)"
PROBLEMATIC_PATTERN=$(cat <<EOF
{
  "id": "evt-1762720028-82705",
  "timestamp": "2025-11-09T14:27:08-0600",
  "type": "moe_pool_updated",
  "data": {"current_workers":1,"target_workers":8}},
  "source": "sparse-pool-manager"
}
EOF
)
if result=$(validate_and_repair_json "$PROBLEMATIC_PATTERN" 1); then
    if validate_json "$result"; then
        test_pass
    else
        test_fail "Could not repair problematic pattern"
    fi
else
    test_fail "Repair failed on problematic pattern"
fi

# Print summary
echo ""
echo "================================"
echo "Test Summary"
echo "================================"
echo "Total tests: $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
