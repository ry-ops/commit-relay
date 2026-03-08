#!/bin/bash
# Model Selection Router - MoE-based model selection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_HOME="$SCRIPT_DIR/.."
MODELS_CATALOG="$GATEWAY_HOME/catalog/models.json"
PRICING_CATALOG="$GATEWAY_HOME/catalog/pricing.json"
PERFORMANCE_DATA="$GATEWAY_HOME/catalog/model-performance.jsonl"
LEARNED_PREFS="$SCRIPT_DIR/learned-preferences.json"

##############################################################################
# select_model: Choose optimal model for task
# Args:
#   $1: task_type
#   $2: max_cost (optional)
#   $3: quality_requirement (optional, default: balanced)
# Outputs: model name
##############################################################################
select_model() {
    local task_type="$1"
    local max_cost="${2:-999}"
    local quality_req="${3:-balanced}"  # economical|balanced|premium

    # Strategy 1: Check learned preferences
    if [ -f "$LEARNED_PREFS" ]; then
        local learned_model=$(jq -r \
            --arg task "$task_type" \
            '.preferences[$task] // empty' \
            "$LEARNED_PREFS")

        if [ -n "$learned_model" ]; then
            echo "$learned_model"
            return 0
        fi
    fi

    # Strategy 2: Use catalog preferences
    local catalog_model=$(jq -r \
        --arg task "$task_type" \
        --arg qual "$quality_req" \
        '.task_type_preferences[$task][$qual][0] // empty' \
        "$MODELS_CATALOG")

    if [ -n "$catalog_model" ]; then
        echo "$catalog_model"
        return 0
    fi

    # Strategy 3: Default based on quality requirement
    case "$quality_req" in
        economical)
            echo "claude-haiku"
            ;;
        premium)
            echo "claude-opus-4"
            ;;
        *)
            echo "claude-sonnet-4"
            ;;
    esac
}

##############################################################################
# estimate_cost: Estimate cost for a model/task combination
##############################################################################
estimate_cost() {
    local model="$1"
    local task_type="$2"
    local input_tokens="${3:-1500}"
    local output_tokens="${4:-800}"

    # Get pricing
    local provider=$(jq -r --arg m "$model" '.models[$m].provider' "$MODELS_CATALOG")
    local input_cost_per_m=$(jq -r \
        --arg provider "$provider" \
        --arg model "$model" \
        '.providers[$provider].models[$model].input_cost_per_million' \
        "$PRICING_CATALOG")

    local output_cost_per_m=$(jq -r \
        --arg provider "$provider" \
        --arg model "$model" \
        '.providers[$provider].models[$model].output_cost_per_million' \
        "$PRICING_CATALOG")

    # Calculate
    local input_cost=$(echo "scale=6; $input_tokens * $input_cost_per_m / 1000000" | bc)
    local output_cost=$(echo "scale=6; $output_tokens * $output_cost_per_m / 1000000" | bc)
    local total=$(echo "$input_cost + $output_cost" | bc)

    echo "$total"
}

##############################################################################
# record_performance: Track model performance for learning
##############################################################################
record_performance() {
    local model="$1"
    local task_type="$2"
    local quality_score="$3"
    local cost="$4"
    local latency_ms="$5"

    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    local perf_record=$(jq -n \
        --arg model "$model" \
        --arg task "$task_type" \
        --arg ts "$timestamp" \
        --argjson quality "$quality_score" \
        --argjson cost "$cost" \
        --argjson latency "$latency_ms" \
        '{
            timestamp: $ts,
            model: $model,
            task_type: $task,
            quality_score: $quality,
            cost: $cost,
            latency_ms: $latency,
            success: true
        }')

    echo "$perf_record" >> "$PERFORMANCE_DATA"
}

##############################################################################
# learn_from_performance: Update learned preferences
##############################################################################
learn_from_performance() {
    if [ ! -f "$PERFORMANCE_DATA" ]; then
        echo "No performance data available for learning" >&2
        return 0
    fi

    # Aggregate performance by task type and model
    local aggregated=$(jq -s '
        group_by(.task_type) |
        map({
            task_type: .[0].task_type,
            models: (
                group_by(.model) |
                map({
                    model: .[0].model,
                    avg_quality: (map(.quality_score) | add / length),
                    avg_cost: (map(.cost) | add / length),
                    total_calls: length
                })
            )
        })
    ' "$PERFORMANCE_DATA")

    # For each task type, find best model
    local preferences=$(echo "$aggregated" | jq '
        map({
            key: .task_type,
            value: (
                .models |
                sort_by(-.avg_quality) |
                .[0].model
            )
        }) |
        from_entries |
        {preferences: .}
    ')

    echo "$preferences" > "$LEARNED_PREFS"
    echo "Learned preferences updated" >&2
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-select}" in
        select)
            select_model "${2:-routing-analysis}" "${3:-999}" "${4:-balanced}"
            ;;
        estimate)
            estimate_cost "$2" "$3" "${4:-1500}" "${5:-800}"
            ;;
        record)
            record_performance "$2" "$3" "$4" "$5" "$6"
            ;;
        learn)
            learn_from_performance
            ;;
        *)
            echo "Usage: $0 {select|estimate|record|learn} [args...]"
            exit 1
            ;;
    esac
fi
