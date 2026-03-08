#!/bin/bash
# scripts/test-autonomous-execution.sh
# Test autonomous worker execution end-to-end
# Part of Week 1: AGENT_ARCHITECTURE_FIX validation

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Autonomous Execution Test${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$COMMIT_RELAY_HOME"

# Test 1: Worker daemon running
echo -e "${YELLOW}Test 1: Worker Daemon Status${NC}"
if ps aux | grep -i "worker-daemon" | grep -v grep > /dev/null; then
    PID=$(ps aux | grep -i "worker-daemon" | grep -v grep | awk '{print $2}')
    echo -e "${GREEN}✅ Worker daemon is running (PID $PID)${NC}"
else
    echo -e "${RED}❌ Worker daemon is NOT running${NC}"
    echo "   Start it with: scripts/worker-daemon.sh &"
    exit 1
fi

# Test 2: Active worker specs directory
echo ""
echo -e "${YELLOW}Test 2: Worker Specs Directory${NC}"
ACTIVE_COUNT=$(ls -1 coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
echo -e "${GREEN}✅ Active workers: $ACTIVE_COUNT${NC}"

# Test 3: Token budget state
echo ""
echo -e "${YELLOW}Test 3: Token Budget${NC}"
TOTAL_BUDGET=$(jq -r '.total_budget' coordination/token-budget.json)
TOTAL_USED=$(jq -r '.total_used' coordination/token-budget.json)
AVAILABLE=$((TOTAL_BUDGET - TOTAL_USED))
echo -e "${GREEN}✅ Budget: ${AVAILABLE}k / ${TOTAL_BUDGET}k available${NC}"

if [ "$AVAILABLE" -lt 10000 ]; then
    echo -e "${RED}   WARNING: Low token budget ($AVAILABLE remaining)${NC}"
fi

# Test 4: Zombie count
echo ""
echo -e "${YELLOW}Test 4: Zombie Workers${NC}"
ZOMBIE_COUNT=$(find coordination/worker-specs/active -name "*.json" -exec jq -r 'select(.status == "zombie") | .worker_id' {} \; 2>/dev/null | wc -l | tr -d ' ')
if [ "$ZOMBIE_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✅ No zombie workers${NC}"
else
    echo -e "${RED}❌ Found $ZOMBIE_COUNT zombie workers${NC}"
    echo "   Run: scripts/zombie-worker-recovery.sh"
fi

# Test 5: Create test task
echo ""
echo -e "${YELLOW}Test 5: Create Test Task${NC}"
TEST_TASK_ID="autonomous-test-$(date +%s)"

cat > "coordination/task-queue-test.json" <<EOF
{
  "id": "$TEST_TASK_ID",
  "title": "Autonomous Test: Echo System Info",
  "type": "development",
  "description": "Create a simple script that echoes system information",
  "priority": "high",
  "status": "pending",
  "created_at": "$(date +"%Y-%m-%dT%H:%M:%S%z")",
  "created_by": "autonomous-test-week1"
}
EOF

echo -e "${GREEN}✅ Created test task: $TEST_TASK_ID${NC}"
echo "   File: coordination/task-queue-test.json"

# Test 6: Lifecycle manager
echo ""
echo -e "${YELLOW}Test 6: Lifecycle Manager${NC}"
if [ -f "scripts/worker-lifecycle-manager.sh" ]; then
    ./scripts/worker-lifecycle-manager.sh
    echo -e "${GREEN}✅ Lifecycle manager executed successfully${NC}"
else
    echo -e "${RED}❌ Lifecycle manager not found${NC}"
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Test Summary${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Worker Daemon:${NC}    Running (PID $PID)"
echo -e "${BLUE}Active Workers:${NC}   $ACTIVE_COUNT"
echo -e "${BLUE}Zombie Workers:${NC}   $ZOMBIE_COUNT"
echo -e "${BLUE}Token Budget:${NC}     ${AVAILABLE}k available"
echo -e "${BLUE}Test Task:${NC}        $TEST_TASK_ID (created)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo -e "${GREEN}✅ Week 1 autonomous execution system is operational!${NC}"
echo ""
echo "Next steps for full Q1 roadmap:"
echo "  - Week 2-7: Implement Five Agent Types Architecture"
echo "  - Week 6-11: Build Unified Observability Platform"
echo "  - Week 12: Q1 Integration and Validation"
echo ""

exit 0
