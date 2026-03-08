#!/bin/bash
# Task Completion Hook - MoE Learning Integration
# Called when a task completes to update memory/learning system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parameters
TASK_ID="${1:-}"
EXPERT="${2:-}"
SUCCESS="${3:-true}"
COMPLETION_TIME_MINUTES="${4:-0}"

if [ -z "$TASK_ID" ] || [ -z "$EXPERT" ]; then
    echo "Usage: $0 <task_id> <expert> [success] [completion_time_minutes]"
    echo "Example: $0 task-001 development true 45"
    exit 1
fi

echo "Task Completion Hook: Task $TASK_ID completed by $EXPERT (success: $SUCCESS, time: ${COMPLETION_TIME_MINUTES}min)"

# Update memory/learning system
MEMORY_MANAGER="$PROJECT_ROOT/coordination/masters/coordinator/lib/memory-manager.sh"

if [ -f "$MEMORY_MANAGER" ]; then
    echo "Updating memory/learning system..."

    # Record task completion metrics
    "$MEMORY_MANAGER" update-success "$TASK_ID" "$EXPERT" "$SUCCESS" "$COMPLETION_TIME_MINUTES" 2>&1 | \
        grep -v "^$" || true

    echo "Memory system updated"
else
    echo "Warning: Memory manager not found at $MEMORY_MANAGER"
fi

# Emit dashboard event
EVENT_SCRIPT="$SCRIPT_DIR/emit-event.sh"
if [ -f "$EVENT_SCRIPT" ]; then
    EVENT_DATA=$(jq -nc \
        --arg task "$TASK_ID" \
        --arg expert "$EXPERT" \
        --arg success "$SUCCESS" \
        --arg time "$COMPLETION_TIME_MINUTES" \
        '{task_id: $task, expert: $expert, success: ($success == "true"), completion_time_minutes: ($time | tonumber)}')

    "$EVENT_SCRIPT" "task_completed" "$EVENT_DATA" 2>/dev/null || true
fi

echo "Task completion hook finished"
