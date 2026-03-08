#!/usr/bin/env bash
#
# Run Compliance Check
# Evaluates policies against worker specs and generates compliance reports
#
# Usage:
#   ./scripts/run-compliance-check.sh [target] [policy-dir]
#
# Examples:
#   ./scripts/run-compliance-check.sh                    # Check all active workers
#   ./scripts/run-compliance-check.sh worker-spec.json   # Check specific worker
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source required libraries
source "$SCRIPT_DIR/lib/policy-engine.sh"

# Configuration
readonly ACTIVE_WORKERS_DIR="$PROJECT_ROOT/coordination/worker-specs/active"
readonly POLICY_DEFINITIONS_DIR="$PROJECT_ROOT/coordination/policies/policy-definitions"
readonly RESULTS_DIR="$PROJECT_ROOT/coordination/policies/evaluation-results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "  Commit-Relay Compliance Check"
echo "=============================================="
echo ""

# Parse arguments
TARGET="${1:-}"
POLICY_DIR="${2:-$POLICY_DEFINITIONS_DIR}"

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# Generate NIST CSF report first
echo "Generating NIST CSF compliance report..."
source "$SCRIPT_DIR/lib/governance/nist-csf-mapper.sh"
generate_nist_csf_report > /dev/null 2>&1 || true
echo -e "${GREEN}[OK]${NC} NIST CSF report generated"
echo ""

# List available policies
echo "Available Policies:"
echo "-------------------"
list_policies | jq -r '.[] | "  - \(.policy_id) (\(.name)) - \(.severity)"' 2>/dev/null || echo "  No policies found"
echo ""

# Determine targets
if [[ -n "$TARGET" && -f "$TARGET" ]]; then
    # Check specific target
    echo "Evaluating target: $TARGET"
    echo ""

    result=$(evaluate_all_policies "$TARGET" "$POLICY_DIR")

    # Display results
    echo "$result" | jq -r '
        "Overall Result: " + .overall_result,
        "",
        "Summary:",
        "  Total Policies: " + (.summary.total_policies | tostring),
        "  Passed: " + (.summary.passed | tostring),
        "  Failed: " + (.summary.failed | tostring),
        "  Compliance: " + (.summary.compliance_percentage | tostring) + "%"
    '

    # Save result
    echo "$result" > "$RESULTS_DIR/latest-evaluation.json"

elif [[ -d "$ACTIVE_WORKERS_DIR" ]]; then
    # Check all active workers
    echo "Evaluating all active workers..."
    echo ""

    total_workers=0
    compliant_workers=0
    failed_workers=0

    for worker_spec in "$ACTIVE_WORKERS_DIR"/*.json; do
        [[ -f "$worker_spec" ]] || continue

        worker_id=$(jq -r '.worker_id' "$worker_spec" 2>/dev/null || echo "unknown")
        ((total_workers++))

        # Evaluate this worker
        result=$(evaluate_all_policies "$worker_spec" "$POLICY_DIR" 2>/dev/null)
        overall=$(echo "$result" | jq -r '.overall_result')
        score=$(echo "$result" | jq -r '.summary.compliance_percentage')

        if [[ "$overall" == "pass" ]]; then
            echo -e "  ${GREEN}[PASS]${NC} $worker_id - ${score}%"
            ((compliant_workers++))
        else
            echo -e "  ${RED}[FAIL]${NC} $worker_id - ${score}%"
            ((failed_workers++))

            # Show failed policies
            echo "$result" | jq -r '.policy_results[] | select(.result == "fail") | "         - " + .policy_id' 2>/dev/null || true
        fi
    done

    echo ""
    echo "Summary:"
    echo "  Total Workers: $total_workers"
    echo -e "  Compliant: ${GREEN}$compliant_workers${NC}"
    echo -e "  Non-compliant: ${RED}$failed_workers${NC}"

    if [[ $total_workers -gt 0 ]]; then
        compliance_rate=$((compliant_workers * 100 / total_workers))
        echo "  Compliance Rate: ${compliance_rate}%"
    fi
else
    echo "No target specified and no active workers found."
    echo ""
    echo "Usage:"
    echo "  $0 [target-json-file] [policy-directory]"
    echo ""
    echo "Example:"
    echo "  $0 coordination/worker-specs/active/worker-impl-001.json"
fi

echo ""
echo "=============================================="
echo "  Compliance check complete"
echo "=============================================="
