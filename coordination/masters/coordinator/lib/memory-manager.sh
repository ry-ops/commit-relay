#!/bin/bash
# Memory Manager - Learning from MoE Routing Decisions
# Analyzes routing decisions and updates long-term memory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MEMORY_DIR="$PROJECT_ROOT/coordination/memory"
ROUTING_LOG="$PROJECT_ROOT/coordination/masters/coordinator/logs/routing-decisions.jsonl"

# Memory files
TASK_PATTERNS="$MEMORY_DIR/long-term/task-patterns.json"
SUCCESS_METRICS="$MEMORY_DIR/long-term/success-metrics.json"
LEARNED_PREFERENCES="$MEMORY_DIR/long-term/learned-preferences.json"

##############################################################################
# analyze_routing_decision: Learn from a single routing decision
##############################################################################
analyze_routing_decision() {
    local task_id="$1"
    local task_description="$2"
    local routing_decision="$3"

    # Extract routing info
    local primary_expert=$(echo "$routing_decision" | jq -r '.decision.primary_expert')
    local confidence=$(echo "$routing_decision" | jq -r '.decision.primary_confidence')
    local strategy=$(echo "$routing_decision" | jq -r '.decision.strategy')

    # Extract keywords from task description
    local keywords=$(echo "$task_description" | tr '[:upper:]' '[:lower:]' | grep -oE '\b\w{4,}\b' | sort -u)

    # Update task patterns
    update_task_patterns "$primary_expert" "$keywords" "$confidence"

    # Update routing accuracy metrics
    update_routing_metrics "$primary_expert" "$confidence" "$strategy"
}

##############################################################################
# update_task_patterns: Add learned keywords and patterns
##############################################################################
update_task_patterns() {
    local expert="$1"
    local keywords="$2"
    local confidence="$3"

    if [ ! -f "$TASK_PATTERNS" ]; then
        return 0
    fi

    # Extract current keywords for this expert
    local current_keywords=$(jq -r ".patterns.by_expert.${expert}.common_keywords[]" "$TASK_PATTERNS" 2>/dev/null || echo "")

    # Add new keywords that appear with high confidence
    if (( $(echo "$confidence > 0.7" | bc -l) )); then
        local new_keywords_learned=0
        for keyword in $keywords; do
            # Check if keyword is already known
            if ! echo "$current_keywords" | grep -q "^${keyword}$"; then
                # Add keyword to learned patterns
                jq ".patterns.by_expert.${expert}.common_keywords += [\"$keyword\"]" "$TASK_PATTERNS" > "$TASK_PATTERNS.tmp"
                mv "$TASK_PATTERNS.tmp" "$TASK_PATTERNS"
                new_keywords_learned=$((new_keywords_learned + 1))
            fi
        done

        # Emit learning event if new keywords were learned
        if [ $new_keywords_learned -gt 0 ]; then
            local event_script="$MEMORY_DIR/../../../scripts/emit-event.sh"
            if [ -f "$event_script" ]; then
                local event_data=$(jq -nc \
                    --arg expert "$expert" \
                    --argjson count "$new_keywords_learned" \
                    --arg conf "$confidence" \
                    '{expert: $expert, new_keywords: $count, confidence: ($conf | tonumber)}')
                "$event_script" "moe_pattern_learned" "$event_data" "memory-manager" 2>/dev/null || true
            fi
        fi
    fi

    # Update task count
    jq ".patterns.by_expert.${expert}.total_tasks += 1" "$TASK_PATTERNS" > "$TASK_PATTERNS.tmp"
    mv "$TASK_PATTERNS.tmp" "$TASK_PATTERNS"

    # Update timestamp
    jq ".last_updated = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" "$TASK_PATTERNS" > "$TASK_PATTERNS.tmp"
    mv "$TASK_PATTERNS.tmp" "$TASK_PATTERNS"
}

