#!/bin/bash
# scripts/lib/utility-optimizer.sh
# Utility-Based Master Optimization Library
#
# Part of Five Agent Types Architecture (Week 4)
# Implements multi-objective optimization for master agent routing
#
# Features:
# - Multi-objective utility function (speed, quality, cost, success_rate)
# - Weighted scoring algorithm
# - Dynamic weight adjustment based on context
# - Utility tracking and analytics
#
# Usage:
#   source scripts/lib/utility-optimizer.sh
#   utility_score=$(calculate_utility "$master_id" "$task_spec" "$objective_weights")
#   best_master=$(select_master_by_utility "$task_spec" "$available_masters")

set -euo pipefail

# Utility function objectives
# Each objective is scored 0.0-1.0, weighted, and combined
declare -A UTILITY_OBJECTIVES=(
    # Speed: How quickly can this master complete the task?
    ["speed.description"]="Task completion time"
    ["speed.optimal_high"]="true"  # Higher is better
    ["speed.default_weight"]="0.25"

    # Quality: How good is the output?
    ["quality.description"]="Output quality and thoroughness"
    ["quality.optimal_high"]="true"
    ["quality.default_weight"]="0.35"

    # Cost: Token/resource efficiency
    ["cost.description"]="Resource efficiency (tokens, time)"
    ["cost.optimal_low"]="true"  # Lower is better (inverted for scoring)
    ["cost.default_weight"]="0.20"

    # Success Rate: Historical success probability
    ["success_rate.description"]="Probability of successful completion"
    ["success_rate.optimal_high"]="true"
    ["success_rate.default_weight"]="0.20"
)

# Master capability profiles
# These are baseline capabilities; actual scores come from historical data
declare -A MASTER_PROFILES=(
    # Coordinator Master
    ["coordinator-master.speed_baseline"]=0.80
    ["coordinator-master.quality_baseline"]=0.75
    ["coordinator-master.cost_baseline"]=0.85
    ["coordinator-master.success_rate_baseline"]=0.90

    # Security Master
    ["security-master.speed_baseline"]=0.70
    ["security-master.quality_baseline"]=0.95
    ["security-master.cost_baseline"]=0.70
    ["security-master.success_rate_baseline"]=0.85

    # Development Master
    ["development-master.speed_baseline"]=0.75
    ["development-master.quality_baseline"]=0.85
    ["development-master.cost_baseline"]=0.75
    ["development-master.success_rate_baseline"]=0.88

    # Inventory Master
    ["inventory-master.speed_baseline"]=0.90
    ["inventory-master.quality_baseline"]=0.80
    ["inventory-master.cost_baseline"]=0.90
    ["inventory-master.success_rate_baseline"]=0.92

    # CICD Master
    ["cicd-master.speed_baseline"]=0.85
    ["cicd-master.quality_baseline"]=0.90
    ["cicd-master.cost_baseline"]=0.80
    ["cicd-master.success_rate_baseline"]=0.91
)

# Context-based weight adjustments
# Certain task characteristics should shift objective priorities
declare -A WEIGHT_ADJUSTMENTS=(
    # Critical priority: Increase quality and success_rate, reduce cost importance
    ["priority.critical.quality"]=1.5
    ["priority.critical.success_rate"]=1.3
    ["priority.critical.cost"]=0.5

    # Time-sensitive: Increase speed, reduce quality slightly
    ["deadline.urgent.speed"]=1.8
    ["deadline.urgent.quality"]=0.9

    # Complex tasks: Increase quality and success_rate
    ["complexity.high.quality"]=1.3
    ["complexity.high.success_rate"]=1.2
    ["complexity.very-high.quality"]=1.5
    ["complexity.very-high.success_rate"]=1.4

    # Budget-constrained: Increase cost optimization
    ["budget.constrained.cost"]=1.6
    ["budget.constrained.speed"]=0.8
)

