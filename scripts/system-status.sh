#!/bin/bash
# scripts/system-status.sh
# Comprehensive status check for entire commit-relay platform

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       COMMIT-RELAY PLATFORM STATUS                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# 1. Check Claude Code Agents
echo -e "${BLUE}┌─ Claude Code Agents ─────────────────────────────────────${NC}"
AGENTS_DIR="$COMMIT_RELAY_HOME/.claude/agents"
if [ -d "$AGENTS_DIR" ]; then
    AGENT_COUNT=$(find "$AGENTS_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
    echo -e "${GREEN}✓${NC} Agents directory: $AGENTS_DIR"
    echo -e "${GREEN}✓${NC} Total agents: $AGENT_COUNT"
    echo ""
    for agent_file in "$AGENTS_DIR"/*.md; do
        if [ -f "$agent_file" ]; then
            agent_name=$(basename "$agent_file" .md)
            agent_desc=$(grep "^description:" "$agent_file" | cut -d':' -f2- | sed 's/^ *//' | cut -c1-50)
            echo -e "  ${GREEN}✓${NC} $agent_name"
            echo -e "    ${agent_desc}..."
        fi
    done
else
    echo -e "${RED}✗${NC} No agents directory found"
fi
echo ""

# 2. Check Worker Daemon
echo -e "${BLUE}┌─ Worker Daemon ──────────────────────────────────────────${NC}"
PID_FILE="/tmp/commit-relay-worker-daemon.pid"
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        UPTIME=$(ps -p "$PID" -o etime= | xargs)
        echo -e "${GREEN}✓${NC} Status: Running (PID $PID)"
        echo -e "${GREEN}✓${NC} Uptime: $UPTIME"
    else
        echo -e "${RED}✗${NC} Status: Not running (stale PID file)"
    fi
else
    echo -e "${RED}✗${NC} Status: Not running"
fi
echo ""

# 3. Check Dashboard
echo -e "${BLUE}┌─ Dashboard ──────────────────────────────────────────────${NC}"
if lsof -ti:3000 > /dev/null 2>&1; then
    DASHBOARD_PID=$(lsof -ti:3000)
    echo -e "${GREEN}✓${NC} Status: Running (PID $DASHBOARD_PID)"
    echo -e "${GREEN}✓${NC} URL: http://localhost:3000"
else
    echo -e "${RED}✗${NC} Status: Not running"
    echo -e "${YELLOW}!${NC} Start with: cd dashboard && npm start"
fi
echo ""

# 4. Check Active Workers
echo -e "${BLUE}┌─ Active Workers ─────────────────────────────────────────${NC}"
ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"
if [ -d "$ACTIVE_SPECS_DIR" ]; then
    WORKER_COUNT=$(find "$ACTIVE_SPECS_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo -e "${GREEN}✓${NC} Active worker specs: $WORKER_COUNT"

    if [ "$WORKER_COUNT" -gt 0 ]; then
        echo ""
        for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
            if [ -f "$spec_file" ]; then
                worker_id=$(jq -r '.worker_id' "$spec_file" 2>/dev/null || echo "unknown")
                worker_status=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "unknown")
                worker_type=$(jq -r '.worker_type' "$spec_file" 2>/dev/null || echo "unknown")

                if [ "$worker_status" = "running" ]; then
                    echo -e "  ${GREEN}●${NC} $worker_id ($worker_type) - ${GREEN}$worker_status${NC}"
                elif [ "$worker_status" = "pending" ]; then
                    echo -e "  ${YELLOW}●${NC} $worker_id ($worker_type) - ${YELLOW}$worker_status${NC}"
                else
                    echo -e "  ${BLUE}●${NC} $worker_id ($worker_type) - $worker_status"
                fi
            fi
        done
    fi
else
    echo -e "${YELLOW}!${NC} No active workers directory"
fi
echo ""

# 5. Check Git Status
echo -e "${BLUE}┌─ Git Repository ─────────────────────────────────────────${NC}"
cd "$COMMIT_RELAY_HOME"
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓${NC} Branch: $BRANCH"

    if git diff --quiet && git diff --cached --quiet; then
        echo -e "${GREEN}✓${NC} Working tree: Clean"
    else
        echo -e "${YELLOW}!${NC} Working tree: Has changes"
    fi
else
    echo -e "${RED}✗${NC} Not a git repository"
fi
echo ""

# 6. Check Coordination State
echo -e "${BLUE}┌─ Coordination State ─────────────────────────────────────${NC}"
BUDGET_FILE="$COMMIT_RELAY_HOME/coordination/token-budget.json"
if [ -f "$BUDGET_FILE" ]; then
    echo -e "${GREEN}✓${NC} Token budget file exists"
    TOTAL_ALLOCATED=$(jq -r '.masters[] | .daily_limit' "$BUDGET_FILE" 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
    echo -e "${GREEN}✓${NC} Total daily budget: ${TOTAL_ALLOCATED}k tokens"
else
    echo -e "${YELLOW}!${NC} Token budget file not found"
fi
echo ""

# Summary
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       PLATFORM SUMMARY                                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Check if core components are running
DAEMON_RUNNING=false
DASHBOARD_RUNNING=false

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        DAEMON_RUNNING=true
    fi
fi

if lsof -ti:3000 > /dev/null 2>&1; then
    DASHBOARD_RUNNING=true
fi

if [ "$DAEMON_RUNNING" = true ] && [ "$DASHBOARD_RUNNING" = true ]; then
    echo -e "${GREEN}✓ Platform Status: FULLY OPERATIONAL${NC}"
    echo ""
    echo "  • Daemon monitoring for workers"
    echo "  • Dashboard providing observability"
    echo "  • $AGENT_COUNT agents ready to use"
    echo ""
    echo "Next steps:"
    echo "  • Use /agents in Claude Code to access agents"
    echo "  • Visit http://localhost:3000 for dashboard"
    echo "  • Create tasks with: ./scripts/create-task.sh"
elif [ "$DAEMON_RUNNING" = true ]; then
    echo -e "${YELLOW}⚠ Platform Status: PARTIALLY OPERATIONAL${NC}"
    echo ""
    echo "  • Daemon is running"
    echo "  • Dashboard is NOT running"
    echo ""
    echo "To start dashboard:"
    echo "  cd $COMMIT_RELAY_HOME/dashboard && npm start"
elif [ "$DASHBOARD_RUNNING" = true ]; then
    echo -e "${YELLOW}⚠ Platform Status: PARTIALLY OPERATIONAL${NC}"
    echo ""
    echo "  • Dashboard is running"
    echo "  • Daemon is NOT running"
    echo ""
    echo "To start daemon:"
    echo "  ./scripts/daemon-control.sh start"
else
    echo -e "${RED}✗ Platform Status: NOT RUNNING${NC}"
    echo ""
    echo "To launch platform:"
    echo "  ./scripts/start-commit-relay.sh"
fi

echo ""