##############################################################################
# update_routing_metrics: Track routing accuracy and decisions
##############################################################################
update_routing_metrics() {
    local expert="$1"
    local confidence="$2"
    local strategy="$3"

    if [ ! -f "$TASK_PATTERNS" ]; then
        return 0
    fi

    # Increment total routes
    jq '.patterns.routing_accuracy.total_routes += 1' "$TASK_PATTERNS" > "$TASK_PATTERNS.tmp"
    mv "$TASK_PATTERNS.tmp" "$TASK_PATTERNS"

    # Update accuracy percentage
    local total=$(jq -r '.patterns.routing_accuracy.total_routes' "$TASK_PATTERNS")
    local correct=$(jq -r '.patterns.routing_accuracy.correct_routes' "$TASK_PATTERNS")

    if [ "$total" -gt 0 ]; then
        local accuracy=$(echo "scale=2; $correct * 100 / $total" | bc)
        jq ".patterns.routing_accuracy.accuracy_percentage = $accuracy" "$TASK_PATTERNS" > "$TASK_PATTERNS.tmp"
        mv "$TASK_PATTERNS.tmp" "$TASK_PATTERNS"
    fi
}

##############################################################################
# update_success_metrics: Record task completion metrics
##############################################################################
update_success_metrics() {
    local task_id="$1"
    local expert="$2"
    local success="$3"  # true/false
    local completion_time="$4"  # in minutes

    if [ ! -f "$SUCCESS_METRICS" ]; then
        return 0
    fi

    # Update overall metrics
    jq '.overall_metrics.total_tasks_processed += 1' "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
    mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"

    if [ "$success" == "true" ]; then
        jq '.overall_metrics.successful_completions += 1' "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
        mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"
    else
        jq '.overall_metrics.failures += 1' "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
        mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"
    fi

    # Update expert-specific metrics
    jq ".expert_performance.${expert}.tasks_completed += 1" "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
    mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"

    # Update average completion time
    local current_avg=$(jq -r ".expert_performance.${expert}.average_time_minutes" "$SUCCESS_METRICS")
    local task_count=$(jq -r ".expert_performance.${expert}.tasks_completed" "$SUCCESS_METRICS")
    local new_avg=$(echo "scale=2; ($current_avg * ($task_count - 1) + $completion_time) / $task_count" | bc)

    jq ".expert_performance.${expert}.average_time_minutes = $new_avg" "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
    mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"

    # Calculate success rate
    local total=$(jq -r '.overall_metrics.total_tasks_processed' "$SUCCESS_METRICS")
    local successful=$(jq -r '.overall_metrics.successful_completions' "$SUCCESS_METRICS")

    if [ "$total" -gt 0 ]; then
        local success_rate=$(echo "scale=2; $successful * 100 / $total" | bc)
        jq ".overall_metrics.success_rate = $success_rate" "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
        mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"
    fi

    # Update timestamp
    jq ".last_updated = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" "$SUCCESS_METRICS" > "$SUCCESS_METRICS.tmp"
    mv "$SUCCESS_METRICS.tmp" "$SUCCESS_METRICS"
}

