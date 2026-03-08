#!/usr/bin/env bash
#
# Agent Wizard Test Suite
# Part of Q2 Week 23-24: Agent Designer & Templates
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly TEST_DIR="$PROJECT_ROOT/testing/tmp/agent-wizard-test-$$"

# Test configuration
readonly WIZARD_CMD="$PROJECT_ROOT/scripts/agent-wizard"
readonly VALIDATOR_CMD="$PROJECT_ROOT/scripts/validate-templates"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#
# Setup test environment
#
setup() {
    echo "Setting up test environment..."
    mkdir -p "$TEST_DIR"
    cd "$PROJECT_ROOT"
}

#
# Cleanup test environment
#
cleanup() {
    echo "Cleaning up test environment..."
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi

    # Clean up generated test agents
    rm -rf "$PROJECT_ROOT/coordination/masters/test-"* 2>/dev/null || true
    rm -rf "$PROJECT_ROOT/coordination/workers/test-"* 2>/dev/null || true
    rm -rf "$PROJECT_ROOT/scripts/daemons/test-"* 2>/dev/null || true
    rm -rf "$PROJECT_ROOT/llm-mesh/agents/test-"* 2>/dev/null || true
}

#
# Test assertion helpers
#
pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_file_exists() {
    local file="$1"
    local test_name="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -f "$file" ]]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name - File not found: $file"
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local test_name="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ -f "$file" ]] && grep -q "$pattern" "$file"; then
        pass "$test_name"
        return 0
    else
        fail "$test_name - Pattern not found: $pattern"
        return 1
    fi
}

assert_command_success() {
    local test_name="$1"
    local exit_code="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ $exit_code -eq 0 ]]; then
        pass "$test_name"
        return 0
    else
        fail "$test_name - Command failed with exit code: $exit_code"
        return 1
    fi
}

#
# Test: List templates
#
test_list_templates() {
    echo ""
    echo "=== Test: List Templates ==="

    local output=$("$WIZARD_CMD" list 2>&1)
    local exit_code=$?

    assert_command_success "List templates command succeeds" $exit_code

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "Available Agent Templates"; then
        pass "List output contains header"
    else
        fail "List output missing header"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "basic-master"; then
        pass "List includes basic-master template"
    else
        fail "List missing basic-master template"
    fi
}

#
# Test: Show template
#
test_show_template() {
    echo ""
    echo "=== Test: Show Template ==="

    local output=$("$WIZARD_CMD" show basic-master 2>&1)
    local exit_code=$?

    assert_command_success "Show template command succeeds" $exit_code

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "Template: basic-master"; then
        pass "Show output contains template name"
    else
        fail "Show output missing template name"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "Customization Parameters"; then
        pass "Show output includes parameters section"
    else
        fail "Show output missing parameters section"
    fi
}

#
# Test: Generate basic master agent
#
test_generate_basic_master() {
    echo ""
    echo "=== Test: Generate Basic Master Agent ==="

    local agent_name="test-basic-master"
    local output=$("$WIZARD_CMD" generate basic-master \
        agent_name="$agent_name" \
        description="Test master agent" \
        routing_algorithm=capability_match 2>&1)
    local exit_code=$?

    assert_command_success "Generate command succeeds" $exit_code

    local script_path="$PROJECT_ROOT/coordination/masters/$agent_name/${agent_name}.sh"
    local config_path="$PROJECT_ROOT/coordination/masters/$agent_name/config.json"

    assert_file_exists "$script_path" "Script file created"
    assert_file_exists "$config_path" "Config file created"

    # Verify script content
    assert_file_contains "$script_path" "#!/usr/bin/env bash" "Script has shebang"
    assert_file_contains "$script_path" "$agent_name" "Script contains agent name"
    assert_file_contains "$script_path" "Test master agent" "Script contains description"
    assert_file_contains "$script_path" "register_agent" "Script registers agent"

    # Verify config content
    assert_file_contains "$config_path" "routing_algorithm" "Config has routing algorithm"
    assert_file_contains "$config_path" "capability_match" "Config has correct algorithm value"
    assert_file_contains "$config_path" "confidence_threshold" "Config has confidence threshold"

    # Verify script is executable
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -x "$script_path" ]]; then
        pass "Script is executable"
    else
        fail "Script is not executable"
    fi
}

#
# Test: Generate analysis worker
#
test_generate_analysis_worker() {
    echo ""
    echo "=== Test: Generate Analysis Worker ==="

    local agent_name="test-analysis-worker"
    local output=$("$WIZARD_CMD" generate analysis-worker \
        agent_name="$agent_name" \
        description="Test analysis worker" 2>&1)
    local exit_code=$?

    assert_command_success "Generate worker command succeeds" $exit_code

    local script_path="$PROJECT_ROOT/coordination/workers/$agent_name/${agent_name}.sh"
    local config_path="$PROJECT_ROOT/coordination/workers/$agent_name/config.json"

    assert_file_exists "$script_path" "Worker script created"
    assert_file_exists "$config_path" "Worker config created"

    assert_file_contains "$script_path" "analysis-worker" "Worker has correct agent class"
    assert_file_contains "$config_path" "analysis_types" "Config has analysis types"
}

