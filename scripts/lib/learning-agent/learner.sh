#!/bin/bash
# scripts/lib/learning-agent/learner.sh
# Learning Agent: Learner Component
# Week 5: Q1 Implementation - Learning Agent (Critic & Learner)
#
# Purpose: Update models and patterns based on critic feedback
# Part of the ASI (Artificial Superintelligence) learning cycle
#
# Functions:
# - extract_patterns(): Mine successful and failed patterns
# - update_routing_model(): Enhance MoE router with learned patterns
# - update_utility_weights(): Optimize utility function based on outcomes
# - calculate_improvement(): Track learning progress over time
#
# Learning Flow:
#   Training Examples → Pattern Extraction → Model Updates → Improved Performance

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Load dependencies
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Configuration
TRAINING_EXAMPLES_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-examples"
PATTERNS_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/learned-patterns"
MOE_KB_DIR="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base"
UTILITY_WEIGHTS_FILE="$COMMIT_RELAY_HOME/coordination/config/utility-weights.json"
LEARNING_METRICS_DIR="$COMMIT_RELAY_HOME/coordination/metrics/learning"
MODEL_VERSIONS_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/model-versions"

# Ensure directories exist
mkdir -p "$PATTERNS_DIR" "$LEARNING_METRICS_DIR" "$MODEL_VERSIONS_DIR"

#------------------------------------------------------------------------------
# extract_patterns()
# Mine patterns from training examples
#
# Args:
#   $1 - min_examples: Minimum examples to consider pattern valid (default: 3)
#   $2 - since_timestamp: Only process examples since this time (optional)
#
# Returns:
#   Path to extracted patterns file
#------------------------------------------------------------------------------
extract_patterns() {
    local min_examples="${1:-3}"
    local since_timestamp="${2:-}"

    log_info "[Learner] Extracting patterns from training examples (min: $min_examples)"

    local positive_file="$TRAINING_EXAMPLES_DIR/positive-examples.jsonl"
    local negative_file="$TRAINING_EXAMPLES_DIR/negative-examples.jsonl"

    # Validate files exist
    if [ ! -f "$positive_file" ]; then
        log_warn "[Learner] No positive examples found"
        touch "$positive_file"
    fi
    if [ ! -f "$negative_file" ]; then
        log_warn "[Learner] No negative examples found"
        touch "$negative_file"
    fi

    # Extract successful patterns (positive examples)
    local successful_patterns=$(extract_successful_patterns "$positive_file" "$min_examples" "$since_timestamp")

    # Extract failed patterns (negative examples)
    local failed_patterns=$(extract_failed_patterns "$negative_file" "$min_examples" "$since_timestamp")

    # Extract context indicators for routing
    local routing_patterns=$(extract_routing_patterns "$positive_file" "$min_examples" "$since_timestamp")

    # Combine patterns
    local patterns=$(jq -n \
        --argjson successful "$successful_patterns" \
        --argjson failed "$failed_patterns" \
        --argjson routing "$routing_patterns" \
        --arg extracted_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson min_examples "$min_examples" \
        '{
            extracted_at: $extracted_at,
            min_examples: $min_examples,
            successful_patterns: $successful,
            failed_patterns: $failed,
            routing_patterns: $routing,
            summary: {
                successful_count: ($successful | length),
                failed_count: ($failed | length),
                routing_count: ($routing | length)
            }
        }')

    # Save patterns
    local patterns_file="$PATTERNS_DIR/patterns-$(date +%Y%m%d-%H%M%S).json"
    echo "$patterns" > "$patterns_file"

    # Also save as latest
    echo "$patterns" > "$PATTERNS_DIR/patterns-latest.json"

    local successful_count=$(echo "$patterns" | jq -r '.summary.successful_count')
    local failed_count=$(echo "$patterns" | jq -r '.summary.failed_count')
    local routing_count=$(echo "$patterns" | jq -r '.summary.routing_count')

    log_info "[Learner] Patterns extracted: $successful_count successful, $failed_count failed, $routing_count routing"

    echo "$patterns_file"
}

