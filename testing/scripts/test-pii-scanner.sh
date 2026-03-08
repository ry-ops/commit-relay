#!/bin/bash
# testing/scripts/test-pii-scanner.sh
# Test suite for PII detection scanner
#
# Tests:
# - Email detection
# - SSN detection
# - Credit card detection
# - Phone number detection
# - API key detection
# - Redaction functionality
# - Risk level calculation
# - File scanning

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export COMMIT_RELAY_HOME

cd "$COMMIT_RELAY_HOME"

# Load PII scanner
source coordination/governance/lib/pii-scanner.sh

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

# Test 1: Email detection
test_email_detection() {
    local content="Contact me at john.doe@example.com for details"
    local result=$(scan_for_pii "$content" "test-email")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "email" ]
}

# Test 2: SSN detection
test_ssn_detection() {
    local content="My SSN is 123-45-6789"
    local result=$(scan_for_pii "$content" "test-ssn")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "ssn" ]
}

# Test 3: Credit card detection
test_credit_card_detection() {
    local content="Card number: 4532-1234-5678-9010"
    local result=$(scan_for_pii "$content" "test-card")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "credit_card" ]
}

# Test 4: Phone number detection
test_phone_detection() {
    local content="Call me at (555) 123-4567"
    local result=$(scan_for_pii "$content" "test-phone")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "phone" ]
}

# Test 5: API key detection
test_api_key_detection() {
    local content="API_KEY=sk_live_1234567890abcdefghij"
    local result=$(scan_for_pii "$content" "test-api-key")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "api_key" ]
}

# Test 6: AWS key detection
test_aws_key_detection() {
    local content="AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
    local result=$(scan_for_pii "$content" "test-aws")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "aws_key" ]
}

# Test 7: GitHub token detection
test_github_token_detection() {
    local content="GITHUB_TOKEN=ghp_1234567890abcdefghijklmnopqrstuvw"
    local result=$(scan_for_pii "$content" "test-github")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "github_token" ]
}

# Test 8: IP address detection
test_ip_detection() {
    local content="Server IP: 192.168.1.100"
    local result=$(scan_for_pii "$content" "test-ip")

    local has_pii=$(echo "$result" | jq -r '.has_pii')
    local finding_type=$(echo "$result" | jq -r '.findings[0].type // "none"')

    [ "$has_pii" = "true" ] && [ "$finding_type" = "ip_address" ]
}

# Test 9: No PII in clean content
test_no_pii_detection() {
    local content="This is a clean message with no sensitive data"
    local result=$(scan_for_pii "$content" "test-clean")

    local has_pii=$(echo "$result" | jq -r '.has_pii')

    [ "$has_pii" = "false" ]
}

# Test 10: Email redaction
test_email_redaction() {
    local content="Contact me at john.doe@example.com for details"
    local redacted=$(redact_pii "$content")

    echo "$redacted" | grep -q "\[EMAIL-REDACTED\]" && ! echo "$redacted" | grep -q "john.doe@example.com"
}

# Test 11: SSN redaction
test_ssn_redaction() {
    local content="My SSN is 123-45-6789"
    local redacted=$(redact_pii "$content")

    echo "$redacted" | grep -q "\[SSN-REDACTED\]" && ! echo "$redacted" | grep -q "123-45-6789"
}

# Test 12: API key redaction
test_api_key_redaction() {
    local content="API_KEY=sk_live_1234567890abcdefghij"
    local redacted=$(redact_pii "$content")

    echo "$redacted" | grep -q "\[API-KEY-REDACTED\]" && ! echo "$redacted" | grep -q "sk_live"
}

# Test 13: Risk level - high (multiple high-confidence findings)
test_high_risk_level() {
    local content="Email: test@example.com, SSN: 123-45-6789, Card: 4532-1234-5678-9010"
    local result=$(scan_for_pii "$content" "test-high-risk")

    local risk_level=$(echo "$result" | jq -r '.risk_level')

    [ "$risk_level" = "critical" ]
}

# Test 14: Risk level - medium (medium-confidence findings)
test_medium_risk_level() {
    local content="IP: 192.168.1.100, username: johndoe"
    local result=$(scan_for_pii "$content" "test-medium-risk")

    local risk_level=$(echo "$result" | jq -r '.risk_level')

    [ "$risk_level" = "medium" ] || [ "$risk_level" = "low" ]
}

# Test 15: Action required for high risk
test_action_required() {
    local content="Email: test@example.com, SSN: 123-45-6789, Card: 4532-1234-5678-9010"
    local result=$(scan_for_pii "$content" "test-action")

    local action_required=$(echo "$result" | jq -r '.action_required')

    [ "$action_required" = "true" ]
}

# Test 16: Multiple PII types detected
test_multiple_pii_types() {
    local content="Contact: john@example.com, Phone: 555-123-4567, IP: 192.168.1.1"
    local result=$(scan_for_pii "$content" "test-multiple")

    local findings_count=$(echo "$result" | jq '.findings | length')

    [ "$findings_count" -ge 3 ]
}

# Test 17: File scanning
test_file_scanning() {
    # Create test file with PII
    local test_file="/tmp/test-pii-content-$$.txt"
    echo "Email: test@example.com" > "$test_file"

    local result=$(scan_file_for_pii "$test_file")
    local has_pii=$(echo "$result" | jq -r '.has_pii')

    rm -f "$test_file"

    [ "$has_pii" = "true" ]
}

# Test 18: Content safety check
test_content_safety() {
    local safe_content="This is safe content"
    local unsafe_content="Email: test@example.com, SSN: 123-45-6789"

    is_content_safe "$safe_content" && ! is_content_safe "$unsafe_content"
}

# Header
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  PII Scanner Test Suite${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# Run all tests
run_test "Email detection" test_email_detection
run_test "SSN detection" test_ssn_detection
run_test "Credit card detection" test_credit_card_detection
run_test "Phone number detection" test_phone_detection
run_test "API key detection" test_api_key_detection
run_test "AWS key detection" test_aws_key_detection
run_test "GitHub token detection" test_github_token_detection
run_test "IP address detection" test_ip_detection
run_test "No PII in clean content" test_no_pii_detection
run_test "Email redaction" test_email_redaction
run_test "SSN redaction" test_ssn_redaction
run_test "API key redaction" test_api_key_redaction
run_test "High risk level calculation" test_high_risk_level
run_test "Medium risk level calculation" test_medium_risk_level
run_test "Action required for high risk" test_action_required
run_test "Multiple PII types detection" test_multiple_pii_types
run_test "File scanning" test_file_scanning
run_test "Content safety check" test_content_safety

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
    echo -e "${GREEN}PII scanner is working correctly${NC}"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo -e "${RED}PII scanner needs investigation${NC}"
    exit 1
fi
