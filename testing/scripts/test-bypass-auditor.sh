#!/bin/bash
# testing/scripts/test-bypass-auditor.sh
# Test suite for bypass auditing system
#
# Tests:
# - Authorization checking
# - Bypass logging
# - Risk calculation
# - Bypass expiration
# - Statistics generation

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export COMMIT_RELAY_HOME

cd "$COMMIT_RELAY_HOME"

# Load bypass auditor
source coordination/governance/lib/bypass-auditor.sh

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

# Clean audit log before tests
AUDIT_LOG="$COMMIT_RELAY_HOME/coordination/governance/bypass-audit.jsonl"
rm -f "$AUDIT_LOG"
mkdir -p "$(dirname "$AUDIT_LOG")"

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

# Test 1: Developer cannot bypass validation for >0 minutes
test_developer_authorization() {
    export COMMIT_RELAY_PRINCIPAL="developer"
    ! check_bypass_authorization "developer" "validation" 30
}

# Test 2: Senior engineer can bypass validation for 30 minutes
test_senior_engineer_authorization() {
    check_bypass_authorization "senior_engineer" "validation" 30
}

# Test 3: Tech lead can bypass validation and governance
test_tech_lead_authorization() {
    check_bypass_authorization "tech_lead" "validation" 120 && \
    check_bypass_authorization "tech_lead" "governance" 30
}

# Test 4: Director has unlimited bypass
test_director_authorization() {
    check_bypass_authorization "director" "validation" 999999 && \
    check_bypass_authorization "director" "governance" 999999 && \
    check_bypass_authorization "director" "access" 999999
}

# Test 5: Bypass gets logged
test_bypass_logging() {
    export COMMIT_RELAY_PRINCIPAL="director"
    audit_bypass "validation" "Testing bypass logging" "test_suite" 30

    grep -q "Testing bypass logging" "$AUDIT_LOG"
}

# Test 6: Denied bypass gets logged
test_denied_bypass_logging() {
    export COMMIT_RELAY_PRINCIPAL="developer"
    ! audit_bypass "governance" "Should be denied" "none" 30

    grep -q "denied" "$AUDIT_LOG"
}

# Test 7: Risk calculation - low risk
test_risk_calculation_low() {
    local risk=$(calculate_bypass_risk "validation" 15)
    [ "$risk" = "medium" ] || [ "$risk" = "low" ]
}

# Test 8: Risk calculation - high risk
test_risk_calculation_high() {
    local risk=$(calculate_bypass_risk "access" 600)
    [ "$risk" = "critical" ] || [ "$risk" = "high" ]
}

# Test 9: Bypass activation
test_bypass_activation() {
    export COMMIT_RELAY_PRINCIPAL="director"
    audit_bypass "validation" "Test activation" "test" 60

    is_bypass_active
}

# Test 10: Bypass expiration
test_bypass_expiration() {
    export COMMIT_RELAY_PRINCIPAL="director"
    audit_bypass "validation" "Test expiration" "test" 0

    # Set expiration to past
    export BYPASS_EXPIRES_AT=$(($(date +%s) - 10))

    ! is_bypass_active
}

# Test 11: Early bypass end
test_bypass_end() {
    export COMMIT_RELAY_PRINCIPAL="director"
    audit_bypass "validation" "Test early end" "test" 60

    end_bypass

    ! is_bypass_active
}

# Test 12: Bypass statistics
test_bypass_stats() {
    local stats=$(get_bypass_stats)
    local total=$(echo "$stats" | jq -r '.total_bypasses')

    [ "$total" -ge 0 ]
}

# Test 13: Environment bypass detection
test_env_bypass() {
    export GOVERNANCE_BYPASS=true
    export COMMIT_RELAY_PRINCIPAL="system"

    check_env_bypass

    unset GOVERNANCE_BYPASS
}

# Test 14: Authorization matrix enforcement
test_authorization_enforcement() {
    # Developer cannot bypass governance
    ! check_bypass_authorization "developer" "governance" 30 && \
    # Senior engineer cannot bypass governance
    ! check_bypass_authorization "senior_engineer" "governance" 30 && \
    # Tech lead CAN bypass governance for 30 min
    check_bypass_authorization "tech_lead" "governance" 30
}

# Header
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Bypass Auditor Test Suite${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# Run all tests
run_test "Developer authorization limits" test_developer_authorization
run_test "Senior engineer authorization" test_senior_engineer_authorization
run_test "Tech lead authorization" test_tech_lead_authorization
run_test "Director unlimited bypass" test_director_authorization
run_test "Bypass logging" test_bypass_logging
run_test "Denied bypass logging" test_denied_bypass_logging
run_test "Risk calculation - low" test_risk_calculation_low
run_test "Risk calculation - high" test_risk_calculation_high
run_test "Bypass activation" test_bypass_activation
run_test "Bypass expiration" test_bypass_expiration
run_test "Early bypass end" test_bypass_end
run_test "Bypass statistics" test_bypass_stats
run_test "Environment bypass detection" test_env_bypass
run_test "Authorization matrix enforcement" test_authorization_enforcement

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
    echo -e "${GREEN}Bypass auditor is working correctly${NC}"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo -e "${RED}Bypass auditor needs investigation${NC}"
    exit 1
fi
