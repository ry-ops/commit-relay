#!/bin/bash
# Test all governance API endpoints

echo "Testing Governance API Endpoints..."
echo "===================================="
echo ""

PASSED=0
FAILED=0

test_endpoint() {
    local endpoint="$1"
    local description="$2"
    
    response=$(curl -s -w "\n%{http_code}" "http://localhost:5001$endpoint" 2>&1)
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$status_code" = "200" ]; then
        echo "✓ PASS: $endpoint"
        ((PASSED++))
    else
        echo "✗ FAIL: $endpoint (HTTP $status_code)"
        ((FAILED++))
        if echo "$body" | grep -q "error"; then
            echo "  Error: $(echo "$body" | jq -r '.error + ": " + .message' 2>/dev/null || echo "$body")"
        fi
    fi
}

# Test all governance endpoints
test_endpoint "/api/governance/dashboard" "Executive governance dashboard"
test_endpoint "/api/governance/compliance-report" "Compliance report (all frameworks)"
test_endpoint "/api/governance/compliance-check/gdpr" "GDPR compliance check"
test_endpoint "/api/governance/compliance-check/soc2" "SOC2 compliance check"
test_endpoint "/api/governance/compliance-check/internal" "Internal policies check"
test_endpoint "/api/governance/metrics" "Governance metrics"
test_endpoint "/api/governance/trends?period=7d" "7-day trends"
test_endpoint "/api/governance/trends?period=30d" "30-day trends"
test_endpoint "/api/governance/trends?period=90d" "90-day trends"

echo ""
echo "===================================="
echo "Results:"
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo "  Total:  $((PASSED + FAILED))"
echo "===================================="

exit $FAILED
