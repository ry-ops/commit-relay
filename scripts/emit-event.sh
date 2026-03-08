#!/bin/bash
# Universal Event Emission Script
# Single Source of Truth: coordination/dashboard-events.jsonl
#
# Usage: ./scripts/emit-event.sh <event_type> <data_json> [source]
#
# Examples:
#   ./scripts/emit-event.sh task_created '{"task_id":"task-001","title":"Test Task"}' "coordinator"
#   ./scripts/emit-event.sh worker_spawned '{"worker_id":"worker-001"}' "development-master"

set -euo pipefail

# Get project root dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Configuration
EVENTS_FILE="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
VALIDATION_LOG="$COMMIT_RELAY_HOME/coordination/logs/json-validation.log"

# Source JSON validator
source "$SCRIPT_DIR/lib/json-validator.sh"

# Source access control
source "$SCRIPT_DIR/lib/access-check.sh"

# Ensure directories exist
mkdir -p "$COMMIT_RELAY_HOME/coordination"
mkdir -p "$COMMIT_RELAY_HOME/coordination/logs"

# Parse arguments
EVENT_TYPE="${1:-}"
EVENT_DATA="${2:-{}}"
EVENT_SOURCE="${3:-system}"

if [ -z "$EVENT_TYPE" ]; then
    echo "Error: Event type is required"
    echo "Usage: $0 <event_type> <data_json> [source]"
    exit 1
fi

# Permission check: Can this source emit events?
PRINCIPAL="${EVENT_SOURCE}"
check_permission "$PRINCIPAL" "dashboard-events" "write" || {
    >&2 echo "ERROR: Permission denied - $PRINCIPAL cannot emit events"
    exit 1
}

# Generate event ID and timestamp
EVENT_ID="evt-$(date +%s)-$$"
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

# Create event JSON
EVENT_JSON=$(cat <<EOF
{
  "id": "$EVENT_ID",
  "timestamp": "$TIMESTAMP",
  "type": "$EVENT_TYPE",
  "data": $EVENT_DATA,
  "source": "$EVENT_SOURCE"
}
EOF
)

# Validate and repair JSON before writing
export JSON_VALIDATION_LOG="$VALIDATION_LOG"
export DEBUG_JSON_VALIDATION="${DEBUG_JSON_VALIDATION:-0}"

if VALIDATED_JSON=$(validate_and_repair_json "$EVENT_JSON" 1); then
    # Validation successful - write to file (atomic operation)
    echo "$VALIDATED_JSON" >> "$EVENTS_FILE"
    >&2 echo "Event emitted: $EVENT_TYPE ($EVENT_ID)"
else
    # Validation failed - log error and exit
    >&2 echo "ERROR: Failed to emit event $EVENT_TYPE ($EVENT_ID) - JSON validation failed"
    >&2 echo "Event data: $EVENT_JSON"
    exit 1
fi
