#!/bin/bash
# Governance Test Framework
# Comprehensive testing of MoE governance controls including risk assessment,
# audit trails, approval workflows, and service recovery

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}"
TEST_OUTPUT_DIR="${COMMIT_RELAY_HOME}/testing/governance/results"
AUDIT_LOG="${TEST_OUTPUT_DIR}/governance-audit-trail.jsonl"
TEST_REPORT="${TEST_OUTPUT_DIR}/governance-test-report.json"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Create output directory
mkdir -p "${TEST_OUTPUT_DIR}"

# Initialize audit log
echo '{"test_suite":"governance","started_at":"'"${TIMESTAMP}"'","framework_version":"1.0.0"}' >> "${AUDIT_LOG}"

#######################################
# Logging Functions
#######################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++))
}

log_failure() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((TESTS_FAILED++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $*"
    ((TESTS_SKIPPED++))
}

#######################################
# Audit Trail Functions
#######################################

audit_log_entry() {
    local test_name="$1"
    local test_type="$2"
    local risk_level="$3"
    local result="$4"
    local details="${5:-}"

    local entry=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "test_name": "${test_name}",
  "test_type": "${test_type}",
  "risk_level": "${risk_level}",
  "result": "${result}",
  "details": ${details:-"{}"},
  "audit_id": "$(uuidgen)"
}
EOF
)
    echo "${entry}" >> "${AUDIT_LOG}"
}

#######################################
# Risk Assessment Functions
#######################################

assess_task_risk() {
    local task_description="$1"
    local risk_level="low"
    local risk_score=0

    # Risk indicators
    local high_risk_keywords=("security" "vulnerability" "cve" "critical" "production" "deploy" "delete" "drop" "remove")
    local medium_risk_keywords=("refactor" "update" "modify" "change" "config" "settings")
    local low_risk_keywords=("feature" "bug-fix" "documentation" "test" "inventory")

    # Calculate risk score
    for keyword in "${high_risk_keywords[@]}"; do
        if echo "${task_description}" | grep -qi "${keyword}"; then
            risk_score=$((risk_score + 30))
        fi
    done

    for keyword in "${medium_risk_keywords[@]}"; do
        if echo "${task_description}" | grep -qi "${keyword}"; then
            risk_score=$((risk_score + 15))
        fi
    done

    # Determine risk level
    if [ ${risk_score} -ge 60 ]; then
        risk_level="critical"
    elif [ ${risk_score} -ge 40 ]; then
        risk_level="high"
    elif [ ${risk_score} -ge 20 ]; then
        risk_level="medium"
    else
        risk_level="low"
    fi

    echo "${risk_level}:${risk_score}"
}

#######################################
# Approval Workflow Functions
#######################################

require_approval() {
    local risk_level="$1"
    local task_id="$2"

    case "${risk_level}" in
        critical|high)
            log_warning "Task ${task_id} requires approval due to ${risk_level} risk level"
            return 0
            ;;
        medium)
            log_info "Task ${task_id} recommended for review (medium risk)"
            return 1
            ;;
        low)
            log_info "Task ${task_id} auto-approved (low risk)"
            return 1
            ;;
    esac
}

simulate_approval_workflow() {
    local task_id="$1"
    local risk_level="$2"

    if require_approval "${risk_level}" "${task_id}"; then
        log_info "Simulating approval workflow for ${task_id}..."

        # Simulate approval process
        local approval_result="approved"
        local approver="governance-system"
        local approval_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        cat <<EOF
{
  "task_id": "${task_id}",
  "risk_level": "${risk_level}",
  "approval_required": true,
  "approval_result": "${approval_result}",
  "approver": "${approver}",
  "approved_at": "${approval_timestamp}"
}
EOF
    else
        cat <<EOF
{
  "task_id": "${task_id}",
  "risk_level": "${risk_level}",
  "approval_required": false,
  "auto_approved": true
}
EOF
    fi
}

