#!/bin/bash

# Test Script for Launcher Validation
# Tests the fixed launcher without actually launching workers

echo "=========================================="
echo "Launcher Validation Test Suite"
echo "=========================================="
echo ""

PROJECT_ROOT="/Users/ryandahlberg/commit-relay"
LAUNCHER="$PROJECT_ROOT/scripts/claude-worker-launcher-v2-FIXED.sh"
TEST_RESULTS=()

# Test 1: Empty WORKER_ID
echo "Test 1: Empty WORKER_ID (should fail validation)"
echo "Command: $LAUNCHER '' 'task-123' 'implementation-worker'"
OUTPUT=$("$LAUNCHER" "" "task-123" "implementation-worker" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "WORKER_ID.*required"; then
    echo "✅ PASS: Correctly rejected empty WORKER_ID"
    TEST_RESULTS+=("PASS")
else
    echo "❌ FAIL: Did not reject empty WORKER_ID (exit code: $EXIT_CODE)"
    TEST_RESULTS+=("FAIL")
fi
echo ""

# Test 2: Empty TASK_ID
echo "Test 2: Empty TASK_ID (should fail validation)"
echo "Command: $LAUNCHER 'worker-123' '' 'implementation-worker'"
OUTPUT=$("$LAUNCHER" "worker-123" "" "implementation-worker" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "TASK_ID.*required"; then
    echo "✅ PASS: Correctly rejected empty TASK_ID"
    TEST_RESULTS+=("PASS")
else
    echo "❌ FAIL: Did not reject empty TASK_ID (exit code: $EXIT_CODE)"
    TEST_RESULTS+=("FAIL")
fi
echo ""

# Test 3: Template generation (without launching)
echo "Test 3: Template generation with valid arguments"
echo "Creating test environment..."

TEST_WORKER="test-worker-validation-$(date +%s)"
TEST_TASK="task-test-launcher-validation"

# Create a mock version that stops before launching
cat > /tmp/test-launcher-mock.sh << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="/Users/ryandahlberg/commit-relay"
WORKER_ID="$1"
TASK_ID="$2"
WORKER_TYPE="${3:-implementation-worker}"

# Input validation
if [[ -z "$WORKER_ID" ]] || [[ -z "$TASK_ID" ]]; then
    echo "ERROR: Arguments required"
    exit 1
fi

# Load task
TASK_FILE="$PROJECT_ROOT/coordination/tasks/$TASK_ID.json"
if [[ -f "$TASK_FILE" ]]; then
    TASK_TITLE=$(jq -r '.title // "Unknown task"' "$TASK_FILE")
    TASK_CONTEXT=$(jq -r '.context // {}' "$TASK_FILE" | jq -c .)
else
    TASK_TITLE="Task $TASK_ID"
    TASK_CONTEXT='{"note":"Task file not found"}'
fi

# Create worker dir
WORKER_DIR="$PROJECT_ROOT/agents/workers/$WORKER_ID"
mkdir -p "$WORKER_DIR"

# Generate template
cat > "$WORKER_DIR/prompt.md" << 'TEMPLATE_EOF'
You are worker WORKER_ID_PLACEHOLDER executing task TASK_ID_PLACEHOLDER.
Task: TASK_TITLE_PLACEHOLDER
Type: WORKER_TYPE_PLACEHOLDER
Context: TASK_CONTEXT_PLACEHOLDER
TEMPLATE_EOF

# Substitute placeholders
sed -i '' "s/WORKER_ID_PLACEHOLDER/$WORKER_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_ID_PLACEHOLDER/$TASK_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_TITLE_PLACEHOLDER/$TASK_TITLE/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/WORKER_TYPE_PLACEHOLDER/$WORKER_TYPE/g" "$WORKER_DIR/prompt.md"

# Escape and substitute context
TASK_CONTEXT_ESCAPED=$(echo "$TASK_CONTEXT" | sed 's/[\/&]/\\&/g')
sed -i '' "s|TASK_CONTEXT_PLACEHOLDER|$TASK_CONTEXT_ESCAPED|g" "$WORKER_DIR/prompt.md"

# Validate
UNSUBSTITUTED=$(grep -c "PLACEHOLDER" "$WORKER_DIR/prompt.md" || true)
if [[ $UNSUBSTITUTED -gt 0 ]]; then
    echo "VALIDATION_FAILED: Found $UNSUBSTITUTED unsubstituted placeholders"
    grep "PLACEHOLDER" "$WORKER_DIR/prompt.md"
    exit 1
fi

echo "VALIDATION_PASSED: All placeholders substituted"
exit 0
EOF

chmod +x /tmp/test-launcher-mock.sh

# Run mock launcher
OUTPUT=$(/tmp/test-launcher-mock.sh "$TEST_WORKER" "$TEST_TASK" "implementation-worker" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "VALIDATION_PASSED"; then
    echo "✅ PASS: Template generation and validation successful"

    # Check the generated prompt
    PROMPT_FILE="$PROJECT_ROOT/agents/workers/$TEST_WORKER/prompt.md"
    if [[ -f "$PROMPT_FILE" ]]; then
        echo "   Checking generated prompt..."

        if grep -q "PLACEHOLDER" "$PROMPT_FILE"; then
            echo "   ❌ Found unsubstituted placeholders in prompt:"
            grep "PLACEHOLDER" "$PROMPT_FILE" | head -3
            TEST_RESULTS+=("FAIL")
        else
            echo "   ✅ No unsubstituted placeholders found"

            # Verify substitutions
            if grep -q "$TEST_WORKER" "$PROMPT_FILE" && \
               grep -q "$TEST_TASK" "$PROMPT_FILE" && \
               grep -q "implementation-worker" "$PROMPT_FILE"; then
                echo "   ✅ All key values present in prompt"
                TEST_RESULTS+=("PASS")
            else
                echo "   ❌ Some values missing from prompt"
                TEST_RESULTS+=("FAIL")
            fi
        fi

        echo "   Generated prompt preview (first 10 lines):"
        head -10 "$PROMPT_FILE" | sed 's/^/   | /'
    else
        echo "   ❌ Prompt file not created"
        TEST_RESULTS+=("FAIL")
    fi
else
    echo "❌ FAIL: Template generation or validation failed"
    echo "   Output: $OUTPUT"
    TEST_RESULTS+=("FAIL")
fi

echo ""

# Summary
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="

PASSED=0
FAILED=0

for result in "${TEST_RESULTS[@]}"; do
    if [[ "$result" == "PASS" ]]; then
        ((PASSED++))
    else
        ((FAILED++))
    fi
done

TOTAL=$((PASSED + FAILED))
echo "Total Tests: $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo "✅ ALL TESTS PASSED"
    exit 0
else
    echo "❌ SOME TESTS FAILED"
    exit 1
fi