#
# Test: Generate monitoring daemon
#
test_generate_monitoring_daemon() {
    echo ""
    echo "=== Test: Generate Monitoring Daemon ==="

    local agent_name="test-monitor"
    local output=$("$WIZARD_CMD" generate monitoring-daemon \
        agent_name="$agent_name" \
        description="Test monitoring daemon" \
        check_interval=30 2>&1)
    local exit_code=$?

    assert_command_success "Generate daemon command succeeds" $exit_code

    local script_path="$PROJECT_ROOT/scripts/daemons/${agent_name}-daemon.sh"
    local config_path="$PROJECT_ROOT/coordination/config/${agent_name}-config.json"

    assert_file_exists "$script_path" "Daemon script created"
    assert_file_exists "$config_path" "Daemon config created"

    assert_file_contains "$script_path" "daemon" "Script contains daemon reference"
    assert_file_contains "$config_path" "check_interval" "Config has check interval"
    assert_file_contains "$config_path" "30" "Config has correct interval value"
}

#
# Test: Generate test worker
#
test_generate_test_worker() {
    echo ""
    echo "=== Test: Generate Test Worker ==="

    local agent_name="test-runner"
    local output=$("$WIZARD_CMD" generate test-worker \
        agent_name="$agent_name" \
        description="Test execution worker" 2>&1)
    local exit_code=$?

    assert_command_success "Generate test worker command succeeds" $exit_code

    local script_path="$PROJECT_ROOT/coordination/workers/$agent_name/${agent_name}.sh"

    assert_file_exists "$script_path" "Test worker script created"
    assert_file_contains "$script_path" "test-worker" "Script has test-worker class"
}

#
# Test: Generate learning agent
#
test_generate_learning_agent() {
    echo ""
    echo "=== Test: Generate Learning Agent ==="

    local agent_name="test-learner"
    local output=$("$WIZARD_CMD" generate learning-agent \
        agent_name="$agent_name" \
        description="Test learning agent" \
        learning_rate=0.05 2>&1)
    local exit_code=$?

    assert_command_success "Generate learning agent command succeeds" $exit_code

    local script_path="$PROJECT_ROOT/llm-mesh/agents/$agent_name/${agent_name}.sh"
    local config_path="$PROJECT_ROOT/llm-mesh/agents/$agent_name/learning-config.json"

    assert_file_exists "$script_path" "Learning agent script created"
    assert_file_exists "$config_path" "Learning config created"

    assert_file_contains "$script_path" "learning" "Script contains learning reference"
    assert_file_contains "$config_path" "learning_rate" "Config has learning rate"
    assert_file_contains "$config_path" "0.05" "Config has correct learning rate"
}

#
# Test: Default value substitution
#
test_default_values() {
    echo ""
    echo "=== Test: Default Value Substitution ==="

    local agent_name="test-defaults"
    "$WIZARD_CMD" generate basic-master \
        agent_name="$agent_name" \
        description="Test defaults" >/dev/null 2>&1

    local config_path="$PROJECT_ROOT/coordination/masters/$agent_name/config.json"

    assert_file_exists "$config_path" "Config file created for defaults test"

    # Check that default values were applied
    assert_file_contains "$config_path" "max_concurrent_tasks" "Default max_concurrent_tasks applied"
    assert_file_contains "$config_path" "timeout_seconds" "Default timeout_seconds applied"
    assert_file_contains "$config_path" "confidence_threshold" "Default confidence_threshold applied"
}

#
# Test: Error handling - missing required parameter
#
test_error_missing_parameter() {
    echo ""
    echo "=== Test: Error Handling - Missing Parameter ==="

    local output=$("$WIZARD_CMD" generate basic-master description="No agent name" 2>&1)
    local exit_code=$?

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ $exit_code -ne 0 ]]; then
        pass "Command fails without agent_name"
    else
        fail "Command should fail without agent_name"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q -i "agent_name.*required"; then
        pass "Error message mentions required agent_name"
    else
        fail "Error message should mention required agent_name"
    fi
}

#
# Test: Error handling - invalid template
#
test_error_invalid_template() {
    echo ""
    echo "=== Test: Error Handling - Invalid Template ==="

    local output=$("$WIZARD_CMD" generate nonexistent-template agent_name=test 2>&1)
    local exit_code=$?

    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ $exit_code -ne 0 ]]; then
        pass "Command fails with invalid template"
    else
        fail "Command should fail with invalid template"
    fi
}

#
# Test: Template validation
#
test_template_validation() {
    echo ""
    echo "=== Test: Template Validation ==="

    local output=$("$VALIDATOR_CMD" all 2>&1)
    local exit_code=$?

    assert_command_success "Validation command succeeds" $exit_code

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "Total templates: 5"; then
        pass "All 5 templates found"
    else
        fail "Should find 5 templates"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | grep -q "Passed: 5"; then
        pass "All templates pass validation"
    else
        fail "All templates should pass validation"
    fi
}

#
# Main test runner
#
run_tests() {
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║           AGENT WIZARD TEST SUITE                              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    setup

    # Run tests
    test_list_templates
    test_show_template
    test_generate_basic_master
    test_generate_analysis_worker
    test_generate_monitoring_daemon
    test_generate_test_worker
    test_generate_learning_agent
    test_default_values
    test_error_missing_parameter
    test_error_invalid_template
    test_template_validation

    cleanup

    # Print summary
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                      TEST SUMMARY                              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    local pass_rate=0
    if [[ $TESTS_RUN -gt 0 ]]; then
        pass_rate=$((TESTS_PASSED * 100 / TESTS_RUN))
    fi

    echo "Pass rate: ${pass_rate}%"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        return 1
    fi
}

# Run tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
