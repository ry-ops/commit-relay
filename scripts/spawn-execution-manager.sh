#!/bin/bash

# Spawn Execution Manager Script
# Used by Master agents to spawn Execution Managers for complex multi-worker coordination

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COORDINATION_DIR="$PROJECT_ROOT/coordination"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
MASTER_TYPE=""
SUBTASK_ID=""
DESCRIPTION=""
FILES_AFFECTED=""
REPOS=""
TOKEN_BUDGET=20000
ESTIMATED_DURATION=30
ACCEPTANCE_CRITERIA=""
DEPENDENCIES=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --master)
      MASTER_TYPE="$2"
      shift 2
      ;;
    --subtask-id)
      SUBTASK_ID="$2"
      shift 2
      ;;
    --description)
      DESCRIPTION="$2"
      shift 2
      ;;
    --files)
      FILES_AFFECTED="$2"
      shift 2
      ;;
    --repos)
      REPOS="$2"
      shift 2
      ;;
    --token-budget)
      TOKEN_BUDGET="$2"
      shift 2
      ;;
    --estimated-duration)
      ESTIMATED_DURATION="$2"
      shift 2
      ;;
    --acceptance-criteria)
      ACCEPTANCE_CRITERIA="$2"
      shift 2
      ;;
    --dependencies)
      DEPENDENCIES="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$MASTER_TYPE" ] || [ -z "$SUBTASK_ID" ] || [ -z "$DESCRIPTION" ]; then
  echo -e "${RED}ERROR: Missing required arguments${NC}"
  echo "Usage: $0 --master <type> --subtask-id <id> --description <desc> [options]"
  echo ""
  echo "Required:"
  echo "  --master <type>              Master type (development, security, inventory)"
  echo "  --subtask-id <id>            Unique subtask identifier"
  echo "  --description <desc>         Subtask description"
  echo ""
  echo "Optional:"
  echo "  --files <files>              Comma-separated list of files affected"
  echo "  --repos <repos>              Comma-separated list of repositories"
  echo "  --token-budget <tokens>      Token budget (default: 20000)"
  echo "  --estimated-duration <min>   Estimated duration in minutes (default: 30)"
  echo "  --acceptance-criteria <json> JSON array of acceptance criteria"
  echo "  --dependencies <json>        JSON array of dependency subtask IDs"
  exit 1
fi

# Validate master type
if [[ ! "$MASTER_TYPE" =~ ^(development|security|inventory)$ ]]; then
  echo -e "${RED}ERROR: Invalid master type: $MASTER_TYPE${NC}"
  echo "Must be one of: development, security, inventory"
  exit 1
fi

