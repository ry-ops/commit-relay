#!/bin/bash
# Update coordination files with actual worker counts

ACTIVE=$(find coordination/worker-specs/active -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
COMPLETED=$(find coordination/worker-specs/completed -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
FAILED=$(find coordination/worker-specs/failed -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
ZOMBIE=$(find coordination/worker-specs/zombie -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((ACTIVE + COMPLETED + FAILED + ZOMBIE))
SUCCESS_RATE=$(echo "scale=1; ($COMPLETED / $TOTAL) * 100" | bc)

echo "Updating coordination files..."
echo "Active: $ACTIVE, Completed: $COMPLETED, Failed: $FAILED, Zombie: $ZOMBIE"
echo "Total: $TOTAL, Success Rate: $SUCCESS_RATE%"

# Update workforce-streams.json
jq --arg active "$ACTIVE" --arg completed "$COMPLETED" --arg failed "$FAILED" --arg zombie "$ZOMBIE" \
  '.workers.active = ($active | tonumber) | 
   .workers.completed = ($completed | tonumber) | 
   .workers.failed = ($failed | tonumber) | 
   .workers.zombie = ($zombie | tonumber) | 
   .last_updated = "'$(date +%Y-%m-%dT%H:%M:%S%z)'"' \
  coordination/workforce-streams.json > /tmp/workforce-streams-updated.json && \
  mv /tmp/workforce-streams-updated.json coordination/workforce-streams.json

echo "✅ Updated workforce-streams.json"

# Update PM state metrics
jq --arg active "$ACTIVE" --arg completed "$COMPLETED" --arg failed "$FAILED" --arg total "$TOTAL" --arg rate "$SUCCESS_RATE" \
  '.metrics.active_workers = ($active | tonumber) | 
   .metrics.completed_workers = ($completed | tonumber) | 
   .metrics.failed_workers = ($failed | tonumber) | 
   .metrics.total_workers = ($total | tonumber) | 
   .metrics.success_rate = ($rate | tonumber) | 
   .last_check = "'$(date +%Y-%m-%dT%H:%M:%S%z)'"' \
  coordination/pm-state.json > /tmp/pm-state-updated.json && \
  mv /tmp/pm-state-updated.json coordination/pm-state.json

echo "✅ Updated pm-state.json"