#------------------------------------------------------------------------------
# extract_successful_patterns()
# Find patterns from successful executions
#
# Args:
#   $1 - positive_examples_file
#   $2 - min_examples
#   $3 - since_timestamp
#
# Returns:
#   JSON array of successful patterns
#------------------------------------------------------------------------------
extract_successful_patterns() {
    local examples_file="$1"
    local min_examples="$2"
    local since_timestamp="$3"

    if [ ! -s "$examples_file" ]; then
        echo "[]"
        return
    fi

    # Group by (task_type, strategy) and find high-performing combinations
    local patterns=$(cat "$examples_file" | \
        if [ -n "$since_timestamp" ]; then
            jq -c "select(.created_at >= \"$since_timestamp\")"
        else
            cat
        fi | \
        jq -s '
            group_by(.context.task_type + "|" + .action.strategy_used) |
            map({
                task_type: .[0].context.task_type,
                strategy: .[0].action.strategy_used,
                worker_type: .[0].action.worker_type,
                count: length,
                avg_score: (map(.overall_score) | (add / length)),
                min_score: (map(.overall_score) | min),
                max_score: (map(.overall_score) | max),
                examples: map(.example_id)
            }) |
            map(select(.count >= '"$min_examples"' and .avg_score >= 70))
        ')

    echo "$patterns"
}

#------------------------------------------------------------------------------
# extract_failed_patterns()
# Find patterns from failed executions to avoid
#
# Args:
#   $1 - negative_examples_file
#   $2 - min_examples
#   $3 - since_timestamp
#
# Returns:
#   JSON array of failed patterns
#------------------------------------------------------------------------------
extract_failed_patterns() {
    local examples_file="$1"
    local min_examples="$2"
    local since_timestamp="$3"

    if [ ! -s "$examples_file" ]; then
        echo "[]"
        return
    fi

    # Group by (task_type, strategy) and find low-performing combinations
    local patterns=$(cat "$examples_file" | \
        if [ -n "$since_timestamp" ]; then
            jq -c "select(.created_at >= \"$since_timestamp\")"
        else
            cat
        fi | \
        jq -s '
            group_by(.context.task_type + "|" + .action.strategy_used) |
            map({
                task_type: .[0].context.task_type,
                strategy: .[0].action.strategy_used,
                worker_type: .[0].action.worker_type,
                count: length,
                avg_score: (map(.overall_score) | (add / length)),
                failure_rate: ((map(select(.outcome.classification == "failure")) | length) / length),
                examples: map(.example_id)
            }) |
            map(select(.count >= '"$min_examples"' and (.avg_score < 50 or .failure_rate > 0.3)))
        ')

    echo "$patterns"
}

#------------------------------------------------------------------------------
# extract_routing_patterns()
# Extract context → master routing patterns
#
# Args:
#   $1 - examples_file
#   $2 - min_examples
#   $3 - since_timestamp
#
# Returns:
#   JSON array of routing patterns
#------------------------------------------------------------------------------
extract_routing_patterns() {
    local examples_file="$1"
    local min_examples="$2"
    local since_timestamp="$3"

    if [ ! -s "$examples_file" ]; then
        echo "[]"
        return
    fi

    # Extract patterns: context indicators → worker_type
    local patterns=$(cat "$examples_file" | \
        if [ -n "$since_timestamp" ]; then
            jq -c "select(.created_at >= \"$since_timestamp\")"
        else
            cat
        fi | \
        jq -s '
            group_by(.context.task_type + "|" + .context.complexity) |
            map({
                task_type: .[0].context.task_type,
                complexity: .[0].context.complexity,
                preferred_worker_type: (
                    group_by(.action.worker_type) |
                    map({worker_type: .[0].action.worker_type, avg_score: (map(.overall_score) | (add / length))}) |
                    max_by(.avg_score) |
                    .worker_type
                ),
                count: length,
                avg_score: (map(.overall_score) | (add / length))
            }) |
            map(select(.count >= '"$min_examples"' and .avg_score >= 70))
        ')

    echo "$patterns"
}

#------------------------------------------------------------------------------
# update_routing_model()
# Update MoE router with learned patterns
#
# Args:
#   $1 - patterns_file: Path to extracted patterns file
#
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
update_routing_model() {
    local patterns_file="$1"

    log_info "[Learner] Updating routing model with learned patterns"

    if [ ! -f "$patterns_file" ]; then
        log_error "[Learner] Patterns file not found: $patterns_file"
        return 1
    fi

    local patterns=$(cat "$patterns_file")
    local routing_patterns=$(echo "$patterns" | jq -r '.routing_patterns')

    # Load existing routing decisions (MoE knowledge base)
    local routing_kb="$MOE_KB_DIR/routing-decisions.jsonl"
    if [ ! -f "$routing_kb" ]; then
        log_warn "[Learner] Routing KB not found, creating new: $routing_kb"
        mkdir -p "$MOE_KB_DIR"
        touch "$routing_kb"
    fi

    # Create versioned backup before updating
    local version=$(date +%Y%m%d-%H%M%S)
    local backup_file="$MODEL_VERSIONS_DIR/routing-model-$version.jsonl"
    if [ -f "$routing_kb" ] && [ -s "$routing_kb" ]; then
        cp "$routing_kb" "$backup_file"
        log_info "[Learner] Routing model backed up to: $backup_file"
    fi

    # Add learned patterns to routing knowledge base
    local patterns_added=0
    echo "$routing_patterns" | jq -c '.[]' | while read -r pattern; do
        local task_type=$(echo "$pattern" | jq -r '.task_type')
        local complexity=$(echo "$pattern" | jq -r '.complexity')
        local preferred_worker=$(echo "$pattern" | jq -r '.preferred_worker_type')
        local avg_score=$(echo "$pattern" | jq -r '.avg_score')
        local count=$(echo "$pattern" | jq -r '.count')

        # Create routing rule
        local routing_rule=$(jq -n \
            --arg task_type "$task_type" \
            --arg complexity "$complexity" \
            --arg worker_type "$preferred_worker" \
            --argjson confidence "$avg_score" \
            --argjson evidence_count "$count" \
            --arg learned_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --arg source "learner" \
            '{
                task_type: $task_type,
                complexity: $complexity,
                recommended_worker_type: $worker_type,
                confidence: $confidence,
                evidence_count: $evidence_count,
                learned_at: $learned_at,
                source: $source
            }')

        echo "$routing_rule" >> "$routing_kb"
        patterns_added=$((patterns_added + 1))
    done

    log_info "[Learner] Added $patterns_added routing patterns to MoE knowledge base"

    # Update successful patterns
    update_successful_patterns "$patterns_file"

    # Update failed patterns (to avoid)
    update_failed_patterns "$patterns_file"

    # Record metric
    record_learning_metric "routing_model_update" "$patterns_added"

    return 0
}

#------------------------------------------------------------------------------
# update_successful_patterns()
# Add successful patterns to knowledge base
#
# Args:
#   $1 - patterns_file
#------------------------------------------------------------------------------
update_successful_patterns() {
    local patterns_file="$1"
    local patterns=$(cat "$patterns_file")
    local successful_patterns=$(echo "$patterns" | jq -r '.successful_patterns')

    local success_kb="$PATTERNS_DIR/successful-patterns.jsonl"

    echo "$successful_patterns" | jq -c '.[]' | while read -r pattern; do
        echo "$pattern" >> "$success_kb"
    done

    local count=$(echo "$successful_patterns" | jq '. | length')
    log_info "[Learner] Added $count successful patterns to knowledge base"
}

#------------------------------------------------------------------------------
# update_failed_patterns()
# Add failed patterns to avoid list
#
# Args:
#   $1 - patterns_file
#------------------------------------------------------------------------------
update_failed_patterns() {
    local patterns_file="$1"
    local patterns=$(cat "$patterns_file")
    local failed_patterns=$(echo "$patterns" | jq -r '.failed_patterns')

    local failed_kb="$PATTERNS_DIR/failed-patterns.jsonl"

    echo "$failed_patterns" | jq -c '.[]' | while read -r pattern; do
        local annotated=$(echo "$pattern" | jq '. + {avoid: true, learned_at: "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"}')
        echo "$annotated" >> "$failed_kb"
    done

    local count=$(echo "$failed_patterns" | jq '. | length')
    log_info "[Learner] Added $count failed patterns to avoid list"
}

#------------------------------------------------------------------------------
# update_utility_weights()
# Optimize utility function weights based on outcomes
#
# Args:
#   $1 - patterns_file: Path to extracted patterns file
#
# Returns:
#   0 on success, 1 on failure
#------------------------------------------------------------------------------
update_utility_weights() {
    local patterns_file="$1"

    log_info "[Learner] Updating utility weights based on learned patterns"

    if [ ! -f "$patterns_file" ]; then
        log_error "[Learner] Patterns file not found: $patterns_file"
        return 1
    fi

    # Initialize or load existing utility weights
    if [ ! -f "$UTILITY_WEIGHTS_FILE" ]; then
        log_info "[Learner] Creating default utility weights file"
        mkdir -p "$(dirname "$UTILITY_WEIGHTS_FILE")"
        create_default_utility_weights
    fi

    # Backup current weights
    local version=$(date +%Y%m%d-%H%M%S)
    local backup_file="$MODEL_VERSIONS_DIR/utility-weights-$version.json"
    cp "$UTILITY_WEIGHTS_FILE" "$backup_file"
    log_info "[Learner] Utility weights backed up to: $backup_file"

    # Load current weights
    local current_weights=$(cat "$UTILITY_WEIGHTS_FILE")

    # Analyze patterns to determine weight adjustments
    local patterns=$(cat "$patterns_file")
    local successful_patterns=$(echo "$patterns" | jq -r '.successful_patterns')

    # Calculate average scores by dimension
    local quality_importance=$(calculate_dimension_importance "$successful_patterns" "quality")
    local efficiency_importance=$(calculate_dimension_importance "$successful_patterns" "efficiency")
    local success_importance=$(calculate_dimension_importance "$successful_patterns" "success")

    # Update weights with learning rate (0.1 = 10% adjustment)
    local learning_rate=0.1
    local updated_weights=$(echo "$current_weights" | jq \
        --argjson quality "$quality_importance" \
        --argjson efficiency "$efficiency_importance" \
        --argjson success "$success_importance" \
        --argjson lr "$learning_rate" \
        '
        # Handle both old (.weights) and new (.default_weights) structures
        if .weights then
            .weights.quality = ((.weights.quality // 0.3) * (1 - $lr)) + ($quality * $lr) |
            .weights.efficiency = ((.weights.efficiency // 0.2) * (1 - $lr)) + ($efficiency * $lr) |
            .weights.success = ((.weights.success // 0.5) * (1 - $lr)) + ($success * $lr) |
            .updated_at = now | strftime("%Y-%m-%dT%H:%M:%SZ") |
            .version = ((.version // 0) + 1)
        elif .default_weights then
            .default_weights.quality = ((.default_weights.quality // 0.35) * (1 - $lr)) + ($quality * $lr) |
            .default_weights.speed = ((.default_weights.speed // 0.25) * (1 - $lr)) + ($efficiency * $lr) |
            .default_weights.success_rate = ((.default_weights.success_rate // 0.20) * (1 - $lr)) + ($success * $lr) |
            .metadata.updated_at = now | strftime("%Y-%m-%dT%H:%M:%SZ")
        else
            .weights = {
                quality: $quality,
                efficiency: $efficiency,
                success: $success
            } |
            .updated_at = now | strftime("%Y-%m-%dT%H:%M:%SZ") |
            .version = 1
        end
        ')

    # Normalize weights to sum to 1.0
    local normalized_weights=$(echo "$updated_weights" | jq '
        if .weights then
            .weights as $w |
            (($w.quality // 0) + ($w.efficiency // 0) + ($w.success // 0)) as $sum |
            if $sum > 0 then
                .weights.quality = ($w.quality / $sum) |
                .weights.efficiency = ($w.efficiency / $sum) |
                .weights.success = ($w.success / $sum)
            else
                .
            end
        elif .default_weights then
            .default_weights as $w |
            (($w.quality // 0) + ($w.speed // 0) + ($w.success_rate // 0) + ($w.cost // 0)) as $sum |
            if $sum > 0 then
                .default_weights.quality = ($w.quality / $sum) |
                .default_weights.speed = ($w.speed / $sum) |
                .default_weights.success_rate = ($w.success_rate / $sum) |
                .default_weights.cost = ($w.cost / $sum)
            else
                .
            end
        else
            .
        end
    ')

    # Save updated weights
    echo "$normalized_weights" > "$UTILITY_WEIGHTS_FILE"

    # Extract weights based on structure
    local new_quality=$(echo "$normalized_weights" | jq -r '.weights.quality // .default_weights.quality // "N/A"')
    local new_efficiency=$(echo "$normalized_weights" | jq -r '.weights.efficiency // .default_weights.speed // "N/A"')
    local new_success=$(echo "$normalized_weights" | jq -r '.weights.success // .default_weights.success_rate // "N/A"')

    log_info "[Learner] Updated utility weights: quality=$new_quality, efficiency=$new_efficiency, success=$new_success"

    # Record metric
    record_learning_metric "utility_weights_update" "1"

    return 0
}

#------------------------------------------------------------------------------
# create_default_utility_weights()
# Create default utility weights configuration
#------------------------------------------------------------------------------
create_default_utility_weights() {
    local default_weights=$(jq -n '{
        version: 1,
        weights: {
            quality: 0.30,
            efficiency: 0.20,
            success: 0.50
        },
        created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        updated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')

    echo "$default_weights" > "$UTILITY_WEIGHTS_FILE"
}

#------------------------------------------------------------------------------
# calculate_dimension_importance()
# Calculate importance of a dimension based on correlation with success
#
# Args:
#   $1 - patterns_json: JSON array of patterns
#   $2 - dimension: quality, efficiency, or success
#
# Returns:
#   Importance score (0.0-1.0)
#------------------------------------------------------------------------------
calculate_dimension_importance() {
    local patterns_json="$1"
    local dimension="$2"

    # Simple heuristic: dimension importance = average score of that dimension
    # in successful patterns
    # In a more sophisticated system, we'd calculate correlation coefficients

    local importance=$(echo "$patterns_json" | jq -r '
        if length == 0 then 0.33
        else
            map(select(.avg_score >= 70)) |
            if length == 0 then 0.33
            else
                # For now, use equal weights as baseline
                # In production, analyze actual dimension scores
                0.33
            end
        end
    ')

    echo "$importance"
}

#------------------------------------------------------------------------------
# calculate_improvement()
# Track learning progress over time
#
# Args:
#   $1 - timeframe: "week", "day", or "hour"
#
# Returns:
#   Improvement metrics JSON
#------------------------------------------------------------------------------
calculate_improvement() {
    local timeframe="${1:-week}"

    log_info "[Learner] Calculating improvement metrics for timeframe: $timeframe"

    local evaluations_file="$LEARNING_METRICS_DIR/evaluations.jsonl"

    if [ ! -f "$evaluations_file" ]; then
        log_warn "[Learner] No evaluation metrics found"
        echo '{"improvement_percent": 0, "insufficient_data": true}'
        return
    fi

    # Calculate time boundaries
    local current_ts=$(date +%s)
    local period_seconds=0

    case "$timeframe" in
        hour)
            period_seconds=3600
            ;;
        day)
            period_seconds=86400
            ;;
        week)
            period_seconds=604800
            ;;
        *)
            log_error "[Learner] Invalid timeframe: $timeframe"
            return 1
            ;;
    esac

    local start_ts=$((current_ts - period_seconds))
    local mid_ts=$((current_ts - (period_seconds / 2)))

    # Convert to ISO timestamps
    local start_time=$(date -u -r "$start_ts" +"%Y-%m-%dT%H:%M:%SZ")
    local mid_time=$(date -u -r "$mid_ts" +"%Y-%m-%dT%H:%M:%SZ")

    # Calculate metrics for first half of period
    local first_half_metrics=$(cat "$evaluations_file" | jq -s --arg start "$start_time" --arg mid "$mid_time" '
        map(select(.timestamp >= $start and .timestamp < $mid)) |
        if length > 0 then
            {
                count: length,
                avg_score: (map(.score) | (add / length)),
                success_rate: ((map(select(.outcome == "success_high_quality" or .outcome == "success_standard")) | length) / length)
            }
        else
            {count: 0, avg_score: 0, success_rate: 0}
        end
    ')

    # Calculate metrics for second half of period
    local second_half_metrics=$(cat "$evaluations_file" | jq -s --arg mid "$mid_time" '
        map(select(.timestamp >= $mid)) |
        if length > 0 then
            {
                count: length,
                avg_score: (map(.score) | (add / length)),
                success_rate: ((map(select(.outcome == "success_high_quality" or .outcome == "success_standard")) | length) / length)
            }
        else
            {count: 0, avg_score: 0, success_rate: 0}
        end
    ')

    # Calculate improvement
    local first_count=$(echo "$first_half_metrics" | jq -r '.count')
    local second_count=$(echo "$second_half_metrics" | jq -r '.count')

    if [ "$first_count" -lt 3 ] || [ "$second_count" -lt 3 ]; then
        log_warn "[Learner] Insufficient data for meaningful improvement calculation"
        echo '{"improvement_percent": 0, "insufficient_data": true}'
        return
    fi

    local improvement=$(jq -n \
        --argjson first "$first_half_metrics" \
        --argjson second "$second_half_metrics" \
        --arg timeframe "$timeframe" \
        '{
            timeframe: $timeframe,
            first_half: $first,
            second_half: $second,
            score_improvement_percent: (($second.avg_score - $first.avg_score) / $first.avg_score * 100),
            success_rate_improvement_percent: (($second.success_rate - $first.success_rate) / $first.success_rate * 100),
            sufficient_data: true
        }')

    local score_improvement=$(echo "$improvement" | jq -r '.score_improvement_percent')
    local success_improvement=$(echo "$improvement" | jq -r '.success_rate_improvement_percent')

    log_info "[Learner] Improvement: score=${score_improvement}%, success_rate=${success_improvement}%"

    # Record improvement metric
    record_learning_metric "improvement_calculated" "$score_improvement"

    echo "$improvement"
}

#------------------------------------------------------------------------------
# record_learning_metric()
# Record learning metrics for tracking
#
# Args:
#   $1 - metric_name
#   $2 - value
#------------------------------------------------------------------------------
record_learning_metric() {
    local metric_name="$1"
    local value="$2"

    local metric=$(jq -n \
        --arg name "$metric_name" \
        --arg value "$value" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            timestamp: $timestamp,
            metric: $name,
            value: $value
        }')

    echo "$metric" >> "$LEARNING_METRICS_DIR/learner-metrics.jsonl"
}

#------------------------------------------------------------------------------
# run_daily_learning()
# Main daily learning workflow
#
# Returns:
#   0 on success
#------------------------------------------------------------------------------
run_daily_learning() {
    log_info "[Learner] Starting daily learning cycle"

    local start_time=$(date +%s)

    # Extract patterns from training examples
    local patterns_file=$(extract_patterns 3)

    if [ ! -f "$patterns_file" ]; then
        log_error "[Learner] Pattern extraction failed"
        return 1
    fi

    # Update routing model
    update_routing_model "$patterns_file"

    # Update utility weights
    update_utility_weights "$patterns_file"

    # Calculate improvement
    local improvement=$(calculate_improvement "week")
    local improvement_file="$LEARNING_METRICS_DIR/improvement-$(date +%Y%m%d).json"
    echo "$improvement" > "$improvement_file"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "[Learner] Daily learning cycle complete (duration: ${duration}s)"

    # Record completion metric
    record_learning_metric "daily_learning_complete" "$duration"

    return 0
}

#------------------------------------------------------------------------------
# Main execution (if called directly)
#------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Support multiple modes
    case "${1:-daily}" in
        daily)
            run_daily_learning
            ;;
        extract)
            patterns_file=$(extract_patterns "${2:-3}")
            cat "$patterns_file" | jq .
            ;;
        update-routing)
            if [ $# -lt 2 ]; then
                echo "Usage: learner.sh update-routing <patterns_file>"
                exit 1
            fi
            update_routing_model "$2"
            ;;
        update-weights)
            if [ $# -lt 2 ]; then
                echo "Usage: learner.sh update-weights <patterns_file>"
                exit 1
            fi
            update_utility_weights "$2"
            ;;
        improvement)
            calculate_improvement "${2:-week}" | jq .
            ;;
        *)
            echo "Usage: learner.sh {daily|extract|update-routing|update-weights|improvement}"
            echo ""
            echo "Modes:"
            echo "  daily              - Run full daily learning cycle"
            echo "  extract [min]      - Extract patterns from training examples"
            echo "  update-routing <f> - Update routing model from patterns file"
            echo "  update-weights <f> - Update utility weights from patterns file"
            echo "  improvement [tf]   - Calculate improvement (timeframe: hour/day/week)"
            exit 1
            ;;
    esac
fi
