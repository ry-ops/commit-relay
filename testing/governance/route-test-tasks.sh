#!/bin/bash
# Route Test Tasks Through MoE
# Route governance test tasks through the MoE router to validate routing decisions
# and observe governance controls in action

set -euo pipefail

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}"
MOE_ROUTER="${COMMIT_RELAY_HOME}/coordination/masters/coordinator/lib/moe-router.sh"
TEST_OUTPUT_DIR="${COMMIT_RELAY_HOME}/testing/governance/results"
ROUTING_RESULTS="${TEST_OUTPUT_DIR}/routing-results.jsonl"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Initialize routing results log
mkdir -p "${TEST_OUTPUT_DIR}"
> "${ROUTING_RESULTS}"

echo "=========================================="
echo "  MoE Routing Test"
echo "=========================================="
echo ""

if [ ! -f "${MOE_ROUTER}" ]; then
    log_error "MoE router not found at ${MOE_ROUTER}"
    exit 1
fi

if [ ! -x "${MOE_ROUTER}" ]; then
    chmod +x "${MOE_ROUTER}"
fi

route_task() {
    local task_file="$1"
    local task_id=$(jq -r '.id' "${task_file}")
    local task_desc=$(jq -r '.description' "${task_file}")
    local expected_risk=$(jq -r '.metadata.risk_level' "${task_file}")

    log_info "Routing task: ${task_id}"
    echo "  Description: ${task_desc}"
    echo "  Expected Risk: ${expected_risk}"

    # Route through MoE
    local routing_result
    if routing_result=$("${MOE_ROUTER}" "${task_id}" "${task_desc}" 2>&1); then
        local primary_expert=$(echo "${routing_result}" | jq -r '.decision.primary_expert')
        local confidence=$(echo "${routing_result}" | jq -r '.decision.primary_confidence')
        local conf_pct=$(echo "scale=0; ${confidence} * 100 / 1" | bc)

        echo "  Routed to: ${primary_expert} (${conf_pct}% confidence)"

        # Add risk level and save to results
        local enhanced_result=$(echo "${routing_result}" | jq '. + {
          "expected_risk": "'"${expected_risk}"'",
          "routed_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
        }')

        echo "${enhanced_result}" >> "${ROUTING_RESULTS}"
        log_success "Task routed successfully"
    else
        log_error "Routing failed for ${task_id}"
        echo '{"task_id":"'"${task_id}"'","error":"routing_failed","expected_risk":"'"${expected_risk}"'"}' >> "${ROUTING_RESULTS}"
    fi

    echo ""
}

# Route all test tasks
echo "--- Routing Low Risk Tasks ---"
for task_file in "${TEST_OUTPUT_DIR}"/task-low-*.json; do
    if [ -f "${task_file}" ]; then
        route_task "${task_file}" || true
    fi
done

echo "--- Routing Medium Risk Tasks ---"
for task_file in "${TEST_OUTPUT_DIR}"/task-medium-*.json; do
    if [ -f "${task_file}" ]; then
        route_task "${task_file}" || true
    fi
done

echo "--- Routing High Risk Tasks ---"
for task_file in "${TEST_OUTPUT_DIR}"/task-high-*.json; do
    if [ -f "${task_file}" ]; then
        route_task "${task_file}" || true
    fi
done

echo "--- Routing Critical Risk Tasks ---"
for task_file in "${TEST_OUTPUT_DIR}"/task-critical-*.json; do
    if [ -f "${task_file}" ]; then
        route_task "${task_file}" || true
    fi
done

# Generate routing summary
echo "=========================================="
echo "  Routing Summary"
echo "=========================================="
echo ""

if [ -f "${ROUTING_RESULTS}" ]; then
    total_routes=$(wc -l < "${ROUTING_RESULTS}" | tr -d ' ')
    security_routes=$(grep -c '"primary_expert":"security"' "${ROUTING_RESULTS}" 2>/dev/null || echo 0)
    development_routes=$(grep -c '"primary_expert":"development"' "${ROUTING_RESULTS}" 2>/dev/null || echo 0)
    cicd_routes=$(grep -c '"primary_expert":"cicd"' "${ROUTING_RESULTS}" 2>/dev/null || echo 0)

    echo "Total Routes:       ${total_routes}"
    echo "Security Master:    ${security_routes}"
    echo "Development Master: ${development_routes}"
    echo "CI/CD Master:       ${cicd_routes}"
    echo ""
    echo "Routing results saved to: ${ROUTING_RESULTS}"
fi

echo ""
echo "Next: Run validation script to verify governance controls"
echo "./testing/governance/validate-governance.sh"
echo ""