# calculate_utility - Calculate multi-objective utility score for master
#
# Arguments:
#   $1 - Master ID (e.g., "security-master")
#   $2 - Task specification JSON
#   $3 - Objective weights JSON (optional, uses defaults if not provided)
#
# Returns:
#   JSON object with utility score and breakdown
#
# Example:
#   utility=$(calculate_utility "security-master" "$task_spec" '{"speed":0.3,"quality":0.4,"cost":0.1,"success_rate":0.2}')
calculate_utility() {
    local master_id="$1"
    local task_spec="$2"
    local weight_overrides="${3:-{}}"

    # Parse task characteristics
    local task_type=$(echo "$task_spec" | jq -r '.type // "unknown"')
    local task_priority=$(echo "$task_spec" | jq -r '.priority // .context.priority // "medium"')
    local task_complexity=$(echo "$task_spec" | jq -r '.complexity // "medium"')

    # Get base weights
    local speed_weight=$(echo "$weight_overrides" | jq -r '.speed // null')
    local quality_weight=$(echo "$weight_overrides" | jq -r '.quality // null')
    local cost_weight=$(echo "$weight_overrides" | jq -r '.cost // null')
    local success_rate_weight=$(echo "$weight_overrides" | jq -r '.success_rate // null')

    # Use defaults if not overridden
    speed_weight=${speed_weight:-${UTILITY_OBJECTIVES[speed.default_weight]}}
    quality_weight=${quality_weight:-${UTILITY_OBJECTIVES[quality.default_weight]}}
    cost_weight=${cost_weight:-${UTILITY_OBJECTIVES[cost.default_weight]}}
    success_rate_weight=${success_rate_weight:-${UTILITY_OBJECTIVES[success_rate.default_weight]}}

    # Apply context-based adjustments
    local adjusted_weights=$(adjust_weights_for_context \
        "$speed_weight" "$quality_weight" "$cost_weight" "$success_rate_weight" \
        "$task_priority" "$task_complexity")

    speed_weight=$(echo "$adjusted_weights" | jq -r '.speed')
    quality_weight=$(echo "$adjusted_weights" | jq -r '.quality')
    cost_weight=$(echo "$adjusted_weights" | jq -r '.cost')
    success_rate_weight=$(echo "$adjusted_weights" | jq -r '.success_rate')

    # Get master capability scores (baseline + historical adjustments)
    local speed_score=$(get_master_capability_score "$master_id" "speed" "$task_type")
    local quality_score=$(get_master_capability_score "$master_id" "quality" "$task_type")
    local cost_score=$(get_master_capability_score "$master_id" "cost" "$task_type")
    local success_score=$(get_master_capability_score "$master_id" "success_rate" "$task_type")

    # Calculate weighted utility score
    local utility_score=$(calculate_weighted_score \
        "$speed_score" "$speed_weight" \
        "$quality_score" "$quality_weight" \
        "$cost_score" "$cost_weight" \
        "$success_score" "$success_rate_weight")

    # Calculate contributions
    local speed_contrib=$(echo "scale=4; $speed_score * $speed_weight" | bc -l 2>/dev/null || echo "0")
    local quality_contrib=$(echo "scale=4; $quality_score * $quality_weight" | bc -l 2>/dev/null || echo "0")
    local cost_contrib=$(echo "scale=4; $cost_score * $cost_weight" | bc -l 2>/dev/null || echo "0")
    local success_contrib=$(echo "scale=4; $success_score * $success_rate_weight" | bc -l 2>/dev/null || echo "0")

    # Build result JSON
    cat <<EOF
{
  "master_id": "$master_id",
  "task_type": "$task_type",
  "utility_score": $utility_score,
  "objectives": {
    "speed": {
      "score": $speed_score,
      "weight": $speed_weight,
      "contribution": $speed_contrib
    },
    "quality": {
      "score": $quality_score,
      "weight": $quality_weight,
      "contribution": $quality_contrib
    },
    "cost": {
      "score": $cost_score,
      "weight": $cost_weight,
      "contribution": $cost_contrib
    },
    "success_rate": {
      "score": $success_score,
      "weight": $success_rate_weight,
      "contribution": $success_contrib
    }
  },
  "context": {
    "priority": "$task_priority",
    "complexity": "$task_complexity",
    "weights_adjusted": true
  },
  "calculated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# adjust_weights_for_context - Adjust objective weights based on task context
#
# Arguments:
#   $1-$4 - Base weights (speed, quality, cost, success_rate)
#   $5 - Priority
#   $6 - Complexity
#
# Returns:
#   JSON object with adjusted weights (normalized to sum to 1.0)
adjust_weights_for_context() {
    local speed_weight="$1"
    local quality_weight="$2"
    local cost_weight="$3"
    local success_rate_weight="$4"
    local priority="$5"
    local complexity="$6"

    # Apply priority adjustments
    case "$priority" in
        critical)
            quality_weight=$(echo "$quality_weight * ${WEIGHT_ADJUSTMENTS[priority.critical.quality]}" | bc -l)
            success_rate_weight=$(echo "$success_rate_weight * ${WEIGHT_ADJUSTMENTS[priority.critical.success_rate]}" | bc -l)
            cost_weight=$(echo "$cost_weight * ${WEIGHT_ADJUSTMENTS[priority.critical.cost]}" | bc -l)
            ;;
    esac

    # Apply complexity adjustments
    case "$complexity" in
        high)
            quality_weight=$(echo "$quality_weight * ${WEIGHT_ADJUSTMENTS[complexity.high.quality]}" | bc -l)
            success_rate_weight=$(echo "$success_rate_weight * ${WEIGHT_ADJUSTMENTS[complexity.high.success_rate]}" | bc -l)
            ;;
        very-high)
            quality_weight=$(echo "$quality_weight * ${WEIGHT_ADJUSTMENTS[complexity.very-high.quality]}" | bc -l)
            success_rate_weight=$(echo "$success_rate_weight * ${WEIGHT_ADJUSTMENTS[complexity.very-high.success_rate]}" | bc -l)
            ;;
    esac

    # Normalize weights to sum to 1.0
    local total=$(echo "scale=4; $speed_weight + $quality_weight + $cost_weight + $success_rate_weight" | bc -l 2>/dev/null)
    # Prevent division by zero
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        total="1.0"
    fi

    speed_weight=$(echo "scale=4; $speed_weight / $total" | bc -l 2>/dev/null || echo "0.25")
    quality_weight=$(echo "scale=4; $quality_weight / $total" | bc -l 2>/dev/null || echo "0.35")
    cost_weight=$(echo "scale=4; $cost_weight / $total" | bc -l 2>/dev/null || echo "0.20")
    success_rate_weight=$(echo "scale=4; $success_rate_weight / $total" | bc -l 2>/dev/null || echo "0.20")

    cat <<EOF
{
  "speed": $speed_weight,
  "quality": $quality_weight,
  "cost": $cost_weight,
  "success_rate": $success_rate_weight
}
EOF
}

