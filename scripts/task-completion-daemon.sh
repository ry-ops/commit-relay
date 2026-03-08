#!/bin/bash

# Task Completion Daemon
# Monitors worker status.json files and updates task queue when workers complete
# This fixes the async worker completion issue where launcher exits before worker finishes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SLEEP_INTERVAL=5  # Check every 5 seconds

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TASK-COMPLETION: $1" | tee -a "$PROJECT_ROOT/agents/logs/system/task-completion-daemon.log"
}

log "Task Completion Daemon starting..."

while true; do
    # Find all active worker specs with task_id
    for worker_spec in "$PROJECT_ROOT/coordination/worker-specs/active"/*.json; do
        if [ ! -f "$worker_spec" ]; then
            continue
        fi

        WORKER_ID=$(basename "$worker_spec" .json)
        TASK_ID=$(jq -r '.task_id' "$worker_spec" 2>/dev/null)
        WORKER_DIR="$PROJECT_ROOT/agents/workers/$WORKER_ID"

        if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
            continue
        fi

        # Check if worker has a status.json file (indicating completion)
        if [ -f "$WORKER_DIR/status.json" ]; then
            WORKER_STATUS=$(jq -r '.status' "$WORKER_DIR/status.json" 2>/dev/null)

            # Check if task is still in worker_spawned status
            TASK_STATUS=$(jq -r --arg tid "$TASK_ID" '.tasks[] | select(.id == $tid) | .status' "$PROJECT_ROOT/coordination/task-queue.json" 2>/dev/null)

            if [ "$TASK_STATUS" = "worker_spawned" ]; then
                TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

                # Update task queue with worker completion status
                jq --arg tid "$TASK_ID" \
                   --arg status "$WORKER_STATUS" \
                   --arg ts "$TIMESTAMP" \
                   '(.tasks[] | select(.id == $tid)) |= (.status = $status | .updated_at = $ts | .completed_at = $ts)' \
                   "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue-update.json && \
                mv /tmp/task-queue-update.json "$PROJECT_ROOT/coordination/task-queue.json"

                log "✓ Updated task $TASK_ID to status '$WORKER_STATUS' (worker: $WORKER_ID)"
            fi
        fi
    done

    sleep $SLEEP_INTERVAL
done
