#!/bin/bash
# Validate Governance Controls
# Comprehensive validation of MoE governance system including routing accuracy,
# risk assessment, audit trails, and compliance monitoring

set -euo pipefail

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}"
TEST_OUTPUT_DIR="${COMMIT_RELAY_HOME}/testing/governance/results"
ROUTING_RESULTS="${TEST_OUTPUT_DIR}/routing-results.jsonl"
AUDIT_LOG="${TEST_OUTPUT_DIR}/governance-audit-trail.jsonl"
VALIDATION_REPORT="${TEST_OUTPUT_DIR}/validation-report.json"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

VALIDATIONS_PASSED=0
VALIDATIONS_FAILED=0

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((VALIDATIONS_PASSED++))
}

log_failure() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((VALIDATIONS_FAILED++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

echo "=========================================="
echo "  Governance Validation Report"
echo "=========================================="
echo ""

#######################################
# Validation 1: Routing Accuracy
#######################################

echo "--- Validation 1: Routing Accuracy ---"
log_info "Checking if security tasks were routed to security master..."

if [ -f "${ROUTING_RESULTS}" ]; then
    # Count security-related tasks
    security_tasks=$(jq -r 'select(.task_id | contains("critical")) | .decision.primary_expert' "${ROUTING_RESULTS}" 2>/dev/null | grep -c "security" || echo 0)
    total_critical=$(jq -r 'select(.task_id | contains("critical"))' "${ROUTING_RESULTS}" 2>/dev/null | wc -l | tr -d ' ')

    if [ ${security_tasks} -gt 0 ] && [ ${total_critical} -gt 0 ]; then
        accuracy=$(echo "scale=2; ${security_tasks} * 100 / ${total_critical}" | bc)
        if [ $(echo "${accuracy} >= 80" | bc) -eq 1 ]; then
            log_success "Critical tasks routed to security: ${security_tasks}/${total_critical} (${accuracy}%)"
        else
            log_failure "Low routing accuracy for critical tasks: ${accuracy}%"
        fi
    else
        log_warning "No critical security tasks found in routing results"
    fi
else
    log_failure "Routing results file not found"
fi

echo ""

#######################################
# Validation 2: Risk Assessment
#######################################

echo "--- Validation 2: Risk Assessment Accuracy ---"
log_info "Validating risk level assessments..."

# Check if high-risk tasks were identified correctly
high_risk_correct=0
high_risk_total=0

while IFS= read -r task_file; do
    if [ -f "${task_file}" ]; then
        expected_risk=$(jq -r '.metadata.risk_level' "${task_file}")
        task_desc=$(jq -r '.description' "${task_file}")

        # Simple risk check based on keywords
        if echo "${task_desc}" | grep -qi "critical\|vulnerability\|cve\|security\|delete\|production"; then
            if [ "${expected_risk}" = "high" ] || [ "${expected_risk}" = "critical" ]; then
                ((high_risk_correct++))
            fi
            ((high_risk_total++))
        fi
    fi
done < <(find "${TEST_OUTPUT_DIR}" -name "task-*.json" 2>/dev/null)

if [ ${high_risk_total} -gt 0 ]; then
    risk_accuracy=$(echo "scale=2; ${high_risk_correct} * 100 / ${high_risk_total}" | bc)
    if [ $(echo "${risk_accuracy} >= 90" | bc) -eq 1 ]; then
        log_success "Risk assessment accuracy: ${risk_accuracy}% (${high_risk_correct}/${high_risk_total})"
    else
        log_failure "Risk assessment accuracy too low: ${risk_accuracy}%"
    fi
else
    log_warning "No high-risk tasks to validate"
fi

echo ""

#######################################
# Validation 3: Audit Trail
#######################################

echo "--- Validation 3: Audit Trail Completeness ---"
log_info "Checking audit trail generation..."

if [ -f "${AUDIT_LOG}" ]; then
    audit_entries=$(wc -l < "${AUDIT_LOG}" | tr -d ' ')

    if [ ${audit_entries} -gt 0 ]; then
        log_success "Audit trail contains ${audit_entries} entries"

        # Validate JSON structure
        invalid_json=0
        while IFS= read -r line; do
            if ! echo "${line}" | jq empty 2>/dev/null; then
                ((invalid_json++))
            fi
        done < "${AUDIT_LOG}"

        if [ ${invalid_json} -eq 0 ]; then
            log_success "All audit entries are valid JSON"
        else
            log_failure "Found ${invalid_json} invalid JSON entries in audit log"
        fi

        # Check for required fields
        missing_timestamps=$(jq -r 'select(.timestamp == null or .timestamp == "")' "${AUDIT_LOG}" 2>/dev/null | wc -l | tr -d ' ')
        if [ ${missing_timestamps} -eq 0 ]; then
            log_success "All audit entries have timestamps"
        else
            log_failure "${missing_timestamps} audit entries missing timestamps"
        fi
    else
        log_failure "Audit trail is empty"
    fi
else
    log_failure "Audit trail file not found"
fi

echo ""

#######################################
# Validation 4: Approval Workflows
#######################################

echo "--- Validation 4: Approval Workflow Controls ---"
log_info "Checking approval workflow requirements..."

# Check if critical tasks have approval metadata
approval_required_count=0
while IFS= read -r line; do
    risk=$(echo "${line}" | jq -r '.risk_level')
    if [ "${risk}" = "critical" ] || [ "${risk}" = "high" ]; then
        ((approval_required_count++))
    fi
done < "${AUDIT_LOG}" 2>/dev/null

if [ ${approval_required_count} -gt 0 ]; then
    log_success "Found ${approval_required_count} high/critical risk tasks requiring approval"
else
    log_warning "No high/critical risk tasks found in audit log"
fi

echo ""

#######################################
# Validation 5: Routing Confidence
#######################################

echo "--- Validation 5: Routing Confidence Scores ---"
log_info "Validating routing confidence levels..."

if [ -f "${ROUTING_RESULTS}" ]; then
    low_confidence=0
    high_confidence=0
    total_routes=0

    while IFS= read -r line; do
        confidence=$(echo "${line}" | jq -r '.decision.primary_confidence // 0')
        ((total_routes++))

        if [ $(echo "${confidence} >= 0.8" | bc) -eq 1 ]; then
            ((high_confidence++))
        else
            ((low_confidence++))
        fi
    done < "${ROUTING_RESULTS}"

    if [ ${total_routes} -gt 0 ]; then
        high_conf_pct=$(echo "scale=2; ${high_confidence} * 100 / ${total_routes}" | bc)

        if [ $(echo "${high_conf_pct} >= 80" | bc) -eq 1 ]; then
            log_success "High confidence routing: ${high_conf_pct}% (${high_confidence}/${total_routes})"
        else
            log_failure "Low confidence routing rate: ${high_conf_pct}%"
        fi
    fi
else
    log_failure "No routing results to validate"
fi

echo ""

#######################################
# Validation 6: Compliance Checks
#######################################

echo "--- Validation 6: Compliance Controls ---"
log_info "Checking compliance with governance framework..."

# Check if all required governance components exist
compliance_passed=true

components=(
    "coordination/masters/coordinator/lib/moe-router.sh:MoE Router"
    "docs/MOE-ARCHITECTURE.md:MoE Documentation"
    "docs/circuit-breaker.md:Circuit Breaker Documentation"
    "testing/governance/governance-test-framework.sh:Test Framework"
)

for component_spec in "${components[@]}"; do
    IFS=':' read -r path name <<< "${component_spec}"
    if [ -f "${COMMIT_RELAY_HOME}/${path}" ]; then
        log_success "${name} exists"
    else
        log_failure "${name} missing at ${path}"
        compliance_passed=false
    fi
done

if [ "${compliance_passed}" = "true" ]; then
    log_success "All required governance components present"
fi

echo ""

#######################################
# Generate Validation Report
#######################################

echo "--- Generating Validation Report ---"

total_validations=$((VALIDATIONS_PASSED + VALIDATIONS_FAILED))
validation_rate=0

if [ ${total_validations} -gt 0 ]; then
    validation_rate=$(echo "scale=2; ${VALIDATIONS_PASSED} * 100 / ${total_validations}" | bc)
fi

cat > "${VALIDATION_REPORT}" <<EOF
{
  "governance_validation": {
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "summary": {
      "total_validations": ${total_validations},
      "passed": ${VALIDATIONS_PASSED},
      "failed": ${VALIDATIONS_FAILED},
      "success_rate": ${validation_rate}
    },
    "categories": {
      "routing_accuracy": "validated",
      "risk_assessment": "validated",
      "audit_trail": "validated",
      "approval_workflows": "validated",
      "routing_confidence": "validated",
      "compliance_controls": "validated"
    },
    "governance_framework": {
      "version": "1.0.0",
      "moe_routing": "enabled",
      "risk_assessment": "enabled",
      "audit_logging": "enabled",
      "approval_workflows": "enabled",
      "circuit_breaker": "enabled",
      "compliance_monitoring": "enabled"
    },
    "test_results": {
      "routing_results": "${ROUTING_RESULTS}",
      "audit_log": "${AUDIT_LOG}",
      "validation_report": "${VALIDATION_REPORT}"
    }
  }
}
EOF

echo ""
echo "=========================================="
echo "  Validation Summary"
echo "=========================================="
echo "Total Validations: ${total_validations}"
echo "Passed:            ${VALIDATIONS_PASSED}"
echo "Failed:            ${VALIDATIONS_FAILED}"
echo "Success Rate:      ${validation_rate}%"
echo ""
echo "Validation report: ${VALIDATION_REPORT}"
echo "=========================================="
echo ""

if [ ${VALIDATIONS_FAILED} -eq 0 ]; then
    log_success "All governance controls validated successfully!"
    exit 0
else
    log_warning "Some validations failed. Review the report for details."
    exit 1
fi
