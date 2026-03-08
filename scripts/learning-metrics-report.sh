#!/bin/bash
# scripts/learning-metrics-report.sh
# Learning Metrics Reporting Tool
# Week 5: Q1 Implementation - Learning Agent
#
# Purpose: Query and report on learning performance metrics
# - Worker evaluation trends
# - Pattern extraction statistics
# - Model update history
# - Improvement tracking

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

cd "$COMMIT_RELAY_HOME"

LEARNING_METRICS_DIR="coordination/metrics/learning"
TRAINING_EXAMPLES_DIR="coordination/knowledge-base/training-examples"
PATTERNS_DIR="coordination/knowledge-base/learned-patterns"

#------------------------------------------------------------------------------
# show_summary()
# Display overall learning metrics summary
#------------------------------------------------------------------------------
show_summary() {
    echo "=== Learning Agent Performance Summary ==="
    echo ""

    # Count evaluations
    if [ -f "$LEARNING_METRICS_DIR/evaluations.jsonl" ]; then
        local total_evaluations=$(wc -l < "$LEARNING_METRICS_DIR/evaluations.jsonl" | tr -d ' ')
        local avg_score=$(cat "$LEARNING_METRICS_DIR/evaluations.jsonl" | jq -s 'map(.score) | add / length' 2>/dev/null || echo "0")
        local success_rate=$(cat "$LEARNING_METRICS_DIR/evaluations.jsonl" | jq -s '
            map(select(.outcome == "success_high_quality" or .outcome == "success_standard")) | length
        ' 2>/dev/null || echo "0")
        local success_percent=$(echo "scale=1; ($success_rate / $total_evaluations) * 100" | bc 2>/dev/null || echo "0")

        echo "Worker Evaluations:"
        echo "  Total: $total_evaluations"
        echo "  Average Score: ${avg_score%.*}/100"
        echo "  Success Rate: ${success_percent}%"
        echo ""
    else
        echo "Worker Evaluations: No data"
        echo ""
    fi

    # Count training examples
    if [ -f "$TRAINING_EXAMPLES_DIR/training-examples.jsonl" ]; then
        local total_examples=$(wc -l < "$TRAINING_EXAMPLES_DIR/training-examples.jsonl" | tr -d ' ')
        local positive_examples=$(wc -l < "$TRAINING_EXAMPLES_DIR/positive-examples.jsonl" 2>/dev/null | tr -d ' ' || echo "0")
        local negative_examples=$(wc -l < "$TRAINING_EXAMPLES_DIR/negative-examples.jsonl" 2>/dev/null | tr -d ' ' || echo "0")

        echo "Training Examples:"
        echo "  Total: $total_examples"
        echo "  Positive: $positive_examples"
        echo "  Negative: $negative_examples"
        echo ""
    else
        echo "Training Examples: No data"
        echo ""
    fi

    # Count learned patterns
    if [ -f "$PATTERNS_DIR/patterns-latest.json" ]; then
        local patterns=$(cat "$PATTERNS_DIR/patterns-latest.json")
        local successful_count=$(echo "$patterns" | jq -r '.summary.successful_count // 0')
        local failed_count=$(echo "$patterns" | jq -r '.summary.failed_count // 0')
        local routing_count=$(echo "$patterns" | jq -r '.summary.routing_count // 0')

        echo "Learned Patterns:"
        echo "  Successful: $successful_count"
        echo "  Failed: $failed_count"
        echo "  Routing: $routing_count"
        echo ""
    else
        echo "Learned Patterns: No data"
        echo ""
    fi

    # Show latest improvement
    local latest_improvement=$(ls -t "$LEARNING_METRICS_DIR"/improvement-*.json 2>/dev/null | head -1)
    if [ -n "$latest_improvement" ] && [ -f "$latest_improvement" ]; then
        local improvement=$(cat "$latest_improvement")
        local sufficient_data=$(echo "$improvement" | jq -r '.sufficient_data // false')

        if [ "$sufficient_data" = "true" ]; then
            local score_improvement=$(echo "$improvement" | jq -r '.score_improvement_percent')
            local success_improvement=$(echo "$improvement" | jq -r '.success_rate_improvement_percent')
            local timeframe=$(echo "$improvement" | jq -r '.timeframe')

            echo "Latest Improvement ($timeframe):"
            echo "  Score: ${score_improvement%.*}%"
            echo "  Success Rate: ${success_improvement%.*}%"
            echo ""
        else
            echo "Latest Improvement: Insufficient data"
            echo ""
        fi
    else
        echo "Latest Improvement: No data"
        echo ""
    fi
}

#------------------------------------------------------------------------------
# show_recent_evaluations()
# Display recent worker evaluations
#------------------------------------------------------------------------------
show_recent_evaluations() {
    local count="${1:-10}"

    echo "=== Recent Worker Evaluations (last $count) ==="
    echo ""

    if [ ! -f "$LEARNING_METRICS_DIR/evaluations.jsonl" ]; then
        echo "No evaluations found"
        return
    fi

    tail -n "$count" "$LEARNING_METRICS_DIR/evaluations.jsonl" | jq -r '
        "\(.timestamp) | Score: \(.score)/100 | \(.outcome)"
    '
}

#------------------------------------------------------------------------------
# show_improvement_trend()
# Display improvement trends over time
#------------------------------------------------------------------------------
show_improvement_trend() {
    echo "=== Improvement Trend ==="
    echo ""

    local improvement_files=$(ls -t "$LEARNING_METRICS_DIR"/improvement-*.json 2>/dev/null | head -7)

    if [ -z "$improvement_files" ]; then
        echo "No improvement data found"
        return
    fi

    echo "Date       | Score Δ | Success Δ | Timeframe"
    echo "-----------|---------|-----------|----------"

    for file in $improvement_files; do
        local date=$(basename "$file" .json | sed 's/improvement-//')
        local improvement=$(cat "$file")
        local sufficient_data=$(echo "$improvement" | jq -r '.sufficient_data // false')

        if [ "$sufficient_data" = "true" ]; then
            local score_delta=$(echo "$improvement" | jq -r '.score_improvement_percent')
            local success_delta=$(echo "$improvement" | jq -r '.success_rate_improvement_percent')
            local timeframe=$(echo "$improvement" | jq -r '.timeframe')

            printf "%s | %+6.1f%% | %+8.1f%% | %s\n" \
                "$date" "${score_delta}" "${success_delta}" "$timeframe"
        else
            printf "%s | %7s | %9s | insufficient data\n" "$date" "-" "-"
        fi
    done
}

#------------------------------------------------------------------------------
# show_pattern_details()
# Display details of learned patterns
#------------------------------------------------------------------------------
show_pattern_details() {
    echo "=== Learned Patterns Details ==="
    echo ""

    if [ ! -f "$PATTERNS_DIR/patterns-latest.json" ]; then
        echo "No patterns found"
        return
    fi

    local patterns=$(cat "$PATTERNS_DIR/patterns-latest.json")

    echo "Successful Patterns:"
    echo "$patterns" | jq -r '.successful_patterns[] |
        "  \(.task_type) + \(.strategy) → Worker: \(.worker_type) (Score: \(.avg_score)/100, Count: \(.count))"
    ' 2>/dev/null || echo "  None"

    echo ""
    echo "Failed Patterns (to avoid):"
    echo "$patterns" | jq -r '.failed_patterns[] |
        "  \(.task_type) + \(.strategy) → Worker: \(.worker_type) (Score: \(.avg_score)/100, Failures: \(.failure_rate * 100)%)"
    ' 2>/dev/null || echo "  None"

    echo ""
    echo "Routing Patterns:"
    echo "$patterns" | jq -r '.routing_patterns[] |
        "  \(.task_type) (complexity: \(.complexity)) → \(.preferred_worker_type) (Score: \(.avg_score)/100)"
    ' 2>/dev/null || echo "  None"
}

#------------------------------------------------------------------------------
# show_learner_activity()
# Display learner execution history
#------------------------------------------------------------------------------
show_learner_activity() {
    echo "=== Learner Activity Log ==="
    echo ""

    if [ ! -f "$LEARNING_METRICS_DIR/learner-metrics.jsonl" ]; then
        echo "No learner activity found"
        return
    fi

    tail -n 20 "$LEARNING_METRICS_DIR/learner-metrics.jsonl" | jq -r '
        "\(.timestamp) | \(.metric): \(.value)"
    '
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------
case "${1:-summary}" in
    summary)
        show_summary
        ;;
    evaluations)
        show_recent_evaluations "${2:-10}"
        ;;
    improvement)
        show_improvement_trend
        ;;
    patterns)
        show_pattern_details
        ;;
    activity)
        show_learner_activity
        ;;
    all)
        show_summary
        echo ""
        show_improvement_trend
        echo ""
        show_pattern_details
        echo ""
        show_recent_evaluations 5
        ;;
    *)
        echo "Usage: learning-metrics-report.sh {summary|evaluations|improvement|patterns|activity|all}"
        echo ""
        echo "Commands:"
        echo "  summary      - Overall learning metrics summary"
        echo "  evaluations  - Recent worker evaluations"
        echo "  improvement  - Improvement trend over time"
        echo "  patterns     - Learned patterns details"
        echo "  activity     - Learner execution activity"
        echo "  all          - Show all reports"
        exit 1
        ;;
esac