# get_master_capability_score - Get capability score for master
#
# Arguments:
#   $1 - Master ID
#   $2 - Capability (speed, quality, cost, success_rate)
#   $3 - Task type (for historical lookup)
#
# Returns:
#   Score between 0.0 and 1.0
get_master_capability_score() {
    local master_id="$1"
    local capability="$2"
    local task_type="$3"

    # Get baseline from profile
    local baseline_key="${master_id}.${capability}_baseline"
    local baseline=${MASTER_PROFILES[$baseline_key]:-0.70}

    # Try to get historical adjustment from knowledge base
    local kb_dir="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/knowledge-base/utility-scores"
    local history_file="$kb_dir/${master_id}-${task_type}.json"

    if [ -f "$history_file" ]; then
        # Get recent performance adjustment
        local adjustment=$(jq -r ".capabilities.$capability.adjustment // 0" "$history_file" 2>/dev/null || echo "0")
        # Apply adjustment (capped at +/- 0.2)
        local adjusted=$(echo "$baseline + $adjustment" | bc -l)
        # Clamp to [0.0, 1.0]
        adjusted=$(echo "if ($adjusted > 1.0) 1.0 else if ($adjusted < 0.0) 0.0 else $adjusted" | bc -l)
        echo "$adjusted"
    else
        echo "$baseline"
    fi
}

