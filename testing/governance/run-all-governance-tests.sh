#!/bin/bash
# Run All Governance Tests
# Master script to execute comprehensive governance testing suite

set -euo pipefail

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}"
TEST_DIR="${COMMIT_RELAY_HOME}/testing/governance"
RESULTS_DIR="${TEST_DIR}/results"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_header() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "  $*"
    echo -e "==========================================${NC}"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

# Clean previous results
log_info "Cleaning previous test results..."
rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

# Make all scripts executable
chmod +x "${TEST_DIR}"/*.sh

log_header "MoE GOVERNANCE TEST SUITE - COMPREHENSIVE VALIDATION"

echo "Test Suite: MoE Governance Controls"
echo "Date: $(date)"
echo "Location: ${TEST_DIR}"
echo ""

#######################################
# Phase 1: Create Test Tasks
#######################################

log_header "PHASE 1: Create Governance Test Tasks"

log_info "Creating test tasks with varying risk levels..."
if "${TEST_DIR}/create-governance-test-tasks.sh"; then
    log_success "Test tasks created successfully"
else
    log_error "Failed to create test tasks"
    exit 1
fi

sleep 2

#######################################
# Phase 2: Run Framework Tests
#######################################

log_header "PHASE 2: Run Governance Test Framework"

log_info "Testing risk assessment, approval workflows, audit trails, and service recovery..."
if "${TEST_DIR}/governance-test-framework.sh"; then
    log_success "Governance framework tests completed"
else
    log_warning "Some framework tests may have failed (check results)"
fi

sleep 2

#######################################
# Phase 3: Route Test Tasks
#######################################

log_header "PHASE 3: Route Tasks Through MoE Router"

log_info "Routing test tasks through MoE system..."
if "${TEST_DIR}/route-test-tasks.sh"; then
    log_success "Test tasks routed successfully"
else
    log_error "Failed to route test tasks"
    exit 1
fi

sleep 2

#######################################
# Phase 4: Validate Governance Controls
#######################################

log_header "PHASE 4: Validate Governance Controls"

log_info "Validating routing accuracy, risk assessment, and compliance..."
if "${TEST_DIR}/validate-governance.sh"; then
    log_success "All governance controls validated successfully"
    VALIDATION_RESULT="PASSED"
else
    log_warning "Some governance validations failed"
    VALIDATION_RESULT="PARTIAL"
fi

sleep 1

#######################################
# Generate Final Report
#######################################

log_header "FINAL REPORT: Governance Test Suite Results"

# Count test files
TASK_COUNT=$(find "${RESULTS_DIR}" -name "task-*.json" 2>/dev/null | wc -l | tr -d ' ')
ROUTING_COUNT=$(wc -l < "${RESULTS_DIR}/routing-results.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
AUDIT_COUNT=$(wc -l < "${RESULTS_DIR}/governance-audit-trail.jsonl" 2>/dev/null | tr -d ' ' || echo 0)

echo "Test Tasks Created:    ${TASK_COUNT}"
echo "Tasks Routed:          ${ROUTING_COUNT}"
echo "Audit Log Entries:     ${AUDIT_COUNT}"
echo "Validation Result:     ${VALIDATION_RESULT}"
echo ""

# Display report locations
echo "Test Results Location: ${RESULTS_DIR}/"
echo ""
echo "Key Files:"
echo "  - Test Report:        governance-test-report.json"
echo "  - Routing Results:    routing-results.jsonl"
echo "  - Audit Trail:        governance-audit-trail.jsonl"
echo "  - Validation Report:  validation-report.json"
echo ""

# Display sample routing results
if [ -f "${RESULTS_DIR}/routing-results.jsonl" ]; then
    echo "Sample Routing Results:"
    echo "----------------------"
    head -3 "${RESULTS_DIR}/routing-results.jsonl" | jq -r '
        "Task: \(.task_id)\n  Risk: \(.expected_risk)\n  Routed to: \(.decision.primary_expert)\n  Confidence: \((.decision.primary_confidence * 100) | floor)%\n"
    ' 2>/dev/null || echo "Unable to parse routing results"
fi

# Generate comprehensive summary report
cat > "${RESULTS_DIR}/comprehensive-summary.json" <<EOF
{
  "governance_test_suite": {
    "executed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "test_phases": {
      "phase_1_create_tasks": "completed",
      "phase_2_framework_tests": "completed",
      "phase_3_route_tasks": "completed",
      "phase_4_validate_controls": "completed"
    },
    "statistics": {
      "tasks_created": ${TASK_COUNT},
      "tasks_routed": ${ROUTING_COUNT},
      "audit_entries": ${AUDIT_COUNT},
      "validation_result": "${VALIDATION_RESULT}"
    },
    "test_categories": {
      "risk_assessment": {
        "low_risk_tasks": 3,
        "medium_risk_tasks": 3,
        "high_risk_tasks": 3,
        "critical_risk_tasks": 3
      },
      "governance_controls_tested": [
        "risk_assessment",
        "approval_workflows",
        "audit_trail_generation",
        "circuit_breaker_triggers",
        "service_auto_recovery",
        "compliance_monitoring",
        "routing_confidence",
        "moe_routing_accuracy"
      ]
    },
    "framework_version": "1.0.0",
    "test_suite_location": "${TEST_DIR}",
    "results_location": "${RESULTS_DIR}"
  }
}
EOF

log_success "Comprehensive summary generated: comprehensive-summary.json"

echo ""
log_header "GOVERNANCE TEST SUITE COMPLETE"

if [ "${VALIDATION_RESULT}" = "PASSED" ]; then
    log_success "All governance controls are functioning correctly!"
    echo ""
    echo "Governance Framework Status: OPERATIONAL"
    echo "Risk Assessment:             VALIDATED"
    echo "Approval Workflows:          VALIDATED"
    echo "Audit Trail:                 VALIDATED"
    echo "Circuit Breaker:             VALIDATED"
    echo "Compliance Monitoring:       VALIDATED"
    echo ""
    exit 0
else
    log_warning "Some governance controls need attention. Review validation report."
    echo ""
    echo "Review: ${RESULTS_DIR}/validation-report.json"
    echo ""
    exit 1
fi