##############################################################################
# suggest_threshold_adjustment: Analyze patterns and suggest improvements
##############################################################################
suggest_threshold_adjustment() {
    if [ ! -f "$TASK_PATTERNS" ] || [ ! -f "$SUCCESS_METRICS" ]; then
        echo "Insufficient data for suggestions"
        return 0
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🧠 Learning Insights & Recommendations"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Get routing accuracy
    local accuracy=$(jq -r '.patterns.routing_accuracy.accuracy_percentage' "$TASK_PATTERNS")
    local total_routes=$(jq -r '.patterns.routing_accuracy.total_routes' "$TASK_PATTERNS")

    echo "📊 Routing Performance:"
    echo "   Total routing decisions: $total_routes"
    echo "   Routing accuracy: ${accuracy}%"
    echo ""

    # Analyze expert utilization
    echo "👥 Expert Utilization:"
    for expert in development security inventory; do
        local task_count=$(jq -r ".patterns.by_expert.${expert}.total_tasks" "$TASK_PATTERNS")
        local success_rate=$(jq -r ".expert_performance.${expert}.success_rate" "$SUCCESS_METRICS" 2>/dev/null || echo "0")
        local avg_time=$(jq -r ".expert_performance.${expert}.average_time_minutes" "$SUCCESS_METRICS" 2>/dev/null || echo "0")

        echo "   ${expert}: ${task_count} tasks, ${success_rate}% success, avg ${avg_time} min"
    done
    echo ""

    # Suggestions
    echo "💡 Suggestions:"

    # If accuracy is low, suggest threshold adjustment
    if (( $(echo "$accuracy < 70" | bc -l) )) && [ "$total_routes" -gt 10 ]; then
        echo "   ⚠ Low routing accuracy detected"
        echo "   → Consider adjusting confidence thresholds"
        echo "   → Review keyword matching patterns"
    fi

    # Check for imbalanced expert usage
    local dev_tasks=$(jq -r '.patterns.by_expert.development.total_tasks' "$TASK_PATTERNS")
    local sec_tasks=$(jq -r '.patterns.by_expert.security.total_tasks' "$TASK_PATTERNS")
    local inv_tasks=$(jq -r '.patterns.by_expert.inventory.total_tasks' "$TASK_PATTERNS")
    local total_tasks=$((dev_tasks + sec_tasks + inv_tasks))

    if [ "$total_tasks" -gt 0 ]; then
        for expert in development security inventory; do
            local expert_tasks=$(jq -r ".patterns.by_expert.${expert}.total_tasks" "$TASK_PATTERNS")
            local percentage=$(echo "scale=0; $expert_tasks * 100 / $total_tasks" | bc)

            if [ "$percentage" -gt 60 ]; then
                echo "   ⚠ ${expert} expert handling ${percentage}% of tasks"
                echo "   → Consider reviewing routing patterns for balance"
            fi
        done
    fi

    echo ""
}

##############################################################################
# generate_learning_report: Comprehensive learning analysis
##############################################################################
generate_learning_report() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         MoE Memory & Learning System Report              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Check memory files exist
    if [ ! -f "$TASK_PATTERNS" ]; then
        echo "⚠ No task patterns data available yet"
        return 0
    fi

    # Display learned patterns
    echo "📚 Learned Task Patterns:"
    echo ""

    for expert in development security inventory; do
        local expert_upper=$(echo "$expert" | tr '[:lower:]' '[:upper:]')
        echo "  🎯 ${expert_upper}:"
        local keywords=$(jq -r ".patterns.by_expert.${expert}.common_keywords[]" "$TASK_PATTERNS" 2>/dev/null | head -10)
        if [ -n "$keywords" ]; then
            echo "     Learned keywords: $(echo $keywords | tr '\n' ', ' | sed 's/,$//')"
        else
            echo "     Learned keywords: (none yet)"
        fi

        local total_tasks=$(jq -r ".patterns.by_expert.${expert}.total_tasks" "$TASK_PATTERNS")
        echo "     Total tasks routed: $total_tasks"
        echo ""
    done

    # Routing insights
    suggest_threshold_adjustment
}

##############################################################################
# Main execution
##############################################################################
case "${1:-}" in
    analyze)
        if [ $# -lt 3 ]; then
            echo "Usage: $0 analyze <task_id> <task_description> <routing_decision_json>"
            exit 1
        fi
        analyze_routing_decision "$2" "$3" "$4"
        ;;

    update-success)
        if [ $# -lt 4 ]; then
            echo "Usage: $0 update-success <task_id> <expert> <success> <completion_time_minutes>"
            exit 1
        fi
        update_success_metrics "$2" "$3" "$4" "$5"
        ;;

    report)
        generate_learning_report
        ;;

    suggest)
        suggest_threshold_adjustment
        ;;

    *)
        echo "Memory Manager - MoE Learning System"
        echo ""
        echo "Usage:"
        echo "  $0 analyze <task_id> <description> <routing_json>  - Learn from routing decision"
        echo "  $0 update-success <task_id> <expert> <true|false> <minutes> - Record task completion"
        echo "  $0 report                                          - Generate learning report"
        echo "  $0 suggest                                         - Get improvement suggestions"
        exit 1
        ;;
esac
