#!/bin/bash
# Meta-Learning for Cross-Task Optimization
# Phase 5 Item #58: Extract meta-patterns that succeed across task types

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
}

# Meta-learning directories
META_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/meta-learning"
mkdir -p "$META_DIR"

# Extract patterns from successful tasks
extract_success_patterns() {
    local days="${1:-30}"
    local min_score="${2:-80}"

    log_info "Extracting success patterns from last $days days (min score: $min_score)"

    local patterns_file="$META_DIR/success-patterns.jsonl"
    local feedback_dir="$COMMIT_RELAY_HOME/coordination/knowledge-base/feedback-reports"

    # Analyze feedback reports
    local patterns='[]'

    for feedback_file in "$feedback_dir"/routing-feedback-*.jsonl; do
        [ -f "$feedback_file" ] || continue

        # Get successful outcomes
        local successes=$(cat "$feedback_file" | jq -s "[.[] | select(.outcome == \"success\" and .score >= $min_score)]")
        local count=$(echo "$successes" | jq 'length')

        if [ "$count" -gt 0 ]; then
            # Extract common patterns
            local expert_patterns=$(echo "$successes" | jq -c 'group_by(.expert) | map({expert: .[0].expert, count: length, avg_score: (map(.score) | add / length)})')
            patterns=$(echo "$patterns" | jq --argjson p "$expert_patterns" '. + $p')
        fi
    done

    # Deduplicate and rank patterns
    echo "$patterns" | jq -s 'flatten | group_by(.expert) | map({
        expert: .[0].expert,
        total_successes: (map(.count) | add),
        avg_score: (map(.avg_score * .count) | add) / (map(.count) | add)
    }) | sort_by(-.total_successes)'
}

# Learn cross-task optimization strategies
learn_optimization_strategies() {
    log_info "Learning optimization strategies..."

    local strategies='[]'

    # Analyze worker performance patterns
    local worker_specs_dir="$COMMIT_RELAY_HOME/coordination/worker-specs/completed"

    if [ -d "$worker_specs_dir" ]; then
        # Group by worker type and analyze performance
        for spec_file in "$worker_specs_dir"/*.json; do
            [ -f "$spec_file" ] || continue

            local worker_type=$(jq -r '.worker_type' "$spec_file")
            local duration=$(jq -r '.execution.duration_minutes // 0' "$spec_file")
            local token_used=$(jq -r '.resources.tokens_used // 0' "$spec_file")
            local success=$(jq -r '.results.status == "completed"' "$spec_file")

            if [ "$success" = "true" ]; then
                local strategy=$(jq -n \
                    --arg type "$worker_type" \
                    --argjson duration "$duration" \
                    --argjson tokens "$token_used" \
                    '{worker_type: $type, duration: $duration, tokens: $tokens}')
                strategies=$(echo "$strategies" | jq --argjson s "$strategy" '. + [$s]')
            fi
        done
    fi

    # Generate optimization recommendations
    echo "$strategies" | jq -s 'flatten | group_by(.worker_type) | map({
        worker_type: .[0].worker_type,
        sample_size: length,
        avg_duration: (map(.duration) | add / length),
        avg_tokens: (map(.tokens) | add / length),
        efficiency: (map(.duration) | add) / (map(.tokens) | add) * 1000
    }) | sort_by(-.efficiency)'
}

# Generate meta-learning report
generate_meta_report() {
    local output_file="$META_DIR/meta-report-$(date +%Y%m%d).json"

    log_info "Generating meta-learning report..."

    local success_patterns=$(extract_success_patterns 30 75)
    local optimization=$(learn_optimization_strategies)

    jq -n \
        --argjson patterns "$success_patterns" \
        --argjson optimization "$optimization" \
        --arg generated "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            generated_at: $generated,
            success_patterns: $patterns,
            optimization_strategies: $optimization,
            recommendations: [
                "Focus on high-performing expert types",
                "Optimize token usage for efficiency",
                "Apply successful patterns to similar tasks"
            ]
        }' > "$output_file"

    log_info "Report saved to: $output_file"
    cat "$output_file"
}

# Apply learned patterns to new task
apply_meta_patterns() {
    local task_description="$1"
    local task_type="${2:-}"

    local latest_report=$(ls -t "$META_DIR"/meta-report-*.json 2>/dev/null | head -1)

    if [ -z "$latest_report" ]; then
        echo '{"applied": false, "reason": "No meta-learning data available"}'
        return
    fi

    # Get top patterns
    local top_pattern=$(jq '.success_patterns[0]' "$latest_report")
    local recommended_expert=$(echo "$top_pattern" | jq -r '.expert // "development"')

    # Get optimization recommendations
    local optimization=$(jq '.optimization_strategies[0]' "$latest_report")

    jq -n \
        --arg expert "$recommended_expert" \
        --argjson pattern "$top_pattern" \
        --argjson optimization "$optimization" \
        '{
            applied: true,
            recommended_expert: $expert,
            pattern_confidence: ($pattern.avg_score // 0),
            optimization_hints: $optimization
        }'
}

# Export functions
export -f extract_success_patterns
export -f learn_optimization_strategies
export -f generate_meta_report
export -f apply_meta_patterns

# CLI
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        extract)
            extract_success_patterns "${2:-30}" "${3:-80}"
            ;;
        optimize)
            learn_optimization_strategies
            ;;
        report)
            generate_meta_report
            ;;
        apply)
            apply_meta_patterns "$2" "${3:-}"
            ;;
        *)
            echo "Meta-Learning for Cross-Task Optimization"
            echo "Usage: meta-learning.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  extract [days] [min_score]  Extract success patterns"
            echo "  optimize                    Learn optimization strategies"
            echo "  report                      Generate meta-learning report"
            echo "  apply <description> [type]  Apply patterns to task"
            ;;
    esac
fi