# Generate unique Execution Manager ID
EXEC_MGR_ID="exec-mgr-${MASTER_TYPE:0:3}-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -d'-' -f1)"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S%z)

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Spawning Execution Manager${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Execution Manager ID: ${GREEN}${EXEC_MGR_ID}${NC}"
echo -e "Master Type: ${GREEN}${MASTER_TYPE}${NC}"
echo -e "Subtask ID: ${GREEN}${SUBTASK_ID}${NC}"
echo -e "Description: ${GREEN}${DESCRIPTION}${NC}"
echo -e "Token Budget: ${GREEN}${TOKEN_BUDGET}${NC}"
echo -e "Estimated Duration: ${GREEN}${ESTIMATED_DURATION} minutes${NC}"
echo ""

# Step 1: Create execution plan in master's execution-plans directory
echo -e "${YELLOW}[1/5]${NC} Creating execution plan..."

PLAN_FILE="$COORDINATION_DIR/masters/$MASTER_TYPE/execution-plans/$SUBTASK_ID.json"

# Parse files into JSON array
FILES_JSON="[]"
if [ -n "$FILES_AFFECTED" ]; then
  FILES_JSON=$(echo "$FILES_AFFECTED" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
fi

# Parse repos into JSON array
REPOS_JSON="[]"
if [ -n "$REPOS" ]; then
  REPOS_JSON=$(echo "$REPOS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
fi

# Parse acceptance criteria
CRITERIA_JSON="[]"
if [ -n "$ACCEPTANCE_CRITERIA" ]; then
  CRITERIA_JSON="$ACCEPTANCE_CRITERIA"
fi

# Parse dependencies
DEPS_JSON="[]"
if [ -n "$DEPENDENCIES" ]; then
  DEPS_JSON="$DEPENDENCIES"
fi

cat > "$PLAN_FILE" <<EOF
{
  "subtask_id": "$SUBTASK_ID",
  "execution_manager_id": "$EXEC_MGR_ID",
  "master": "$MASTER_TYPE",
  "description": "$DESCRIPTION",
  "files_affected": $FILES_JSON,
  "repos": $REPOS_JSON,
  "estimated_duration_minutes": $ESTIMATED_DURATION,
  "token_budget": $TOKEN_BUDGET,
  "acceptance_criteria": $CRITERIA_JSON,
  "dependencies": $DEPS_JSON,
  "status": "pending",
  "created_at": "$TIMESTAMP",
  "updated_at": "$TIMESTAMP"
}
EOF

echo -e "${GREEN}✓${NC} Execution plan created: $PLAN_FILE"

# Step 2: Create Execution Manager state in active directory
echo -e "${YELLOW}[2/5]${NC} Creating Execution Manager state..."

EM_STATE_FILE="$COORDINATION_DIR/execution-managers/active/$EXEC_MGR_ID.json"

cat > "$EM_STATE_FILE" <<EOF
{
  "exec_mgr_id": "$EXEC_MGR_ID",
  "master_type": "$MASTER_TYPE",
  "subtask_id": "$SUBTASK_ID",
  "status": "ready",
  "started_at": "$TIMESTAMP",
  "last_heartbeat": "$TIMESTAMP",
  "workers_spawned": 0,
  "workers_completed": 0,
  "workers_failed": 0,
  "tokens_used": 0,
  "current_phase": "awaiting_start"
}
EOF

echo -e "${GREEN}✓${NC} Execution Manager state created: $EM_STATE_FILE"

# Step 3: Update token budget
echo -e "${YELLOW}[3/5]${NC} Allocating token budget..."

if [ -f "$COORDINATION_DIR/token-budget.json" ]; then
  jq --arg em_id "$EXEC_MGR_ID" \
     --argjson budget "$TOKEN_BUDGET" \
     --arg master "$MASTER_TYPE" \
     '.execution_managers = (.execution_managers // {}) |
      .execution_managers[$em_id] = {
        "allocated": $budget,
        "used": 0,
        "master": $master,
        "started_at": now | todate
      }' \
    "$COORDINATION_DIR/token-budget.json" > "$COORDINATION_DIR/token-budget.json.tmp"

  mv "$COORDINATION_DIR/token-budget.json.tmp" "$COORDINATION_DIR/token-budget.json"
  echo -e "${GREEN}✓${NC} Token budget allocated: $TOKEN_BUDGET tokens"
else
  echo -e "${YELLOW}⚠${NC}  Token budget file not found, skipping allocation"
fi

# Step 4: Create log directory and spawn info
echo -e "${YELLOW}[4/5]${NC} Setting up Execution Manager workspace..."

LOG_DIR="$PROJECT_ROOT/agents/logs/execution-managers/$EXEC_MGR_ID"
mkdir -p "$LOG_DIR"

cat > "$LOG_DIR/spawn-info.txt" <<EOF
Execution Manager Spawn Information
Generated: $TIMESTAMP

Execution Manager ID: $EXEC_MGR_ID
Master Type: $MASTER_TYPE
Subtask ID: $SUBTASK_ID
Description: $DESCRIPTION

Token Budget: $TOKEN_BUDGET
Estimated Duration: $ESTIMATED_DURATION minutes

Files:
$PLAN_FILE
$EM_STATE_FILE

To start the Execution Manager manually:
  export EXEC_MGR_ID="$EXEC_MGR_ID"
  echo "$EXEC_MGR_ID" > /tmp/exec-mgr-id.txt
  cd $PROJECT_ROOT
  claude --prompt "\$(cat agents/prompts/execution-manager.md)"
EOF

echo -e "${GREEN}✓${NC} Workspace created: $LOG_DIR"

# Step 5: Create handoff notification
echo -e "${YELLOW}[5/5]${NC} Creating handoff notification..."

HANDOFF_FILE="$COORDINATION_DIR/masters/$MASTER_TYPE/handoffs/to-exec-mgr-$EXEC_MGR_ID.json"

cat > "$HANDOFF_FILE" <<EOF
{
  "handoff_id": "to-exec-mgr-$EXEC_MGR_ID",
  "from": "${MASTER_TYPE}-master",
  "to": "execution-manager-$EXEC_MGR_ID",
  "subtask_id": "$SUBTASK_ID",
  "execution_manager_required": true,
  "reason": "Complex multi-worker coordination required",
  "execution_plan": "$PLAN_FILE",
  "created_at": "$TIMESTAMP"
}
EOF

echo -e "${GREEN}✓${NC} Handoff created: $HANDOFF_FILE"

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Execution Manager Spawned${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}Details:${NC}"
echo -e "  ID: ${GREEN}$EXEC_MGR_ID${NC}"
echo -e "  Execution Plan: ${BLUE}$PLAN_FILE${NC}"
echo -e "  State File: ${BLUE}$EM_STATE_FILE${NC}"
echo -e "  Logs: ${BLUE}$LOG_DIR${NC}"
echo ""

# Output JSON for programmatic use
echo "{\"exec_mgr_id\":\"$EXEC_MGR_ID\",\"subtask_id\":\"$SUBTASK_ID\",\"plan_file\":\"$PLAN_FILE\"}"

exit 0
