#!/bin/bash
# Quick status overview of commit-relay system

set -e

cd ~/commit-relay
git pull origin main --quiet

echo "================================"
echo "Commit-Relay System Status"
echo "================================"
echo ""

# Parse system health from status.json
echo "📊 System Health:"
jq -r '.system_health | "  Active Tasks: \(.total_active_tasks)\n  Pending Handoffs: \(.pending_handoffs)\n  Blocked Tasks: \(.blocked_tasks)\n  Agents Online: \(.agents_online)"' coordination/status.json
echo ""

# Show active agents
echo "🤖 Agent Status:"
jq -r '.agents | to_entries[] | "  \(.key): \(.value.status) (Last: \(.value.last_checkin | split("T")[0]))"' coordination/status.json
echo ""

# Show pending tasks
task_count=$(jq '.tasks | length' coordination/task-queue.json)
echo "📋 Task Queue: $task_count tasks"
if [ "$task_count" -gt 0 ]; then
  jq -r '.tasks[] | "  [\(.status)] \(.id): \(.title) (@\(.assigned_to))"' coordination/task-queue.json
fi
echo ""

# Show pending handoffs
handoff_count=$(jq '.pending_handoffs | length' coordination/handoffs.json)
echo "🔄 Pending Handoffs: $handoff_count"
if [ "$handoff_count" -gt 0 ]; then
  jq -r '.pending_handoffs[] | "  \(.id): \(.from_agent) → \(.to_agent) (\(.status))"' coordination/handoffs.json
fi
echo ""

echo "Last updated: $(jq -r '.updated_at' coordination/status.json)"
echo "================================"