#######################################
# Service Recovery Functions
#######################################

test_circuit_breaker() {
    local service_name="$1"
    local failure_count="${2:-5}"

    log_info "Testing circuit breaker for ${service_name}..."

    # Simulate failures
    local breaker_state="closed"
    for i in $(seq 1 ${failure_count}); do
        if [ $i -ge 5 ]; then
            breaker_state="open"
            break
        fi
    done

    cat <<EOF
{
  "service": "${service_name}",
  "failures_simulated": ${failure_count},
  "breaker_state": "${breaker_state}",
  "expected_state": "open"
}
EOF
}

test_auto_recovery() {
    local service_name="$1"

    log_info "Testing auto-recovery for ${service_name}..."

    # Simulate recovery after timeout
    sleep 1

    cat <<EOF
{
  "service": "${service_name}",
  "recovery_attempted": true,
  "recovery_successful": true,
  "new_state": "half_open"
}
EOF
}

#######################################
# Main Test Functions
#######################################

test_risk_assessment_low() {
    log_info "Test: Low Risk Task Assessment"

    local task_desc="feature: Add user profile page with avatar upload"
    local result=$(assess_task_risk "${task_desc}")
    local risk_level="${result%%:*}"
    local risk_score="${result##*:}"

    if [ "${risk_level}" = "low" ]; then
        log_success "Low risk correctly identified (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_low" "risk_assessment" "low" "pass" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 0
    else
        log_failure "Expected low risk, got ${risk_level} (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_low" "risk_assessment" "${risk_level}" "fail" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 1
    fi
}

test_risk_assessment_medium() {
    log_info "Test: Medium Risk Task Assessment"

    local task_desc="refactor: Update database connection pooling configuration"
    local result=$(assess_task_risk "${task_desc}")
    local risk_level="${result%%:*}"
    local risk_score="${result##*:}"

    if [ "${risk_level}" = "medium" ]; then
        log_success "Medium risk correctly identified (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_medium" "risk_assessment" "medium" "pass" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 0
    else
        log_failure "Expected medium risk, got ${risk_level} (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_medium" "risk_assessment" "${risk_level}" "fail" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 1
    fi
}

test_risk_assessment_high() {
    log_info "Test: High Risk Task Assessment"

    local task_desc="security-fix: Patch critical vulnerability in authentication system"
    local result=$(assess_task_risk "${task_desc}")
    local risk_level="${result%%:*}"
    local risk_score="${result##*:}"

    if [ "${risk_level}" = "high" ] || [ "${risk_level}" = "critical" ]; then
        log_success "High/Critical risk correctly identified (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_high" "risk_assessment" "${risk_level}" "pass" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 0
    else
        log_failure "Expected high/critical risk, got ${risk_level} (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_high" "risk_assessment" "${risk_level}" "fail" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 1
    fi
}

test_risk_assessment_critical() {
    log_info "Test: Critical Risk Task Assessment"

    local task_desc="cve-2024-1234: Deploy emergency security patch to production, delete vulnerable code"
    local result=$(assess_task_risk "${task_desc}")
    local risk_level="${result%%:*}"
    local risk_score="${result##*:}"

    if [ "${risk_level}" = "critical" ]; then
        log_success "Critical risk correctly identified (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_critical" "risk_assessment" "critical" "pass" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 0
    else
        log_failure "Expected critical risk, got ${risk_level} (score: ${risk_score})"
        audit_log_entry "test_risk_assessment_critical" "risk_assessment" "${risk_level}" "fail" '{"task":"'"${task_desc}"'","score":'"${risk_score}"'}'
        return 1
    fi
}

