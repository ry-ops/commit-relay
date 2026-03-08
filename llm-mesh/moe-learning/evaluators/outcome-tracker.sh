#!/bin/bash
# MoE Outcome Tracker
# Tracks routing decision outcomes and feeds them to the learning system

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_MESH_HOME="$SCRIPT_DIR/../.."
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Paths
ROUTING_DECISIONS="$COMMIT_RELAY_HOME/coordination/masters/coordinator/logs/routing-decisions.jsonl"
TASK_QUEUE="$COMMIT_RELAY_HOME/coordination/task-queue.json"
OUTCOMES_CATALOG="$SCRIPT_DIR/../catalog/routing-decisions.jsonl"
METRICS_DIR="$SCRIPT_DIR/../metrics"

# Ensure directories exist
mkdir -p "$(dirname "$OUTCOMES_CATALOG")" "$METRICS_DIR"

##############################################################################
# track_outcome: Track the outcome of a completed task
# Args:
#   $1: task_id
#   $2: status (completed|failed|reassigned)
#   $3: quality_score (0-1, optional)
# Outputs: Appends routing decision with outcome to catalog
##############################################################################
track_outcome() {
    local task_id="$1"
    local status="$2"
    local quality_score="${3:-0.5}"  # Default to neutral quality
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    # Find the routing decision for this task
    local routing_decision=$(grep "\"task_id\":\"$task_id\"" "$ROUTING_DECISIONS" 2>/dev/null | tail -1)

    if [ -z "$routing_decision" ]; then
        echo "Warning: No routing decision found for task $task_id" >&2
        return 1
    fi

    # Extract routing details
    local primary_expert=$(echo "$routing_decision" | jq -r '.decision.primary_expert')
    local primary_confidence=$(echo "$routing_decision" | jq -r '.decision.primary_confidence')
    local routing_strategy=$(echo "$routing_decision" | jq -r '.decision.strategy')

    # Find task details from task queue or completed tasks
    local task_description=""
    local task_type=""

    # Try to find task in various locations
    if [ -f "$COMMIT_RELAY_HOME/coordination/tasks/$task_id.json" ]; then
        local task_file="$COMMIT_RELAY_HOME/coordination/tasks/$task_id.json"
        task_description=$(jq -r '.context.description // .description // .title' "$task_file")
        task_type=$(jq -r '.type // "unknown"' "$task_file")
    fi

    # Determine success and routing accuracy
    local success="false"
    local routing_accuracy=0.5

    if [ "$status" = "completed" ]; then
        success="true"
        routing_accuracy=0.85  # Good routing if completed successfully
    elif [ "$status" = "reassigned" ]; then
        success="false"
        routing_accuracy=0.3   # Poor routing if reassigned
    else
        success="false"
        routing_accuracy=0.4   # Failed routing
    fi

    # Calculate confidence calibration
    # High confidence + success = well calibrated (1.0)
    # High confidence + failure = poorly calibrated (0.2)
    # Low confidence + success = underconfident (0.6)
    # Low confidence + failure = well calibrated (0.9)
    local confidence_calibration=0.5
    local conf_float=$(echo "$primary_confidence" | awk '{print ($1 > 0.7) ? 1 : 0}')
    local success_int=$([ "$success" = "true" ] && echo 1 || echo 0)

    if [ "$conf_float" -eq 1 ] && [ "$success_int" -eq 1 ]; then
        confidence_calibration=1.0
    elif [ "$conf_float" -eq 1 ] && [ "$success_int" -eq 0 ]; then
        confidence_calibration=0.2
    elif [ "$conf_float" -eq 0 ] && [ "$success_int" -eq 1 ]; then
        confidence_calibration=0.6
    else
        confidence_calibration=0.9
    fi

    # Build outcome record
    local outcome_record=$(jq -n \
        --arg decision_id "decision-$(date +%s)-$RANDOM" \
        --arg timestamp "$timestamp" \
        --arg task_id "$task_id" \
        --arg task_desc "$task_description" \
        --arg task_type "$task_type" \
        --arg primary_expert "$primary_expert" \
        --argjson primary_conf "$primary_confidence" \
        --arg strategy "$routing_strategy" \
        --arg status "$status" \
        --argjson success "$success" \
        --argjson quality_score "$quality_score" \
        --argjson routing_accuracy "$routing_accuracy" \
        --argjson conf_calibration "$confidence_calibration" \
        '{
            decision_id: $decision_id,
            timestamp: $timestamp,
            task: {
                task_id: $task_id,
                description: $task_desc,
                type: $task_type
            },
            routing: {
                strategy: $strategy,
                primary_expert: $primary_expert,
                primary_confidence: $primary_conf
            },
            execution: {
                status: $status
            },
            outcome: {
                success: $success,
                quality_score: $quality_score,
                routing_accuracy: $routing_accuracy,
                confidence_calibration: $conf_calibration,
                ideal_expert: $primary_expert
            },
            learning: {
                analyzed: false
            }
        }')

    # Append to catalog
    echo "$outcome_record" >> "$OUTCOMES_CATALOG"

    # Update metrics
    update_metrics "$routing_accuracy" "$conf_calibration"

    echo "Tracked outcome for task $task_id: status=$status, routing_accuracy=$routing_accuracy"
}

##############################################################################
# update_metrics: Update aggregate metrics
##############################################################################
update_metrics() {
    local routing_accuracy="$1"
    local confidence_calibration="$2"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    # Append to routing accuracy metrics
    echo "{\"timestamp\":\"$timestamp\",\"routing_accuracy\":$routing_accuracy}" \
        >> "$METRICS_DIR/routing-accuracy.jsonl"

    # Append to confidence calibration metrics
    echo "{\"timestamp\":\"$timestamp\",\"confidence_calibration\":$confidence_calibration}" \
        >> "$METRICS_DIR/confidence-calibration.jsonl"

    # Calculate rolling averages (last 20 decisions)
    local avg_accuracy=$(tail -20 "$METRICS_DIR/routing-accuracy.jsonl" 2>/dev/null | \
        jq -s 'map(.routing_accuracy) | add / length' || echo "0")

    local avg_calibration=$(tail -20 "$METRICS_DIR/confidence-calibration.jsonl" 2>/dev/null | \
        jq -s 'map(.confidence_calibration) | add / length' || echo "0")

    # Append to learning progress
    echo "{\"timestamp\":\"$timestamp\",\"avg_routing_accuracy\":$avg_accuracy,\"avg_confidence_calibration\":$avg_calibration}" \
        >> "$METRICS_DIR/learning-progress.jsonl"
}

##############################################################################
# get_unanalyzed_outcomes: Get outcomes that haven't been analyzed yet
##############################################################################
get_unanalyzed_outcomes() {
    if [ ! -f "$OUTCOMES_CATALOG" ]; then
        echo "[]"
        return
    fi

    jq -s '[.[] | select(.learning.analyzed == false)]' "$OUTCOMES_CATALOG"
}

##############################################################################
# mark_as_analyzed: Mark an outcome as analyzed
##############################################################################
mark_as_analyzed() {
    local decision_id="$1"

    # Create temporary file with updated records
    local temp_file=$(mktemp)

    jq --arg did "$decision_id" \
        'if .decision_id == $did then .learning.analyzed = true else . end' \
        "$OUTCOMES_CATALOG" > "$temp_file"

    mv "$temp_file" "$OUTCOMES_CATALOG"
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <task_id> <status> [quality_score]"
        echo "  status: completed|failed|reassigned"
        echo "  quality_score: 0-1 (optional, defaults to 0.5)"
        exit 1
    fi

    track_outcome "$@"
fi
