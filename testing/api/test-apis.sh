#!/bin/bash
# Test all dashboard GET endpoints

echo "Testing Dashboard APIs..."
echo "========================="

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

# Test all GET endpoints that don't require params
test_endpoint "/api/health" "Health check"
test_endpoint "/api/metrics" "System metrics"
test_endpoint "/api/metrics/history" "Metrics history"
test_endpoint "/api/workers" "Workers list"
test_endpoint "/api/tasks" "Tasks list"
test_endpoint "/api/execution-managers" "Execution managers"
test_endpoint "/api/streams" "Workforce streams"
test_endpoint "/api/coordination/raw" "Raw coordination data"
test_endpoint "/api/events" "System events"
test_endpoint "/api/git-operations" "Git operations"
test_endpoint "/api/git-info" "Git info"
test_endpoint "/api/daemon/status" "Worker daemon status"
test_endpoint "/api/pm-daemon/status" "PM daemon status"
test_endpoint "/api/dashboard-server/status" "Dashboard server status"
test_endpoint "/api/health-alerts" "Health alerts"

echo ""
echo "========================="
echo "Results:"
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo "  Total:  $((PASSED + FAILED))"
echo "========================="

exit $FAILED
