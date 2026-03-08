#!/usr/bin/env bash
#
# Agent Registry Tests
# Part of Q2 Week 21-22: Agent Registry & Catalog
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Use test registry directory
export REGISTRY_DIR="coordination/agentstudio/test-registry"

# Source libraries
source "$PROJECT_ROOT/scripts/lib/agentstudio/agent-register.sh"
source "$PROJECT_ROOT/scripts/lib/agentstudio/agent-catalog.sh"

# Test counters
PASS_COUNT=0
FAIL_COUNT=0

#
# Test utilities
#
pass() {
    echo "✓ PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "✗ FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

cleanup() {
    rm -rf "$REGISTRY_DIR"
}

#
# Tests
#

echo "=== Agent Registry Tests ==="
echo ""

# Cleanup before tests
cleanup

# Test 1: Initialize registry
echo "Test 1: Registry Initialization"
init_registry
if [[ -d "$ACTIVE_DIR" && -d "$IDLE_DIR" && -d "$RETIRED_DIR" && -d "$INDEX_DIR" ]]; then
    pass "Registry directories created"
else
    fail "Registry directories not created"
fi
echo ""

# Test 2: Generate agent ID
echo "Test 2: Agent ID Generation"
agent_id=$(generate_agent_id "test-worker")
if [[ "$agent_id" =~ ^test-worker-[a-f0-9]{8}$ ]]; then
    pass "Agent ID format valid: $agent_id"
else
    fail "Agent ID format invalid: $agent_id"
fi
echo ""

# Test 3: Register agent
echo "Test 3: Agent Registration"
capabilities='[{"capability_id":"test_capability","name":"Test Capability","category":"testing"}]'
registered_id=$(register_agent "test-worker" "Test Worker" "1.0.0" "$capabilities" "Test description")

if [[ -f "$ACTIVE_DIR/${registered_id}.json" ]]; then
    pass "Agent file created: $registered_id"
else
    fail "Agent file not created"
fi
echo ""

# Test 4: Get agent
echo "Test 4: Get Agent"
agent_data=$(get_agent "$registered_id")
if echo "$agent_data" | jq -e '.agent_id' >/dev/null 2>&1; then
    agent_name=$(echo "$agent_data" | jq -r '.name')
    if [[ "$agent_name" == "Test Worker" ]]; then
        pass "Agent retrieved with correct name"
    else
        fail "Agent name mismatch: $agent_name"
    fi
else
    fail "Agent data invalid"
fi
echo ""

# Test 5: Update agent status
echo "Test 5: Update Agent Status"
update_agent_status "$registered_id" "idle"
if [[ -f "$IDLE_DIR/${registered_id}.json" ]]; then
    pass "Agent moved to idle directory"

    status=$(cat "$IDLE_DIR/${registered_id}.json" | jq -r '.status')
    if [[ "$status" == "idle" ]]; then
        pass "Agent status updated correctly"
    else
        fail "Agent status not updated: $status"
    fi
else
    fail "Agent not moved to idle directory"
fi
echo ""

# Test 6: Heartbeat
echo "Test 6: Agent Heartbeat"
initial_last_seen=$(cat "$IDLE_DIR/${registered_id}.json" | jq -r '.last_seen_at')
sleep 1
agent_heartbeat "$registered_id"
updated_last_seen=$(cat "$IDLE_DIR/${registered_id}.json" | jq -r '.last_seen_at')

if [[ $updated_last_seen -gt $initial_last_seen ]]; then
    pass "Heartbeat updated last_seen_at"
else
    fail "Heartbeat did not update last_seen_at"
fi
echo ""

# Test 7: Update performance
echo "Test 7: Update Performance"
update_performance "$registered_id" 10 2 1500 5000
perf_data=$(cat "$IDLE_DIR/${registered_id}.json" | jq '.performance')

completed=$(echo "$perf_data" | jq -r '.tasks_completed')
failed=$(echo "$perf_data" | jq -r '.tasks_failed')
success_rate=$(echo "$perf_data" | jq -r '.success_rate')

if [[ $completed -eq 10 && $failed -eq 2 ]]; then
    pass "Performance metrics updated"

    # Check success rate calculation (10/12 = 0.8333)
    if [[ $(echo "$success_rate > 0.83 && $success_rate < 0.84" | bc) -eq 1 ]]; then
        pass "Success rate calculated correctly: $success_rate"
    else
        fail "Success rate incorrect: $success_rate"
    fi
else
    fail "Performance metrics not updated correctly"
fi
echo ""

# Test 8: Update health
echo "Test 8: Update Health"
update_health "$registered_id" "degraded" "Test health message" 3
health_data=$(cat "$IDLE_DIR/${registered_id}.json" | jq '.health')

health_status=$(echo "$health_data" | jq -r '.status')
health_message=$(echo "$health_data" | jq -r '.message')
error_count=$(echo "$health_data" | jq -r '.error_count')

if [[ "$health_status" == "degraded" && "$health_message" == "Test health message" && $error_count -eq 3 ]]; then
    pass "Health data updated correctly"
else
    fail "Health data not updated correctly"
fi
echo ""

# Test 9: List agents
echo "Test 9: List Agents"
# Register a few more agents
register_agent "dev-worker" "Dev Worker" "1.0.0" '[]' >/dev/null
register_agent "security-worker" "Security Worker" "1.0.0" '[]' >/dev/null

all_agents=$(list_agents)
agent_count=$(echo "$all_agents" | jq 'length')

if [[ $agent_count -eq 3 ]]; then
    pass "List agents returned correct count: $agent_count"
else
    fail "List agents count mismatch: $agent_count (expected 3)"
fi
echo ""

# Test 10: Find by class
echo "Test 10: Find by Class"
test_workers=$(find_by_class "test-worker")
count=$(echo "$test_workers" | jq 'length')

if [[ $count -eq 1 ]]; then
    pass "Find by class returned correct count"
else
    fail "Find by class count mismatch: $count"
fi
echo ""

# Test 11: Retire agent
echo "Test 11: Retire Agent"
deregister_agent "$registered_id"

if [[ -f "$RETIRED_DIR/${registered_id}.json" ]]; then
    pass "Agent moved to retired directory"

    retired_status=$(cat "$RETIRED_DIR/${registered_id}.json" | jq -r '.status')
    if [[ "$retired_status" == "retired" ]]; then
        pass "Agent status set to retired"
    else
        fail "Agent status not set to retired: $retired_status"
    fi

    retired_at=$(cat "$RETIRED_DIR/${registered_id}.json" | jq -r '.retired_at')
    if [[ $retired_at -gt 0 ]]; then
        pass "Retired timestamp set"
    else
        fail "Retired timestamp not set"
    fi
else
    fail "Agent not moved to retired directory"
fi
echo ""

# Test 12: Capability index
echo "Test 12: Capability Index"
# Register agent with capability
cap_test_id=$(register_agent "cap-test-worker" "Cap Test" "1.0.0" '[{"capability_id":"code_analysis","name":"Code Analysis","category":"development"}]')

agents_with_cap=$(find_by_capability "code_analysis")
count=$(echo "$agents_with_cap" | jq 'length')

if [[ $count -ge 1 ]]; then
    pass "Capability index working"
else
    fail "Capability index not working"
fi
echo ""

# Test 13: Search agents
echo "Test 13: Search Agents"
search_results=$(search_agents '{"status":"active"}')
count=$(echo "$search_results" | jq 'length')

if [[ $count -ge 2 ]]; then
    pass "Search returned results: $count"
else
    fail "Search returned no results"
fi
echo ""

# Test 14: Catalog stats
echo "Test 14: Catalog Statistics"
stats=$(get_catalog_stats)

if echo "$stats" | jq -e '.total_agents' >/dev/null 2>&1; then
    total=$(echo "$stats" | jq -r '.total_agents')
    if [[ $total -ge 3 ]]; then
        pass "Catalog stats working, total agents: $total"
    else
        fail "Catalog stats total agents incorrect: $total"
    fi
else
    fail "Catalog stats invalid"
fi
echo ""

# Test 15: Export catalog
echo "Test 15: Export Catalog"
export_file=$(export_catalog "coordination/agentstudio/test-catalog-export.json")

if [[ -f "$export_file" ]]; then
    pass "Catalog exported to file"

    if jq -e '.agents' "$export_file" >/dev/null 2>&1; then
        pass "Export file contains valid JSON"
    else
        fail "Export file JSON invalid"
    fi
else
    fail "Catalog export failed"
fi
echo ""

# Cleanup after tests
cleanup
rm -f "coordination/agentstudio/test-catalog-export.json"

# Summary
echo "=== Test Summary ==="
echo "PASSED: $PASS_COUNT"
echo "FAILED: $FAIL_COUNT"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
