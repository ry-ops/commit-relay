#!/bin/bash
# Sync worker-pool.json with actual file counts for accurate metrics

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKER_POOL_FILE="$PROJECT_ROOT/coordination/worker-pool.json"
WORKFORCE_STREAMS_FILE="$PROJECT_ROOT/coordination/workforce-streams.json"

# Count actual workers from file system
ACTIVE_COUNT=$(find "$PROJECT_ROOT/coordination/worker-specs/active" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
COMPLETED_COUNT=$(find "$PROJECT_ROOT/coordination/worker-specs/completed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
FAILED_COUNT=$(find "$PROJECT_ROOT/coordination/worker-specs/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S%z)

# Update worker-pool.json
if [ -f "$WORKER_POOL_FILE" ]; then
    # Get lists of worker IDs
    ACTIVE_WORKERS=$(find "$PROJECT_ROOT/coordination/worker-specs/active" -name "*.json" -exec basename {} .json \; 2>/dev/null | jq -R . | jq -s .)
    COMPLETED_WORKERS=$(find "$PROJECT_ROOT/coordination/worker-specs/completed" -name "*.json" -exec basename {} .json \; 2>/dev/null | jq -R . | jq -s .)
    FAILED_WORKERS=$(find "$PROJECT_ROOT/coordination/worker-specs/failed" -name "*.json" -exec basename {} .json \; 2>/dev/null | jq -R . | jq -s .)

    jq --argjson active "$ACTIVE_WORKERS" \
       --argjson completed "$COMPLETED_WORKERS" \
       --argjson failed "$FAILED_WORKERS" \
       --arg ts "$TIMESTAMP" \
       '.active_workers = $active | .completed_workers = $completed | .failed_workers = $failed | .last_updated = $ts' \
       "$WORKER_POOL_FILE" > "${WORKER_POOL_FILE}.tmp" && \
       mv "${WORKER_POOL_FILE}.tmp" "$WORKER_POOL_FILE"
fi

# Update workforce-streams.json
if [ -f "$WORKFORCE_STREAMS_FILE" ]; then
    jq --argjson active "$ACTIVE_COUNT" \
       --argjson completed "$COMPLETED_COUNT" \
       --argjson failed "$FAILED_COUNT" \
       --argjson zombie 0 \
       --arg ts "$TIMESTAMP" \
       '.workers.active = $active | .workers.completed = $completed | .workers.failed = $failed | .workers.zombie = $zombie | .last_updated = $ts' \
       "$WORKFORCE_STREAMS_FILE" > "${WORKFORCE_STREAMS_FILE}.tmp" && \
       mv "${WORKFORCE_STREAMS_FILE}.tmp" "$WORKFORCE_STREAMS_FILE"
fi

# Output current stats
if [ "$1" = "--verbose" ] || [ "$1" = "-v" ]; then
    echo "Worker Metrics Synced:"
    echo "  Active: $ACTIVE_COUNT"
    echo "  Completed: $COMPLETED_COUNT"
    echo "  Failed: $FAILED_COUNT"
    echo "  Total: $((ACTIVE_COUNT + COMPLETED_COUNT + FAILED_COUNT))"

    if [ "$((COMPLETED_COUNT + FAILED_COUNT))" -gt 0 ]; then
        SUCCESS_RATE=$(echo "scale=1; $COMPLETED_COUNT * 100 / ($COMPLETED_COUNT + $FAILED_COUNT)" | bc)
        echo "  Success Rate: ${SUCCESS_RATE}%"
    fi
fi
