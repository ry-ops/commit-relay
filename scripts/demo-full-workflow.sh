#!/bin/bash

# Demonstration of Full Autonomous Git Workflow
# This script shows the complete end-to-end workflow

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "🚀 Commit-Relay Full Autonomous Workflow Demo"
echo "=============================================="
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
echo "  ✓ Worker daemon running: $(pgrep -f worker-daemon.sh > /dev/null && echo 'YES' || echo 'NO')"
echo "  ✓ Dashboard server running: $(lsof -i :3000 2>/dev/null | grep -q LISTEN && echo 'YES' || echo 'NO')"
echo "  ✓ Git automation library: $([ -f "$PROJECT_ROOT/scripts/lib/git-automation.sh" ] && echo 'YES' || echo 'NO')"
echo ""

# Show current system state
echo "📊 Current System State:"
echo "  Tasks in queue: $(cat "$PROJECT_ROOT/coordination/task-queue.json" 2>/dev/null | jq '.tasks | length' || echo '0')"
echo "  Git operations: $(wc -l < "$PROJECT_ROOT/coordination/git-operations.jsonl" 2>/dev/null || echo '0')"
echo "  Dashboard events: $(wc -l < "$PROJECT_ROOT/coordination/dashboard-events.jsonl" 2>/dev/null || echo '0')"
echo ""

# Create a demo task
echo "📝 Creating demo task..."
TASK_ID="demo-$(date +%s)"
TASK_FILE="examples/autonomous-demo/workflow-test-$TASK_ID.txt"

# Use create-task.sh
"$PROJECT_ROOT/scripts/create-task.sh" \
  --type development \
  --title "Full workflow demo: Create test file" \
  --description "Demonstrate end-to-end autonomous workflow with git automation" \
  --priority medium

echo ""
echo "✅ Demo task created!"
echo ""
echo "🎬 Now watch your dashboard at http://localhost:3000"
echo ""
echo "You should see (in real-time):"
echo "  1. Task appears in task queue"
echo "  2. Worker spawns and starts working"
echo "  3. Worker commits and pushes changes"
echo "  4. Git push event appears on dashboard"
echo "  5. Task marked as completed"
echo ""
echo "All within 10 seconds! No manual intervention needed!"
echo ""
echo "📺 Monitoring dashboard: http://localhost:3000"
echo "📊 Watch the Recent Activity section for real-time updates"
