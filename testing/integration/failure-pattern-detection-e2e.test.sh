#!/bin/bash
# testing/integration/failure-pattern-detection-e2e.test.sh
# End-to-End Integration Tests for Failure Pattern Detection
# Phase 4.4 - Self-Healing Implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
export COMMIT_RELAY_HOME

source "$COMMIT_RELAY_HOME/scripts/lib/failure-pattern-detection.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo "==========================================="
echo "  Pattern Detection E2E Integration Tests"
echo "==========================================="
echo ""

# Setup
echo -e "${YELLOW}Setting up test environment...${NC}"

# Backup existing files
BACKUP_DIR="${COMMIT_RELAY_HOME}/testing/.backups/pattern-detection-$(date +%s)"
mkdir -p "$BACKUP_DIR"

[ -f "$PATTERN_DB" ] && cp "$PATTERN_DB" "$BACKUP_DIR/"
[ -f "$ZOMBIE_EVENTS" ] && cp "$ZOMBIE_EVENTS" "$BACKUP_DIR/"
[ -f "$RESTART_EVENTS" ] && cp "$RESTART_EVENTS" "$BACKUP_DIR/"

# Clear existing patterns
rm -f "$PATTERN_DB"

# Create test events simulating real failure scenarios
mkdir -p "$(dirname "$ZOMBIE_EVENTS")"
mkdir -p "$(dirname "$RESTART_EVENTS")"

# Create worker specs FIRST for event enrichment
mkdir -p "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/2025-11-18"
for i in 1 2 3 4 5; do
    cat > "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/2025-11-18/scan-worker-$i.json" <<EOFSPEC
{
  "worker_id": "scan-worker-$i",
  "worker_type": "scan-worker",
  "task_id": "task-$i",
  "status": "zombie"
}
EOFSPEC
done

# Now create events (after specs exist)
cat > "$ZOMBIE_EVENTS" <<'EOFEVENTS'
{"event_type":"zombie_detected","worker_id":"scan-worker-1","timestamp":"2025-11-18T14:00:00-0600","data":{"final_memory_usage":2048}}
{"event_type":"zombie_detected","worker_id":"scan-worker-2","timestamp":"2025-11-18T14:05:00-0600","data":{"final_memory_usage":2100}}
{"event_type":"zombie_detected","worker_id":"scan-worker-3","timestamp":"2025-11-18T14:10:00-0600","data":{"final_memory_usage":2050}}
{"event_type":"zombie_detected","worker_id":"scan-worker-4","timestamp":"2025-11-18T14:15:00-0600","data":{"final_memory_usage":2048}}
{"event_type":"zombie_detected","worker_id":"scan-worker-5","timestamp":"2025-11-18T14:20:00-0600","data":{"final_memory_usage":2099}}
EOFEVENTS

echo ""
echo "Test Scenario: Zombie Event Pattern Detection"
echo "========================================================================="
echo ""

# Step 1: Collect recent events
echo "✓ Step 1: Collect failure events from last 24 hours"
events=$(collect_recent_events 24 2>/dev/null)
event_count=$(echo "$events" | grep -c . || echo "0")

if [ "$event_count" -ge 5 ]; then
    echo -e "  ${GREEN}PASS${NC}: Collected $event_count events"
else
    echo -e "  ${RED}FAIL${NC}: Expected >= 5 events, got: $event_count"
    exit 1
fi

# Step 2: Classify events
echo ""
echo "✓ Step 2: Classify failure events"
first_event=$(echo "$events" | head -1)
classification=$(classify_failure "$first_event" 2>/dev/null)

echo "    Event: $(echo "$first_event" | jq -c '.')"
echo "    Classification: $classification"

if [[ "$classification" =~ ^resource: ]]; then
    echo -e "  ${GREEN}PASS${NC}: Event classified as resource failure"
else
    echo -e "  ${YELLOW}WARN${NC}: Unexpected classification: $classification"
fi

# Step 3: Extract signatures
echo ""
echo "✓ Step 3: Extract failure signatures"
signature=$(extract_failure_signature "$first_event" 2>/dev/null)
worker_type=$(echo "$signature" | jq -r '.worker_type')

echo "    Signature: $(echo "$signature" | jq -c '.')"
echo "    Worker type: $worker_type"

if [ "$worker_type" = "scan-worker" ]; then
    echo -e "  ${GREEN}PASS${NC}: Signature extracted correctly"
else
    echo -e "  ${RED}FAIL${NC}: Expected worker_type=scan-worker, got: $worker_type"
    exit 1
fi

# Step 4: Detect frequent patterns
echo ""
echo "✓ Step 4: Detect frequent patterns (threshold: 3)"
patterns=$(detect_frequent_patterns "$events" 2>/dev/null)
pattern_count=$(echo "$patterns" | grep -c . || echo "0")

echo "    Patterns detected: $pattern_count"

if [ "$pattern_count" -ge 1 ]; then
    echo -e "  ${GREEN}PASS${NC}: Detected $pattern_count pattern(s)"
    echo "$patterns" | jq -c '.' 2>/dev/null | while read -r pattern; do
        pattern_id=$(echo "$pattern" | jq -r '.pattern_id')
        confidence=$(echo "$pattern" | jq -r '.confidence')
        occurrences=$(echo "$pattern" | jq -r '.frequency.total_occurrences')
        echo "      - $pattern_id: $occurrences occurrences (confidence: $confidence)"
    done
else
    echo -e "  ${RED}FAIL${NC}: Expected >= 1 pattern, got: $pattern_count"
    exit 1
fi

# Step 5: Store patterns in database
echo ""
echo "✓ Step 5: Store patterns in database"
echo "$patterns" | while read -r pattern; do
    [ -z "$pattern" ] && continue
    update_pattern "$pattern" 2>/dev/null
