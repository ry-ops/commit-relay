#!/bin/bash
# Worker Status Script - Monitor active workers

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"

cd "$COMMIT_RELAY_HOME"

# Pull latest state
git pull origin main --quiet 2>/dev/null || log_warn "Could not pull latest state"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}Worker Status Dashboard${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Active Workers
echo -e "${BLUE}📊 Active Workers${NC}"
ACTIVE_COUNT=$(jq '.active_workers | length' coordination/worker-pool.json)
echo -e "  Total: ${GREEN}$ACTIVE_COUNT${NC}"
echo ""

if [ "$ACTIVE_COUNT" -gt 0 ]; then
    jq -r '.active_workers[] |
        "  • \(.worker_id)\n" +
        "    Type: \(.worker_type)\n" +
        "    Status: \(.status)\n" +
        "    Master: \(.spawned_by)\n" +
        "    Task: \(.task_id)\n" +
        "    Tokens: \(.tokens_used)/\(.token_budget)\n" +
        "    Started: \(.spawned_at)\n"' \
        coordination/worker-pool.json
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Completed Workers (today)
echo -e "${BLUE}✓ Completed Workers (Today)${NC}"
COMPLETED_COUNT=$(jq '.stats.total_completed_today' coordination/worker-pool.json)
echo -e "  Total: ${GREEN}$COMPLETED_COUNT${NC}"
echo ""

if [ "$COMPLETED_COUNT" -gt 0 ]; then
    RECENT_COMPLETED=$(jq -r '.completed_workers[-5:] | reverse[] |
        "  • \(.worker_id) - \(.status) (\(.duration_minutes)m, \(.tokens_used) tokens)"' \
        coordination/worker-pool.json 2>/dev/null || echo "  (No recent completions)")
    echo "$RECENT_COMPLETED"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Failed Workers
echo -e "${BLUE}✗ Failed Workers${NC}"
FAILED_COUNT=$(jq '.stats.total_failed_today' coordination/worker-pool.json)
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "  Total: ${RED}$FAILED_COUNT${NC}"
    echo ""
    jq -r '.failed_workers[] |
        "  • \(.worker_id) - \(.status)\n" +
        "    Error: \(.error)\n" +
        "    Failed: \(.failed_at)\n"' \
        coordination/worker-pool.json
else
    echo -e "  Total: ${GREEN}0${NC}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Token Budget
echo -e "${BLUE}💰 Token Budget${NC}"
TOTAL_BUDGET=$(jq '.total_budget' coordination/token-budget.json)
WORKER_POOL=$(jq '.worker_pool.total' coordination/token-budget.json)
ALLOCATED=$(jq '.worker_pool.allocated_to_workers' coordination/token-budget.json)
AVAILABLE=$(jq '.worker_pool.available' coordination/token-budget.json)

echo -e "  Total Budget: $TOTAL_BUDGET"
echo -e "  Worker Pool: $WORKER_POOL"
echo -e "  Allocated: ${YELLOW}$ALLOCATED${NC}"
echo -e "  Available: ${GREEN}$AVAILABLE${NC}"

# Calculate percentage
PERCENT_USED=$((ALLOCATED * 100 / WORKER_POOL))
echo -e "  Usage: $PERCENT_USED%"

# Visual bar
BAR_LENGTH=40
FILLED=$((PERCENT_USED * BAR_LENGTH / 100))
EMPTY=$((BAR_LENGTH - FILLED))

printf "  ["
printf "${GREEN}%${FILLED}s${NC}" | tr ' ' '█'
printf "%${EMPTY}s" | tr ' ' '░'
printf "]\n"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Statistics
echo -e "${BLUE}📈 Statistics${NC}"
AVG_DURATION=$(jq '.stats.avg_duration_minutes' coordination/worker-pool.json)
AVG_TOKENS=$(jq '.stats.avg_tokens_used' coordination/worker-pool.json)

echo -e "  Average Duration: ${CYAN}${AVG_DURATION}m${NC}"
echo -e "  Average Tokens: ${CYAN}${AVG_TOKENS}${NC}"
echo -e "  Success Rate: $(jq -r 'if .stats.total_spawned_today > 0 then
    ((.stats.total_completed_today / .stats.total_spawned_today) * 100 | floor)
    else 0 end | "\(.)%"' coordination/worker-pool.json)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Recent activity
echo -e "${BLUE}📝 Recent Activity${NC}"
if [ -d "agents/logs/workers/$(date +%Y-%m-%d)" ]; then
    WORKER_COUNT=$(find "agents/logs/workers/$(date +%Y-%m-%d)" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    echo -e "  Workers with logs today: ${GREEN}$WORKER_COUNT${NC}"

    if [ "$WORKER_COUNT" -gt 0 ]; then
        echo ""
        echo "  Recent worker logs:"
        ls -t "agents/logs/workers/$(date +%Y-%m-%d)" | head -5 | while read worker; do
            echo "    • $worker"
        done
    fi
else
    echo "  No worker activity today"
fi

echo ""
echo "Last updated: $(jq -r '.updated_at' coordination/worker-pool.json)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
