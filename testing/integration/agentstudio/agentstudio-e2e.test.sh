#!/usr/bin/env bash
#
# Agentstudio End-to-End Integration Tests
# Tests complete workflow: registry → templates → versions → performance → marketplace
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Test configuration
readonly TEST_DIR="/tmp/agentstudio-e2e-test-$$"
readonly TEST_AGENT_ID="test-agent-e2e-$$"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#
# Test utilities
#
log_test() {
    echo -e "${YELLOW}TEST:${NC} $1"
}

log_pass() {
    echo -e "${GREEN}PASS:${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}FAIL:${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

run_test() {
    local name="$1"
    local cmd="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$name"

    if eval "$cmd"; then
        log_pass "$name"
        return 0
    else
        log_fail "$name"
        return 1
    fi
}

#
# Setup
#
setup() {
    echo "=== Setting up test environment ==="
    mkdir -p "$TEST_DIR"

    # Override directories for testing
    export REGISTRY_DIR="$TEST_DIR/registry"
    export TEMPLATES_DIR="$TEST_DIR/templates"
    export VERSIONS_DIR="$TEST_DIR/versions"
    export PERFORMANCE_DIR="$TEST_DIR/performance"
    export MARKETPLACE_DIR="$TEST_DIR/marketplace"
    export EXPORT_DIR="$TEST_DIR/exports"

    mkdir -p "$REGISTRY_DIR"/{active,inactive,pending}
    mkdir -p "$TEMPLATES_DIR"/{builtin,custom,generated}
    mkdir -p "$VERSIONS_DIR"/{active,staged,deprecated,history,indices}
    mkdir -p "$PERFORMANCE_DIR"/{reports,benchmarks,baselines}
    mkdir -p "$MARKETPLACE_DIR"/{listings,packages,reviews,indices}
    mkdir -p "$EXPORT_DIR"

    echo "Test directory: $TEST_DIR"
}

#
# Teardown
#
teardown() {
    echo ""
    echo "=== Cleaning up test environment ==="
    rm -rf "$TEST_DIR"
}

#
# Test: Registry Operations
#
test_registry() {
    echo ""
    echo "=== Testing Registry Operations ==="

    source "$PROJECT_ROOT/scripts/lib/agentstudio/agent-registry.sh"

    # Test 1: Register agent
    run_test "Register new agent" '
        local result=$(register_agent "$TEST_AGENT_ID" "Test Agent" "master" "A test agent for e2e testing")
        [[ -n "$result" ]] && [[ -f "$REGISTRY_DIR/active/${TEST_AGENT_ID}.json" ]]
    '

    # Test 2: Get agent
    run_test "Get registered agent" '
        local agent=$(get_agent "$TEST_AGENT_ID")
        local name=$(echo "$agent" | jq -r ".name")
        [[ "$name" == "Test Agent" ]]
    '

    # Test 3: Update agent status
    run_test "Update agent status" '
        update_agent_status "$TEST_AGENT_ID" "running"
        local agent=$(get_agent "$TEST_AGENT_ID")
        local status=$(echo "$agent" | jq -r ".status")
        [[ "$status" == "running" ]]
    '

    # Test 4: Update agent metrics
    run_test "Update agent metrics" '
        update_agent_metrics "$TEST_AGENT_ID" 100 95 50
        local agent=$(get_agent "$TEST_AGENT_ID")
        local tasks=$(echo "$agent" | jq -r ".metrics.total_tasks")
        [[ "$tasks" == "100" ]]
    '

    # Test 5: List agents
    run_test "List all agents" '
        local agents=$(list_agents)
        local count=$(echo "$agents" | jq "length")
        [[ $count -ge 1 ]]
    '

    # Test 6: Search agents
    run_test "Search agents by class" '
        local results=$(search_agents "" "master")
        local count=$(echo "$results" | jq "length")
        [[ $count -ge 1 ]]
    '
}

#
# Test: Template Operations
#
test_templates() {
    echo ""
    echo "=== Testing Template Operations ==="

    source "$PROJECT_ROOT/scripts/lib/agentstudio/template-engine.sh"

    # Test 1: Create custom template
    run_test "Create custom template" '
        local result=$(create_template "test-template" "master" "Test Template" "A test template")
        [[ -n "$result" ]] && [[ -f "$TEMPLATES_DIR/custom/test-template.json" ]]
    '

    # Test 2: Get template
    run_test "Get template" '
        local template=$(get_template "test-template")
        local name=$(echo "$template" | jq -r ".name")
        [[ "$name" == "Test Template" ]]
    '

    # Test 3: List templates
    run_test "List templates" '
        local templates=$(list_templates)
        local count=$(echo "$templates" | jq "length")
        [[ $count -ge 1 ]]
    '

    # Test 4: Validate template
    run_test "Validate template" '
        local result=$(validate_template "test-template")
        local valid=$(echo "$result" | jq -r ".valid")
        [[ "$valid" == "true" ]]
    '
}

#
# Test: Version Management
#
test_versions() {
    echo ""
    echo "=== Testing Version Management ==="

    source "$PROJECT_ROOT/scripts/lib/agentstudio/version-manager.sh"

    # Test 1: Create version
    run_test "Create version" '
        local result=$(create_version "$TEST_AGENT_ID" "1.0.0" "Initial version")
        [[ -n "$result" ]] && [[ "$result" =~ ^$TEST_AGENT_ID-v1\.0\.0- ]]
    '

    local version_id=$(ls "$VERSIONS_DIR/active/" | head -1 | sed "s/.json//")

    # Test 2: Get version
    run_test "Get version" '
        local version=$(get_version "'$version_id'")
        local ver=$(echo "$version" | jq -r ".version")
        [[ "$ver" == "1.0.0" ]]
    '

    # Test 3: Update version status
    run_test "Update version status" '
        update_version_status "'$version_id'" "testing"
        local version=$(get_version "'$version_id'")
        local status=$(echo "$version" | jq -r ".status")
        [[ "$status" == "testing" ]]
    '

    # Test 4: Add changelog
    run_test "Add changelog entry" '
        add_changelog_entry "'$version_id'" "feature" "Added new capability"
        local version=$(get_version "'$version_id'")
        local changes=$(echo "$version" | jq ".changelog[0].changes | length")
        [[ $changes -ge 1 ]]
    '

    # Test 5: Tag version
    run_test "Tag version" '
        tag_version "'$version_id'" "latest"
        local version=$(get_version "'$version_id'")
        local tags=$(echo "$version" | jq -r ".tags[]")
        [[ "$tags" =~ "latest" ]]
    '

    # Test 6: Stage version
    run_test "Stage version" '
        stage_version "'$version_id'" "staging"
        local version=$(get_version "'$version_id'")
        local status=$(echo "$version" | jq -r ".status")
        [[ "$status" == "staged" ]]
    '

    # Test 7: Deploy version
    run_test "Deploy version" '
        deploy_version "'$version_id'" "development" 1 "immediate"
        local version=$(get_version "'$version_id'")
        local status=$(echo "$version" | jq -r ".status")
        [[ "$status" == "deployed" ]]
    '

    # Test 8: List versions
    run_test "List versions" '
        local versions=$(list_versions "'$TEST_AGENT_ID'")
        local count=$(echo "$versions" | jq "length")
        [[ $count -ge 1 ]]
    '
}

#
# Test: Performance Tracking
#
test_performance() {
    echo ""
    echo "=== Testing Performance Tracking ==="

    source "$PROJECT_ROOT/scripts/lib/agentstudio/performance-tracker.sh"

    # Test 1: Collect metrics
    run_test "Collect metrics" '
        local metrics=$(collect_metrics "$TEST_AGENT_ID" 24)
        local has_throughput=$(echo "$metrics" | jq "has(\"metrics\")")
        [[ "$has_throughput" == "true" ]]
    '

    # Test 2: Run benchmark
    run_test "Run benchmark" '
        local results=$(run_benchmark "$TEST_AGENT_ID" "speed")
        local count=$(echo "$results" | jq "length")
        [[ $count -ge 1 ]]
    '

    # Test 3: Detect bottlenecks
    run_test "Detect bottlenecks" '
        local metrics=$(collect_metrics "$TEST_AGENT_ID" 24)
        local bottlenecks=$(detect_bottlenecks "$TEST_AGENT_ID" "$metrics")
        [[ $(echo "$bottlenecks" | jq "type") == "\"array\"" ]]
    '

    # Test 4: Generate recommendations
    run_test "Generate recommendations" '
        local metrics=$(collect_metrics "$TEST_AGENT_ID" 24)
        local bottlenecks=$(detect_bottlenecks "$TEST_AGENT_ID" "$metrics")
        local recs=$(generate_recommendations "$TEST_AGENT_ID" "$metrics" "$bottlenecks")
        [[ $(echo "$recs" | jq "type") == "\"array\"" ]]
    '

    # Test 5: Generate report
    run_test "Generate performance report" '
        local report=$(generate_performance_report "$TEST_AGENT_ID" 24)
        local has_metrics=$(echo "$report" | jq "has(\"metrics\")")
        local has_recs=$(echo "$report" | jq "has(\"recommendations\")")
        [[ "$has_metrics" == "true" ]] && [[ "$has_recs" == "true" ]]
    '

    # Test 6: Save baseline
    run_test "Save baseline" '
        save_baseline "$TEST_AGENT_ID"
        [[ -f "$PERFORMANCE_DIR/baselines/${TEST_AGENT_ID}-baseline.json" ]]
    '
}

#
# Test: Marketplace Operations
#
test_marketplace() {
    echo ""
    echo "=== Testing Marketplace Operations ==="

    source "$PROJECT_ROOT/scripts/lib/agentstudio/marketplace.sh"

    # Test 1: Publish agent
    run_test "Publish to marketplace" '
        local listing_id=$(publish_agent "$TEST_AGENT_ID" "Test Agent" "1.0.0" "A test agent" "development")
        [[ -n "$listing_id" ]] && [[ "$listing_id" =~ ^mkt- ]]
    '

    local listing_id=$(ls "$MARKETPLACE_DIR/listings/" | head -1 | sed "s/.json//")

    # Test 2: Get listing
    run_test "Get listing" '
        local listing=$(get_listing "'$listing_id'")
        local name=$(echo "$listing" | jq -r ".name")
        [[ "$name" == "Test Agent" ]]
    '

    # Test 3: Search marketplace
    run_test "Search marketplace" '
        local results=$(search_marketplace "Test")
        local count=$(echo "$results" | jq "length")
        [[ $count -ge 1 ]]
    '

    # Test 4: List by category
    run_test "List by category" '
        local results=$(list_by_category "development")
        local count=$(echo "$results" | jq "length")
        [[ $count -ge 1 ]]
    '

    # Test 5: Add review
    run_test "Add review" '
        local review_id=$(add_review "'$listing_id'" 5 "Great agent" "Works perfectly!")
        [[ -n "$review_id" ]] && [[ "$review_id" =~ ^rev- ]]
    '

    # Test 6: Get reviews
    run_test "Get reviews" '
        local reviews=$(get_reviews "'$listing_id'")
        local count=$(echo "$reviews" | jq "length")
        [[ $count -ge 1 ]]
    '

    # Test 7: Record download
    run_test "Record download" '
        record_download "'$listing_id'"
        local listing=$(get_listing "'$listing_id'")
        local downloads=$(echo "$listing" | jq -r ".statistics.downloads")
        [[ $downloads -ge 1 ]]
    '

    # Test 8: Install from marketplace
    run_test "Install from marketplace" '
        local result=$(install_from_marketplace "'$listing_id'")
        local status=$(echo "$result" | jq -r ".status")
        [[ "$status" == "installed" ]]
    '

    # Test 9: Get marketplace stats
    run_test "Get marketplace stats" '
        local stats=$(get_marketplace_stats)
        local total=$(echo "$stats" | jq -r ".total_listings")
        [[ $total -ge 1 ]]
    '

    # Test 10: Get trending
    run_test "Get trending" '
        local results=$(get_trending 10)
        [[ $(echo "$results" | jq "type") == "\"array\"" ]]
    '
}

#
# Test: CLI Tools
#
test_cli_tools() {
    echo ""
    echo "=== Testing CLI Tools ==="

    # Test 1: agent-version help
    run_test "agent-version CLI help" '
        "$PROJECT_ROOT/scripts/agent-version" help >/dev/null 2>&1
    '

    # Test 2: agent-performance help
    run_test "agent-performance CLI help" '
        "$PROJECT_ROOT/scripts/agent-performance" help >/dev/null 2>&1
    '

    # Test 3: agent-marketplace help
    run_test "agent-marketplace CLI help" '
        "$PROJECT_ROOT/scripts/agent-marketplace" help >/dev/null 2>&1
    '

    # Test 4: agent-marketplace stats
    run_test "agent-marketplace CLI stats" '
        MARKETPLACE_DIR="$TEST_DIR/marketplace" "$PROJECT_ROOT/scripts/agent-marketplace" stats >/dev/null 2>&1
    '

    # Test 5: agent-marketplace categories
    run_test "agent-marketplace CLI categories" '
        "$PROJECT_ROOT/scripts/agent-marketplace" categories >/dev/null 2>&1
    '
}

#
# Test: Cross-System Integration
#
test_integration() {
    echo ""
    echo "=== Testing Cross-System Integration ==="

    source "$PROJECT_ROOT/scripts/lib/agentstudio/agent-registry.sh"
    source "$PROJECT_ROOT/scripts/lib/agentstudio/version-manager.sh"
    source "$PROJECT_ROOT/scripts/lib/agentstudio/performance-tracker.sh"
    source "$PROJECT_ROOT/scripts/lib/agentstudio/marketplace.sh"

    local integration_agent="integration-test-$$"

    # Test 1: Complete workflow - register to marketplace
    run_test "Complete workflow: register → version → performance → marketplace" '
        # Step 1: Register agent
        register_agent "$integration_agent" "Integration Agent" "worker" "End-to-end test"

        # Step 2: Create version
        local version_id=$(create_version "$integration_agent" "1.0.0" "Initial")

        # Step 3: Deploy version
        deploy_version "$version_id" "development" 1 "immediate"

        # Step 4: Track performance
        local report=$(generate_performance_report "$integration_agent" 1)

        # Step 5: Publish to marketplace
        local listing_id=$(publish_agent "$integration_agent" "Integration Agent" "1.0.0" "E2E test agent" "testing")

        # Verify all steps succeeded
        [[ -n "$version_id" ]] && [[ -n "$listing_id" ]]
    '

    # Test 2: Version update workflow
    run_test "Version update workflow" '
        # Create new version
        local v2=$(create_version "$integration_agent" "1.1.0" "Update")

        # Add changelog
        add_changelog_entry "$v2" "feature" "New feature"
        add_changelog_entry "$v2" "fix" "Bug fix"

        # Stage and deploy
        stage_version "$v2" "staging"
        deploy_version "$v2" "development" 1 "immediate"

        # Tag
        tag_version "$v2" "latest"

        [[ -n "$v2" ]]
    '

    # Test 3: Performance optimization workflow
    run_test "Performance optimization workflow" '
        # Collect metrics
        local metrics=$(collect_metrics "$integration_agent" 24)

        # Run benchmarks
        local benchmarks=$(run_benchmark "$integration_agent" "all")

        # Get recommendations
        local bottlenecks=$(detect_bottlenecks "$integration_agent" "$metrics")
        local recs=$(generate_recommendations "$integration_agent" "$metrics" "$bottlenecks")

        # Save baseline
        save_baseline "$integration_agent"

        [[ $(echo "$recs" | jq "type") == "\"array\"" ]]
    '

    # Test 4: Marketplace distribution workflow
    run_test "Marketplace distribution workflow" '
        # Search
        local results=$(search_marketplace "Integration")
        local listing_id=$(echo "$results" | jq -r ".[0].listing_id")

        # Review
        add_review "$listing_id" 4 "Good agent" "Works well for testing"

        # Install
        install_from_marketplace "$listing_id"

        # Check stats
        local stats=$(get_marketplace_stats)
        local installs=$(echo "$stats" | jq -r ".total_installs")

        [[ $installs -ge 1 ]]
    '
}

#
# Main
#
main() {
    echo "========================================"
    echo "  Agentstudio E2E Integration Tests"
    echo "========================================"
    echo ""

    setup

    # Run all test suites
    test_registry
    test_templates
    test_versions
    test_performance
    test_marketplace
    test_cli_tools
    test_integration

    teardown

    # Summary
    echo ""
    echo "========================================"
    echo "  Test Summary"
    echo "========================================"
    echo ""
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed${NC}"
        exit 1
    fi
}

# Run tests
main "$@"
