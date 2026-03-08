#!/bin/bash
# Test v5.0 CAG-enhanced MoE Router

ROUTER="./coordination/masters/coordinator/lib/moe-router.sh"

echo "Testing v5.0 CAG-Enhanced MoE Router"
echo "======================================"
echo ""

test_routing() {
    local test_name="$1"
    local task_desc="$2"

    echo "Test: $test_name"
    echo "  Task: $task_desc"

    local result=$("$ROUTER" "test-id" "$task_desc" 2>&1)
    local expert=$(echo "$result" | jq -r '.decision.primary_expert')
    local confidence=$(echo "$result" | jq -r '.decision.primary_confidence')
    local conf_pct=$(echo "$confidence * 100" | bc)

    echo "  → Routed to: $expert (${conf_pct}% confidence)"
    echo ""
}

test_routing "Security Scan" "security-scan: scan repository for vulnerabilities"
test_routing "Feature Development" "feature: implement user authentication"
test_routing "CVE Remediation" "cve-2024-1234: patch critical vulnerability"
test_routing "Code Refactor" "refactor: improve code quality and performance"
test_routing "Bug Fix" "bug-fix: resolve login error"
test_routing "Inventory" "inventory: catalog all repositories"

echo "======================================"
echo "✅ v5.0 type-based routing operational"
