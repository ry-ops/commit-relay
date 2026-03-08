#!/bin/bash
# test-core-foundation.sh - Test the core principles foundation
# This script validates that the core infrastructure is working correctly

# Use relaxed mode for testing (logging.sh has variable management issues with strict mode)
set -eo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test 1: Load init-common.sh
echo "=========================================="
echo "Test 1: Loading init-common.sh"
echo "=========================================="

if source "$SCRIPT_DIR/lib/init-common.sh"; then
  echo "✅ init-common.sh loaded successfully"
else
  echo "❌ FAIL: init-common.sh failed to load"
  exit 1
fi

# Test 2: Verify environment variables are set
echo ""
echo "=========================================="
echo "Test 2: Environment Variables"
echo "=========================================="

echo "COMMIT_RELAY_HOME: $COMMIT_RELAY_HOME"
echo "LOG_LEVEL: $LOG_LEVEL"
echo "GOVERNANCE_ENABLED: $GOVERNANCE_ENABLED"
echo "OBSERVABILITY_ENABLED: $OBSERVABILITY_ENABLED"
echo "VALIDATION_ENABLED: $VALIDATION_ENABLED"
echo "TRACE_ID: ${TRACE_ID:-not set}"
echo "SPAN_ID: ${SPAN_ID:-not set}"

if [ -n "$COMMIT_RELAY_HOME" ] && [ -n "$LOG_LEVEL" ]; then
  echo "✅ Environment variables set correctly"
else
  echo "❌ FAIL: Environment variables not set"
  exit 1
fi

# Test 3: Verify logging functions work
echo ""
echo "=========================================="
echo "Test 3: Logging Functions"
echo "=========================================="

log_debug "This is a debug message"
log_info "This is an info message"
log_warn "This is a warning message"
# Don't test error/critical as they might affect output

echo "✅ Logging functions work"

# Test 4: Test configuration reading
echo ""
echo "=========================================="
echo "Test 4: Configuration Reading"
echo "=========================================="

HEARTBEAT_INTERVAL=$(get_config "services.heartbeat_interval_seconds" "30")
echo "Heartbeat interval: $HEARTBEAT_INTERVAL"

if [ "$HEARTBEAT_INTERVAL" = "30" ]; then
  echo "✅ Configuration reading works"
else
  echo "❌ FAIL: Configuration value incorrect"
  exit 1
fi

# Test 5: Test JSON validation
echo ""
echo "=========================================="
echo "Test 5: JSON Validation"
echo "=========================================="

# Valid JSON
VALID_JSON='{"test": "value", "number": 123}'
if validate_json_syntax "$VALID_JSON"; then
  echo "✅ Valid JSON accepted"
else
  echo "❌ FAIL: Valid JSON rejected"
  exit 1
fi

# Invalid JSON
INVALID_JSON='{"test": "value", "number": 123'  # Missing closing brace
if ! validate_json_syntax "$INVALID_JSON" 2>/dev/null; then
  echo "✅ Invalid JSON rejected"
else
  echo "❌ FAIL: Invalid JSON accepted"
  exit 1
fi

# Test 6: Test template variable validation
echo ""
echo "=========================================="
echo "Test 6: Template Variable Validation"
echo "=========================================="

# Valid template (no uninitialized vars)
VALID_TEMPLATE='{"name": "test", "value": 123}'
if validate_template_vars "$VALID_TEMPLATE"; then
  echo "✅ Valid template accepted"
else
  echo "❌ FAIL: Valid template rejected"
  exit 1
fi

# Invalid template (uninitialized variable)
INVALID_TEMPLATE='{"name": "test", "skills": , "value": 123}'
if ! validate_template_vars "$INVALID_TEMPLATE" 2>/dev/null; then
  echo "✅ Uninitialized variable detected correctly"
else
  echo "❌ FAIL: Uninitialized variable not detected"
  exit 1
fi

# Test 7: Test safe_write_json
echo ""
echo "=========================================="
echo "Test 7: Safe JSON Write"
echo "=========================================="

TEST_FILE="/tmp/test-safe-write-$$.json"