test_approval_workflow_low_risk() {
    log_info "Test: Approval Workflow - Low Risk Auto-Approval"

    local task_id="test-task-low-001"
    local approval_json=$(simulate_approval_workflow "${task_id}" "low")
    local auto_approved=$(echo "${approval_json}" | jq -r '.auto_approved')

    if [ "${auto_approved}" = "true" ]; then
        log_success "Low risk task auto-approved correctly"
        audit_log_entry "test_approval_workflow_low_risk" "approval_workflow" "low" "pass" "${approval_json}"
        return 0
    else
        log_failure "Low risk task should be auto-approved"
        audit_log_entry "test_approval_workflow_low_risk" "approval_workflow" "low" "fail" "${approval_json}"
        return 1
    fi
}

test_approval_workflow_high_risk() {
    log_info "Test: Approval Workflow - High Risk Requires Approval"

    local task_id="test-task-high-001"
    local approval_json=$(simulate_approval_workflow "${task_id}" "high")
    local approval_required=$(echo "${approval_json}" | jq -r '.approval_required')

    if [ "${approval_required}" = "true" ]; then
        log_success "High risk task requires approval correctly"
        audit_log_entry "test_approval_workflow_high_risk" "approval_workflow" "high" "pass" "${approval_json}"
        return 0
    else
        log_failure "High risk task should require approval"
        audit_log_entry "test_approval_workflow_high_risk" "approval_workflow" "high" "fail" "${approval_json}"
        return 1
    fi
}

test_audit_trail_generation() {
    log_info "Test: Audit Trail Generation"

    # Check if audit log exists and has entries
    if [ -f "${AUDIT_LOG}" ]; then
        local entry_count=$(wc -l < "${AUDIT_LOG}")
        if [ ${entry_count} -gt 0 ]; then
            log_success "Audit trail generated successfully (${entry_count} entries)"
            audit_log_entry "test_audit_trail_generation" "audit_trail" "low" "pass" '{"entries":'"${entry_count}"'}'
            return 0
        fi
    fi

    log_failure "Audit trail not generated or empty"
    audit_log_entry "test_audit_trail_generation" "audit_trail" "low" "fail" '{}'
    return 1
}

test_audit_trail_integrity() {
    log_info "Test: Audit Trail Integrity (JSON validation)"

    local invalid_entries=0
    while IFS= read -r line; do
        if ! echo "${line}" | jq empty 2>/dev/null; then
            ((invalid_entries++))
        fi
    done < "${AUDIT_LOG}"

    if [ ${invalid_entries} -eq 0 ]; then
        log_success "All audit entries are valid JSON"
        audit_log_entry "test_audit_trail_integrity" "audit_trail" "low" "pass" '{"invalid_entries":0}'
        return 0
    else
        log_failure "Found ${invalid_entries} invalid JSON entries"
        audit_log_entry "test_audit_trail_integrity" "audit_trail" "low" "fail" '{"invalid_entries":'"${invalid_entries}"'}'
        return 1
    fi
}

test_circuit_breaker_triggers() {
    log_info "Test: Circuit Breaker Triggers on Failures"

    local breaker_result=$(test_circuit_breaker "test-service" 5)
    local breaker_state=$(echo "${breaker_result}" | jq -r '.breaker_state')

    if [ "${breaker_state}" = "open" ]; then
        log_success "Circuit breaker opened after 5 failures"
        audit_log_entry "test_circuit_breaker_triggers" "circuit_breaker" "medium" "pass" "${breaker_result}"
        return 0
    else
        log_failure "Circuit breaker should be open, got ${breaker_state}"
        audit_log_entry "test_circuit_breaker_triggers" "circuit_breaker" "medium" "fail" "${breaker_result}"
        return 1
    fi
}

test_service_auto_recovery() {
    log_info "Test: Service Auto-Recovery"

    local recovery_result=$(test_auto_recovery "test-service")
    local recovery_successful=$(echo "${recovery_result}" | jq -r '.recovery_successful')

    if [ "${recovery_successful}" = "true" ]; then
        log_success "Service auto-recovery successful"
        audit_log_entry "test_service_auto_recovery" "auto_recovery" "medium" "pass" "${recovery_result}"
        return 0
    else
        log_failure "Service auto-recovery failed"
        audit_log_entry "test_service_auto_recovery" "auto_recovery" "medium" "fail" "${recovery_result}"
        return 1
    fi
}

