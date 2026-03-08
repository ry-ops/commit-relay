#!/bin/bash

# Aggregate Worker Results Script
# Used by Execution Managers to collect and synthesize outputs from multiple workers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COORDINATION_DIR="$PROJECT_ROOT/coordination"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
EXEC_MGR_ID=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --exec-mgr-id)
      EXEC_MGR_ID="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$EXEC_MGR_ID" ]; then
  echo -e "${RED}ERROR: --exec-mgr-id is required${NC}"
  echo "Usage: $0 --exec-mgr-id <em-id> [--output <file>]"
  exit 1
fi

# Default output file
if [ -z "$OUTPUT_FILE" ]; then
  OUTPUT_FILE="$COORDINATION_DIR/execution-managers/results/${EXEC_MGR_ID}-result.json"
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Aggregating Worker Results${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Execution Manager: ${GREEN}${EXEC_MGR_ID}${NC}"
echo ""

# Get EM state
EM_STATE_FILE="$COORDINATION_DIR/execution-managers/active/${EXEC_MGR_ID}.json"
if [ ! -f "$EM_STATE_FILE" ]; then
  EM_STATE_FILE="$COORDINATION_DIR/execution-managers/completed/${EXEC_MGR_ID}.json"
fi

if [ ! -f "$EM_STATE_FILE" ]; then
  echo -e "${RED}ERROR: Execution Manager state not found: $EXEC_MGR_ID${NC}"
  exit 1
fi

# Extract EM details
MASTER_TYPE=$(jq -r '.master_type' "$EM_STATE_FILE")
SUBTASK_ID=$(jq -r '.subtask_id' "$EM_STATE_FILE")
STARTED_AT=$(jq -r '.started_at' "$EM_STATE_FILE")

echo -e "${YELLOW}[1/5]${NC} Collecting worker specifications..."

# Find all workers spawned by this EM
WORKER_SPECS=$(find "$COORDINATION_DIR/worker-specs" -name "*.json" -type f -exec grep -l "\"execution_manager\": \"$EXEC_MGR_ID\"" {} \; 2>/dev/null || true)

if [ -z "$WORKER_SPECS" ]; then
  echo -e "${YELLOW}⚠${NC}  No workers found for Execution Manager: $EXEC_MGR_ID"
  WORKERS_SPAWNED=0
  WORKERS_COMPLETED=0
  WORKERS_FAILED=0
else
  WORKERS_SPAWNED=$(echo "$WORKER_SPECS" | wc -l | tr -d ' ')
  
  # Count completed vs failed
  WORKERS_COMPLETED=0
  WORKERS_FAILED=0
  
  for spec in $WORKER_SPECS; do
    status=$(jq -r '.status' "$spec" 2>/dev/null || echo "unknown")
    if [ "$status" = "completed" ]; then
      WORKERS_COMPLETED=$((WORKERS_COMPLETED + 1))
    elif [ "$status" = "failed" ]; then
      WORKERS_FAILED=$((WORKERS_FAILED + 1))
    fi
  done
  
  echo -e "${GREEN}✓${NC} Found $WORKERS_SPAWNED workers ($WORKERS_COMPLETED completed, $WORKERS_FAILED failed)"
fi

echo -e "${YELLOW}[2/5]${NC} Collecting modified files..."

# Aggregate files modified by all workers
FILES_MODIFIED="[]"
if [ -n "$WORKER_SPECS" ]; then
  FILES_MODIFIED=$(for spec in $WORKER_SPECS; do
    jq -r '.results.artifacts[]? | select(.type == "file") | .path' "$spec" 2>/dev/null || true
  done | jq -R . | jq -s 'unique')
fi

FILE_COUNT=$(echo "$FILES_MODIFIED" | jq 'length')
echo -e "${GREEN}✓${NC} Collected $FILE_COUNT modified files"

echo -e "${YELLOW}[3/5]${NC} Collecting git commits..."

# Aggregate git commits from all workers
COMMITS="[]"
if [ -n "$WORKER_SPECS" ]; then
  COMMITS=$(for spec in $WORKER_SPECS; do
    jq -r '.results.artifacts[]? | select(.type == "commit") | .sha' "$spec" 2>/dev/null || true
  done | jq -R . | jq -s 'unique')
fi

COMMIT_COUNT=$(echo "$COMMITS" | jq 'length')
echo -e "${GREEN}✓${NC} Collected $COMMIT_COUNT commits"

echo -e "${YELLOW}[4/5]${NC} Calculating resource usage..."

# Calculate total tokens used
TOKENS_USED=0
if [ -n "$WORKER_SPECS" ]; then
  for spec in $WORKER_SPECS; do
    worker_tokens=$(jq -r '.execution.tokens_used // 0' "$spec" 2>/dev/null || echo 0)
    TOKENS_USED=$((TOKENS_USED + worker_tokens))
  done
fi

# Calculate total duration
COMPLETED_AT=$(date +%Y-%m-%dT%H:%M:%S%z)
START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$STARTED_AT" "+%s" 2>/dev/null || echo 0)
END_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$COMPLETED_AT" "+%s" 2>/dev/null || date +%s)
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
DURATION_MINUTES=$((DURATION_SECONDS / 60))

echo -e "${GREEN}✓${NC} Total tokens used: $TOKENS_USED"
echo -e "${GREEN}✓${NC} Total duration: $DURATION_MINUTES minutes"

echo -e "${YELLOW}[5/5]${NC} Generating aggregated result..."

# Read execution plan for acceptance criteria
PLAN_FILE="$COORDINATION_DIR/masters/$MASTER_TYPE/execution-plans/$SUBTASK_ID.json"
ACCEPTANCE_CRITERIA="[]"
if [ -f "$PLAN_FILE" ]; then
  ACCEPTANCE_CRITERIA=$(jq -r '.acceptance_criteria // []' "$PLAN_FILE")
fi

# Generate acceptance criteria status (simplified - would need actual validation)
CRITERIA_MET="{}"
if [ "$(echo "$ACCEPTANCE_CRITERIA" | jq 'length')" -gt 0 ]; then
  # For now, mark as met if all workers completed successfully
  if [ "$WORKERS_FAILED" -eq 0 ] && [ "$WORKERS_COMPLETED" -gt 0 ]; then
    CRITERIA_MET=$(echo "$ACCEPTANCE_CRITERIA" | jq -r 'map({(.): true}) | add // {}')
  else
    CRITERIA_MET=$(echo "$ACCEPTANCE_CRITERIA" | jq -r 'map({(.): false}) | add // {}')
  fi
fi

# Generate summary from worker results
SUMMARY="Execution Manager $EXEC_MGR_ID completed with $WORKERS_SPAWNED workers. "
SUMMARY+="$WORKERS_COMPLETED succeeded, $WORKERS_FAILED failed. "
SUMMARY+="Modified $FILE_COUNT files across $COMMIT_COUNT commits. "
SUMMARY+="Total resource usage: $TOKENS_USED tokens, $DURATION_MINUTES minutes."

# Create aggregated result JSON
cat > "$OUTPUT_FILE" <<EOF
{
  "exec_mgr_id": "$EXEC_MGR_ID",
  "subtask_id": "$SUBTASK_ID",
  "master_type": "$MASTER_TYPE",
  "status": "completed",
  "execution_summary": {
    "workers_spawned": $WORKERS_SPAWNED,
    "workers_completed": $WORKERS_COMPLETED,
    "workers_failed": $WORKERS_FAILED,
    "duration_minutes": $DURATION_MINUTES,
    "tokens_used": $TOKENS_USED,
    "files_modified": $FILES_MODIFIED,
    "commits": $COMMITS
  },
  "acceptance_criteria_met": $CRITERIA_MET,
  "completion_report": "$SUMMARY",
  "started_at": "$STARTED_AT",
  "completed_at": "$COMPLETED_AT"
}
EOF

# Validate JSON
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo -e "${RED}ERROR: Generated invalid JSON${NC}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Aggregated result saved: $OUTPUT_FILE"

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Result Aggregation Complete${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}Summary:${NC}"
echo -e "  Workers: $WORKERS_SPAWNED total ($WORKERS_COMPLETED completed, $WORKERS_FAILED failed)"
echo -e "  Files Modified: $FILE_COUNT"
echo -e "  Commits: $COMMIT_COUNT"
echo -e "  Tokens Used: $TOKENS_USED"
echo -e "  Duration: $DURATION_MINUTES minutes"
echo -e "  Result File: ${BLUE}$OUTPUT_FILE${NC}"
echo ""

# Output JSON for programmatic use
cat "$OUTPUT_FILE"

exit 0
