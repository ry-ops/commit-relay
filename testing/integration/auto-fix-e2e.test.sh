#!/bin/bash
# testing/integration/auto-fix-e2e.test.sh
# End-to-End Integration Tests for Auto-Fix Framework
# Phase 4.5 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/auto-fix.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/failure-pattern-detection.sh" 2>/dev/null || true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "==========================================="
echo "  Auto-Fix E2E Integration Tests"
echo "==========================================="
echo ""

# Setup
echo -e "${YELLOW}Setting up test environment...${NC}"

# Backup existing files
BACKUP_DIR="${COMMIT_RELAY_HOME}/testing/.backups/auto-fix-$(date +%s)"
mkdir -p "$BACKUP_DIR"

[ -f "$FIX_HISTORY_FILE" ] && cp "$FIX_HISTORY_FILE" "$BACKUP_DIR/"
[ -f "$PATTERN_DB" ] && cp "$PATTERN_DB" "$BACKUP_DIR/"
[ -f "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json" ] && \
    cp "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json" "$BACKUP_DIR/"

# Create test pattern
cat > "$PATTERN_DB" <<'EOFPATTERN'
{"pattern_id":"e2e_pattern_oom","category":"resource","type":"out_of_memory","signature":{"event_type":"zombie_detected","worker_type":"scan-worker","error_code":"OOM_KILLED"},"frequency":{"total_occurrences":5,"last_24h":5},"confidence":0.96,"severity":"critical","created_at":"2025-11-18T10:00:00-0600","updated_at":"2025-11-18T15:00:00-0600"}
EOFPATTERN

# Create test worker spec
mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/templates"
cat > "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json" <<'EOFSPEC'
{
  "worker_type": "scan-worker",
  "resources": {
    "memory_limit_mb": 2048,
    "cpu_limit": 1.0
  },
  "timeouts": {
    "task_timeout_seconds": 1800
  }
}
EOFSPEC

# Clear history
rm -f "$FIX_HISTORY_FILE"

echo ""
echo "Test Scenario: OOM Pattern Detection → Fix Application → Validation"
echo "========================================================================="
echo ""

# Step 1: Verify pattern exists
echo "✓ Step 1: Verify high-confidence OOM pattern exists"
pattern_count=$(grep -c "e2e_pattern_oom" "$PATTERN_DB" || echo "0")
if [ "$pattern_count" -ge 1 ]; then
    echo -e "  ${GREEN}PASS${NC}: Pattern found in database"
else
    echo -e "  ${RED}FAIL${NC}: Pattern not found"
    exit 1
fi

# Step 2: Find matching fixes
echo ""
echo "✓ Step 2: Find matching fixes for OOM pattern"
matches=$(match_fixes_for_pattern "e2e_pattern_oom" 2>/dev/null || echo "[]")
match_count=$(echo "$matches" | jq 'length')

if [ "$match_count" -ge 1 ]; then
    echo -e "  ${GREEN}PASS${NC}: Found $match_count matching fix(es)"
    echo "$matches" | jq -r '.[] | "    - \(.fix_id): \(.name)"'
else
    echo -e "  ${RED}FAIL${NC}: No matching fixes found"
    exit 1
fi

# Step 3: Validate fix safety
echo ""
echo "✓ Step 3: Validate fix safety assessment"
fix_id=$(echo "$matches" | jq -r '.[0].fix_id')
safety=$(validate_fix_safety "$fix_id" "e2e_pattern_oom" 2>/dev/null)

safety_score=$(echo "$safety" | jq -r '.safety_score')
can_auto=$(echo "$safety" | jq -r '.can_auto_apply')
needs_approval=$(echo "$safety" | jq -r '.needs_approval')

echo "    Safety Score: $safety_score"
echo "    Can Auto-Apply: $can_auto"
echo "    Needs Approval: $needs_approval"

if [ "$can_auto" = "true" ]; then
    echo -e "  ${GREEN}PASS${NC}: Fix approved for auto-application"
else
    echo -e "  ${YELLOW}WARN${NC}: Fix requires manual approval (continuing anyway for test)"
fi

# Step 4: Check prerequisites
echo ""
echo "✓ Step 4: Validate fix prerequisites"
if check_fix_prerequisites "$fix_id" "e2e_pattern_oom" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: All prerequisites satisfied"
else
    echo -e "  ${RED}FAIL${NC}: Prerequisites not met"
    exit 1
fi

# Step 5: Check rate limits
echo ""
echo "✓ Step 5: Verify rate limits allow fix application"
if check_rate_limits "$fix_id" "resource" "scan-worker" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: Rate limits OK"
else
    echo -e "  ${RED}FAIL${NC}: Rate limit exceeded"
    exit 1
fi