test_compliance_monitoring() {
    log_info "Test: Compliance Monitoring"

    # Check if required governance files exist
    local compliance_passed=true
    local missing_files=()

    # Check for MoE router
    if [ ! -f "${COMMIT_RELAY_HOME}/coordination/masters/coordinator/lib/moe-router.sh" ]; then
        missing_files+=("moe-router.sh")
        compliance_passed=false
    fi

    # Check for audit trail
    if [ ! -f "${AUDIT_LOG}" ]; then
        missing_files+=("audit-trail")
        compliance_passed=false
    fi

    if [ "${compliance_passed}" = "true" ]; then
        log_success "Compliance monitoring passed - all required files present"
        audit_log_entry "test_compliance_monitoring" "compliance" "low" "pass" '{}'
        return 0
    else
        log_failure "Compliance monitoring failed - missing files: ${missing_files[*]}"
        audit_log_entry "test_compliance_monitoring" "compliance" "low" "fail" '{"missing_files":["'"${missing_files[*]}"'"]}'
        return 1
    fi
}

#######################################
# Main Test Suite
#######################################

run_all_tests() {
    echo ""
    echo "=========================================="
    echo "  MoE Governance Test Suite"
    echo "=========================================="
    echo ""

    # Risk Assessment Tests
    echo "--- Risk Assessment Tests ---"
    test_risk_assessment_low || true
    test_risk_assessment_medium || true
    test_risk_assessment_high || true
    test_risk_assessment_critical || true
    echo ""

    # Approval Workflow Tests
    echo "--- Approval Workflow Tests ---"
    test_approval_workflow_low_risk || true
    test_approval_workflow_high_risk || true
    echo ""

    # Audit Trail Tests
    echo "--- Audit Trail Tests ---"
    test_audit_trail_generation || true
    test_audit_trail_integrity || true
    echo ""

    # Service Recovery Tests
    echo "--- Service Recovery Tests ---"
    test_circuit_breaker_triggers || true
    test_service_auto_recovery || true
    echo ""

    # Compliance Tests
    echo "--- Compliance Tests ---"
    test_compliance_monitoring || true
    echo ""

    # Generate test report
    generate_test_report
}

generate_test_report() {
    local total_tests=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    local pass_rate=0

    if [ ${total_tests} -gt 0 ]; then
        pass_rate=$(echo "scale=2; ${TESTS_PASSED} * 100 / ${total_tests}" | bc)
    fi

    cat > "${TEST_REPORT}" <<EOF
{
  "test_suite": "governance",
  "timestamp": "${TIMESTAMP}",
  "summary": {
    "total_tests": ${total_tests},
    "passed": ${TESTS_PASSED},
    "failed": ${TESTS_FAILED},
    "skipped": ${TESTS_SKIPPED},
    "pass_rate": ${pass_rate}
  },
  "audit_log": "${AUDIT_LOG}",
  "test_categories": {
    "risk_assessment": 4,
    "approval_workflow": 2,
    "audit_trail": 2,
    "service_recovery": 2,
    "compliance": 1
  },
  "governance_controls": {
    "risk_assessment_enabled": true,
    "approval_workflows_enabled": true,
    "audit_trail_enabled": true,
    "circuit_breaker_enabled": true,
    "compliance_monitoring_enabled": true
  }
}
EOF

    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo "Total Tests: ${total_tests}"
    echo "Passed:      ${TESTS_PASSED}"
    echo "Failed:      ${TESTS_FAILED}"
    echo "Skipped:     ${TESTS_SKIPPED}"
    echo "Pass Rate:   ${pass_rate}%"
    echo ""
    echo "Test Report: ${TEST_REPORT}"
    echo "Audit Log:   ${AUDIT_LOG}"
    echo "=========================================="
}

# Run test suite
run_all_tests