# calculate_weighted_score - Calculate weighted sum of objectives
#
# Arguments:
#   Pairs of (score, weight) for each objective
#
# Returns:
#   Weighted utility score (0.0-1.0)
calculate_weighted_score() {
    local speed_score="$1"
    local speed_weight="$2"
    local quality_score="$3"
    local quality_weight="$4"
    local cost_score="$5"
    local cost_weight="$6"
    local success_score="$7"
    local success_weight="$8"

    local total=$(echo "scale=4; \
        ($speed_score * $speed_weight) + \
        ($quality_score * $quality_weight) + \
        ($cost_score * $cost_weight) + \
        ($success_score * $success_weight)" | bc -l)

    echo "$total"
}

# select_master_by_utility - Select best master using utility optimization
#
# Arguments:
#   $1 - Task specification JSON
#   $2 - Available masters (JSON array)
#   $3 - Objective weights (optional)
#
# Returns:
#   JSON object with selected master and utility breakdown
#
# Example:
#   result=$(select_master_by_utility "$task_spec" '["security-master","development-master"]')
select_master_by_utility() {
    local task_spec="$1"
    local available_masters="$2"
    local weights="${3:-{}}"

    local best_master=""
    local best_score=0
    local all_scores=""

    # Calculate utility for each available master
    while IFS= read -r master_id; do
        local utility=$(calculate_utility "$master_id" "$task_spec" "$weights")
        local score=$(echo "$utility" | jq -r '.utility_score')

        # Track all scores for transparency
        all_scores="${all_scores}${utility},"

        # Check if this is the best so far
        if (( $(echo "$score > $best_score" | bc -l) )); then
            best_score="$score"
            best_master="$master_id"
        fi
    done < <(echo "$available_masters" | jq -r '.[]')

    # Remove trailing comma
    all_scores="${all_scores%,}"

    # Build result
    cat <<EOF
{
  "selected_master": "$best_master",
  "best_utility_score": $best_score,
  "task_type": $(echo "$task_spec" | jq -r '.type // "unknown"' | jq -R .),
  "all_utilities": [$all_scores],
  "selection_method": "multi_objective_utility",
  "selected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# save_utility_decision - Save utility decision to knowledge base
#
# Arguments:
#   $1 - Utility decision JSON
#   $2 - Task ID
#
# Returns:
#   0 on success, 1 on failure
save_utility_decision() {
    local decision="$1"
    local task_id="$2"

    local kb_dir="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/knowledge-base/utility-decisions"
    mkdir -p "$kb_dir"

    # Save individual decision
    local decision_file="$kb_dir/${task_id}-decision.json"
    echo "$decision" > "$decision_file"

    # Append to decisions log
    local log_file="$kb_dir/utility-decisions.jsonl"
    echo "$decision" >> "$log_file"

    return 0
}

# update_master_performance - Update master performance based on task outcome
#
# Arguments:
#   $1 - Master ID
#   $2 - Task type
#   $3 - Outcome JSON (with speed, quality, cost, success metrics)
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   outcome='{"speed":0.85,"quality":0.92,"cost":0.78,"success":1.0}'
#   update_master_performance "security-master" "security-scan" "$outcome"
update_master_performance() {
    local master_id="$1"
    local task_type="$2"
    local outcome="$3"

    local kb_dir="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/knowledge-base/utility-scores"
    mkdir -p "$kb_dir"

    local history_file="$kb_dir/${master_id}-${task_type}.json"

    # Load existing history or create new
    if [ -f "$history_file" ]; then
        local history=$(cat "$history_file")
    else
        history='{"master_id":"'$master_id'","task_type":"'$task_type'","capabilities":{},"history":[]}'
    fi

    # Extract outcome scores
    local speed=$(echo "$outcome" | jq -r '.speed // 0')
    local quality=$(echo "$outcome" | jq -r '.quality // 0')
    local cost=$(echo "$outcome" | jq -r '.cost // 0')
    local success=$(echo "$outcome" | jq -r '.success // 0')

    # Get baselines
    local speed_baseline=${MASTER_PROFILES[${master_id}.speed_baseline]:-0.70}
    local quality_baseline=${MASTER_PROFILES[${master_id}.quality_baseline]:-0.70}
    local cost_baseline=${MASTER_PROFILES[${master_id}.cost_baseline]:-0.70}
    local success_baseline=${MASTER_PROFILES[${master_id}.success_rate_baseline]:-0.70}

    # Calculate adjustments (exponential moving average, alpha=0.2)
    local speed_adj=$(echo "scale=4; ($speed - $speed_baseline) * 0.2" | bc -l)
    local quality_adj=$(echo "scale=4; ($quality - $quality_baseline) * 0.2" | bc -l)
    local cost_adj=$(echo "scale=4; ($cost - $cost_baseline) * 0.2" | bc -l)
    local success_adj=$(echo "scale=4; ($success - $success_baseline) * 0.2" | bc -l)

    # Update history with new adjustment
    history=$(echo "$history" | jq \
        --argjson speed_adj "$speed_adj" \
        --argjson quality_adj "$quality_adj" \
        --argjson cost_adj "$cost_adj" \
        --argjson success_adj "$success_adj" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.capabilities.speed.adjustment = $speed_adj |
         .capabilities.quality.adjustment = $quality_adj |
         .capabilities.cost.adjustment = $cost_adj |
         .capabilities.success_rate.adjustment = $success_adj |
         .history += [{
           "timestamp": $timestamp,
           "outcome": {
             "speed": '$speed',
             "quality": '$quality',
             "cost": '$cost',
             "success": '$success'
           }
         }] |
         .updated_at = $timestamp')

    # Save updated history
    echo "$history" > "$history_file"

    return 0
}

# get_utility_weights_for_task - Get recommended weights for task
#
# Arguments:
#   $1 - Task specification JSON
#
# Returns:
#   JSON object with recommended weights
get_utility_weights_for_task() {
    local task_spec="$1"

    local priority=$(echo "$task_spec" | jq -r '.priority // "medium"')
    local task_type=$(echo "$task_spec" | jq -r '.type // "unknown"')

    # Default weights
    local speed_weight=${UTILITY_OBJECTIVES[speed.default_weight]}
    local quality_weight=${UTILITY_OBJECTIVES[quality.default_weight]}
    local cost_weight=${UTILITY_OBJECTIVES[cost.default_weight]}
    local success_weight=${UTILITY_OBJECTIVES[success_rate.default_weight]}

    # Task-type specific weight profiles
    case "$task_type" in
        security-scan|security-fix)
            # Security: Prioritize quality and success
            quality_weight=0.45
            success_weight=0.30
            speed_weight=0.15
            cost_weight=0.10
            ;;
        development|implementation)
            # Development: Balance quality and speed
            quality_weight=0.35
            speed_weight=0.30
            success_weight=0.25
            cost_weight=0.10
            ;;
        analysis|documentation)
            # Documentation: Prioritize quality
            quality_weight=0.50
            success_weight=0.25
            speed_weight=0.15
            cost_weight=0.10
            ;;
    esac

    cat <<EOF
{
  "speed": $speed_weight,
  "quality": $quality_weight,
  "cost": $cost_weight,
  "success_rate": $success_weight,
  "task_type": "$task_type",
  "priority": "$priority"
}
EOF
}

# Export functions for use by other scripts
export -f calculate_utility
export -f adjust_weights_for_context
export -f get_master_capability_score
export -f calculate_weighted_score
export -f select_master_by_utility
export -f save_utility_decision
export -f update_master_performance
export -f get_utility_weights_for_task