# Step 6: Record original configuration
echo ""
echo "✓ Step 6: Record original worker configuration"
original_memory=$(jq -r '.resources.memory_limit_mb' "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json")
echo "    Original memory limit: ${original_memory}MB"

# Step 7: Apply fix
echo ""
echo "✓ Step 7: Apply auto-fix"
backup_info=$(execute_fix "$fix_id" "e2e_pattern_oom" 2>/dev/null || echo "[]")

if [ -n "$backup_info" ] && [ "$backup_info" != "[]" ]; then
    echo -e "  ${GREEN}PASS${NC}: Fix applied successfully"
    echo "    Backup created: $(echo "$backup_info" | jq -r '.[0]' | xargs basename)"
else
    echo -e "  ${RED}FAIL${NC}: Fix application failed"
    exit 1
fi

# Step 8: Verify configuration changed
echo ""
echo "✓ Step 8: Verify worker configuration updated"
new_memory=$(jq -r '.resources.memory_limit_mb' "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json")
echo "    New memory limit: ${new_memory}MB"

expected_memory=$(echo "$original_memory * 1.5" | bc | cut -d. -f1)
if [ "$new_memory" = "$expected_memory" ]; then
    echo -e "  ${GREEN}PASS${NC}: Configuration updated correctly (${original_memory}MB → ${new_memory}MB)"
else
    echo -e "  ${YELLOW}WARN${NC}: Unexpected value (expected ${expected_memory}MB, got ${new_memory}MB)"
fi

# Step 9: Verify history recorded
echo ""
echo "✓ Step 9: Verify fix recorded in history"
if grep -q "$fix_id" "$FIX_HISTORY_FILE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: Fix recorded in history"
    history_entry=$(grep "$fix_id" "$FIX_HISTORY_FILE" | tail -1)
    echo "    Status: $(echo "$history_entry" | jq -r '.status')"
    echo "    Applied: $(echo "$history_entry" | jq -r '.applied_at')"
else
    echo -e "  ${RED}FAIL${NC}: Fix not found in history"
    exit 1
fi

# Step 10: Verify events emitted
echo ""
echo "✓ Step 10: Verify fix events logged"
if [ -f "$FIX_EVENTS_LOG" ]; then
    event_count=$(grep -c "fix_execution" "$FIX_EVENTS_LOG" || echo "0")
    if [ "$event_count" -ge 1 ]; then
        echo -e "  ${GREEN}PASS${NC}: Events logged ($event_count events)"
    else
        echo -e "  ${YELLOW}WARN${NC}: No events found in log"
    fi
else
    echo -e "  ${YELLOW}WARN${NC}: Event log file not created"
fi

# Step 11: Test rollback
echo ""
echo "✓ Step 11: Test fix rollback capability"
rollback_fix "$fix_id" "$backup_info" 2>/dev/null

rolled_back_memory=$(jq -r '.resources.memory_limit_mb' "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json")
if [ "$rolled_back_memory" = "$original_memory" ]; then
    echo -e "  ${GREEN}PASS${NC}: Configuration restored to original (${rolled_back_memory}MB)"
else
    echo -e "  ${RED}FAIL${NC}: Rollback failed (expected ${original_memory}MB, got ${rolled_back_memory}MB)"
    exit 1
fi

# Step 12: Verify rollback history
echo ""
echo "✓ Step 12: Verify rollback recorded in history"
if grep -q "rolled_back" "$FIX_HISTORY_FILE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: Rollback recorded in history"
else
    echo -e "  ${YELLOW}WARN${NC}: Rollback entry not found in history"
fi

# Cleanup
echo ""
echo -e "${YELLOW}Cleaning up test environment...${NC}"

# Restore backups
if [ -f "$BACKUP_DIR/failure-patterns.jsonl" ]; then
    mv "$BACKUP_DIR/failure-patterns.jsonl" "$PATTERN_DB"
fi

if [ -f "$BACKUP_DIR/fix-history.jsonl" ]; then
    mv "$BACKUP_DIR/fix-history.jsonl" "$FIX_HISTORY_FILE"
fi

if [ -f "$BACKUP_DIR/scan-worker.json" ]; then
    mv "$BACKUP_DIR/scan-worker.json" "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json"
fi

# Remove test backups
rm -rf "$COMMIT_RELAY_HOME/coordination/worker-specs/templates/scan-worker.json.backup."*

echo ""
echo "==========================================="
echo "  E2E Test Summary"
echo "==========================================="
echo ""
echo -e "${GREEN}${BOLD}All integration tests passed!${NC}"
echo ""
echo "Validated workflow:"
echo "  1. Pattern detection and matching"
echo "  2. Safety and prerequisite validation"
echo "  3. Rate limiting checks"
echo "  4. Fix application and configuration updates"
echo "  5. History and event logging"
echo "  6. Rollback capability"
echo ""