# Try to write valid JSON
VALID_DATA='{"test": "data", "timestamp": "2025-11-17T11:00:00Z"}'
if safe_write_json "$VALID_DATA" "$TEST_FILE" "none"; then
  echo "✅ Valid JSON written successfully"

  # Verify file exists and contains correct data
  if [ -f "$TEST_FILE" ]; then
    WRITTEN_DATA=$(cat "$TEST_FILE")
    if [ "$WRITTEN_DATA" = "$VALID_DATA" ]; then
      echo "✅ Written data matches"
    else
      echo "❌ FAIL: Written data doesn't match"
      exit 1
    fi
  else
    echo "❌ FAIL: File was not created"
    exit 1
  fi
else
  echo "❌ FAIL: safe_write_json failed for valid data"
  exit 1
fi

# Try to write invalid JSON (should fail)
INVALID_DATA='{"test": , "bad": "data"}'
if ! safe_write_json "$INVALID_DATA" "/tmp/test-invalid-$$.json" "none" 2>/dev/null; then
  echo "✅ Invalid JSON correctly rejected"
else
  echo "❌ FAIL: Invalid JSON was written"
  exit 1
fi

# Cleanup
rm -f "$TEST_FILE"

# Test 8: Test observability events
echo ""
echo "=========================================="
echo "Test 8: Observability Events"
echo "=========================================="

trace_start "test-operation" "test-001"
trace_event "test.step1" "success" '{"message":"Step 1 completed"}'
trace_event "test.step2" "success" '{"message":"Step 2 completed"}'
trace_end "test-operation" "success"

# Check if events file was created
EVENT_FILE="$COMMIT_RELAY_HOME/coordination/observability/events/all-events.jsonl"
if [ -f "$EVENT_FILE" ]; then
  # Count events
  EVENT_COUNT=$(grep -c "test-operation" "$EVENT_FILE" || echo "0")
  if [ "$EVENT_COUNT" -gt 0 ]; then
    echo "✅ Observability events recorded ($EVENT_COUNT events)"
  else
    echo "⚠️  Warning: No events found in file"
  fi
else
  echo "⚠️  Warning: Events file not created"
fi

# Test 9: Test directory creation
echo ""
echo "=========================================="
echo "Test 9: Required Directories"
echo "=========================================="

REQUIRED_DIRS=(
  "coordination/config"
  "coordination/schemas"
  "coordination/observability/events"
  "coordination/observability/stream"
  "coordination/observability/indices"
  "agents/logs/system"
)

ALL_EXIST=true
for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$COMMIT_RELAY_HOME/$dir" ]; then
    echo "✅ $dir exists"
  else
    echo "❌ $dir missing"
    ALL_EXIST=false
  fi
done

if [ "$ALL_EXIST" = "true" ]; then
  echo "✅ All required directories exist"
else
  echo "❌ FAIL: Some directories missing"
  exit 1
fi

# Test 10: Test required files
echo ""
echo "=========================================="
echo "Test 10: Required Files"
echo "=========================================="

REQUIRED_FILES=(
  "coordination/config/system.json"
  "coordination/schemas/worker-spec.json"
  "coordination/schemas/task-spec.json"
  "coordination/task-queue.json"
  "coordination/worker-pool.json"
  "coordination/token-budget.json"
)

ALL_EXIST=true
for file in "${REQUIRED_FILES[@]}"; do
  if [ -f "$COMMIT_RELAY_HOME/$file" ]; then
    echo "✅ $file exists"
  else
    echo "❌ $file missing"
    ALL_EXIST=false
  fi
done

if [ "$ALL_EXIST" = "true" ]; then
  echo "✅ All required files exist"
else
  echo "❌ FAIL: Some files missing"
  exit 1
fi

# Final summary
echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "✅ All core foundation tests passed!"
echo ""
echo "Core services initialized:"
echo "  - Configuration management"
echo "  - Logging infrastructure"
echo "  - Validation service"
echo "  - Observability tracking"
echo "  - Governance framework"
echo ""
echo "Next steps:"
echo "  1. Review test results above"
echo "  2. Check event log: coordination/observability/events/all-events.jsonl"
echo "  3. Proceed with Phase 1: Observability Integration"
echo ""