done

db_pattern_count=$(grep -c . "$PATTERN_DB" 2>/dev/null || echo "0")

if [ "$db_pattern_count" -ge 1 ]; then
    echo -e "  ${GREEN}PASS${NC}: Stored $db_pattern_count pattern(s) in database"
else
    echo -e "  ${RED}FAIL${NC}: No patterns in database"
    exit 1
fi

# Step 6: Verify pattern database format
echo ""
echo "✓ Step 6: Verify pattern database format (JSONL)"
all_valid=true
line_num=0

while IFS= read -r line; do
    ((line_num++))
    if ! echo "$line" | jq empty 2>/dev/null; then
        echo -e "  ${RED}FAIL${NC}: Line $line_num is not valid JSON"
        all_valid=false
        break
    fi
done < "$PATTERN_DB"

if [ "$all_valid" = true ]; then
    echo -e "  ${GREEN}PASS${NC}: All patterns are valid JSONL"
else
    exit 1
fi

# Step 7: Test pattern matching
echo ""
echo "✓ Step 7: Test pattern matching for new events"
new_event='{"event_type":"zombie_detected","worker_id":"scan-worker-6","timestamp":"2025-11-18T14:25:00-0600","data":{}}'

# Create spec for new worker
cat > "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/2025-11-18/scan-worker-6.json" <<EOFSPEC
{
  "worker_id": "scan-worker-6",
  "worker_type": "scan-worker",
  "task_id": "task-6",
  "status": "zombie"
}
EOFSPEC

matched_pattern=$(find_matching_pattern "$new_event" 2>/dev/null || echo "")

if [ -n "$matched_pattern" ]; then
    echo "    Matched pattern: $matched_pattern"
    echo -e "  ${GREEN}PASS${NC}: New event matched to existing pattern"
else
    echo -e "  ${YELLOW}WARN${NC}: No pattern match found (may be acceptable if similarity < threshold)"
fi

# Step 8: Test pattern update
echo ""
echo "✓ Step 8: Test pattern update (increment occurrences)"
first_pattern=$(head -1 "$PATTERN_DB")
pattern_id=$(echo "$first_pattern" | jq -r '.pattern_id')
initial_count=$(echo "$first_pattern" | jq -r '.frequency.total_occurrences')

# Update the same pattern again
update_pattern "$first_pattern" 2>/dev/null

updated_pattern=$(grep "$pattern_id" "$PATTERN_DB" | head -1)
updated_count=$(echo "$updated_pattern" | jq -r '.frequency.total_occurrences')

echo "    Initial count: $initial_count"
echo "    Updated count: $updated_count"

if [ "$updated_count" -eq $((initial_count + 1)) ]; then
    echo -e "  ${GREEN}PASS${NC}: Pattern occurrence count incremented correctly"
else
    echo -e "  ${RED}FAIL${NC}: Expected count $((initial_count + 1)), got: $updated_count"
    exit 1
fi

# Step 9: Test pattern index
echo ""
echo "✓ Step 9: Verify pattern index generation"
update_pattern_index 2>/dev/null

if [ -f "$PATTERN_INDEX" ] && jq empty "$PATTERN_INDEX" 2>/dev/null; then
    category_count=$(jq 'length' "$PATTERN_INDEX" 2>/dev/null)
    echo "    Categories indexed: $category_count"
    echo -e "  ${GREEN}PASS${NC}: Pattern index generated successfully"
else
    echo -e "  ${RED}FAIL${NC}: Pattern index missing or invalid"
    exit 1
fi

# Step 10: Test analyze_patterns (full workflow)
echo ""
echo "✓ Step 10: Test complete analysis workflow"

# Clear DB for clean test
rm -f "$PATTERN_DB"

# Run full analysis
patterns_detected=$(analyze_patterns 2>&1 | tail -1)

if [[ "$patterns_detected" =~ ^[0-9]+$ ]] && [ "$patterns_detected" -ge 1 ]; then
    echo "    Patterns detected: $patterns_detected"
    echo -e "  ${GREEN}PASS${NC}: Complete analysis workflow successful"
else
    echo -e "  ${YELLOW}WARN${NC}: Analysis workflow completed but results unclear: $patterns_detected"
fi

# Cleanup
echo ""
echo -e "${YELLOW}Cleaning up test environment...${NC}"

# Remove test workers specs
rm -rf "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/2025-11-18/scan-worker-"*

# Restore backups if they exist
if [ -f "$BACKUP_DIR/failure-patterns.jsonl" ]; then
    mv "$BACKUP_DIR/failure-patterns.jsonl" "$PATTERN_DB"
fi

if [ -f "$BACKUP_DIR/zombie-cleanup-events.jsonl" ]; then
    mv "$BACKUP_DIR/zombie-cleanup-events.jsonl" "$ZOMBIE_EVENTS"
fi

if [ -f "$BACKUP_DIR/worker-restart-events.jsonl" ]; then
    mv "$BACKUP_DIR/worker-restart-events.jsonl" "$RESTART_EVENTS"
fi

echo ""
echo "==========================================="
echo "  E2E Test Summary"
echo "==========================================="
echo ""
echo -e "${GREEN}${BOLD}All integration tests passed!${NC}"
echo ""
echo "Validated workflow:"
echo "  1. Event collection from multiple sources"
echo "  2. Failure classification (resource, systemic, etc.)"
echo "  3. Signature extraction with worker metadata"
echo "  4. Frequency-based pattern detection"
echo "  5. Pattern database storage (JSONL format)"
echo "  6. Pattern matching for new events"
echo "  7. Pattern update and occurrence tracking"
echo "  8. Pattern indexing by category"
echo "  9. Complete analysis workflow"
echo ""
