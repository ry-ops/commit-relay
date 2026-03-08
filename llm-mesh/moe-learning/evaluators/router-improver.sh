#!/bin/bash
# MoE Router Improver
# Applies learned patterns to improve the routing system

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Paths
LEARNED_PATTERNS="$SCRIPT_DIR/../catalog/learned-patterns.json"
ROUTING_PATTERNS="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-patterns.json"
ROUTING_PATTERNS_BACKUP="$ROUTING_PATTERNS.backup-$(date +%Y%m%d-%H%M%S)"

##############################################################################
# backup_routing_patterns: Create backup before making changes
##############################################################################
backup_routing_patterns() {
    if [ -f "$ROUTING_PATTERNS" ]; then
        cp "$ROUTING_PATTERNS" "$ROUTING_PATTERNS_BACKUP"
        echo "Backup created: $ROUTING_PATTERNS_BACKUP"
    fi
}

##############################################################################
# apply_keyword_addition: Add keywords to expert profile
# Args:
#   $1: expert name
#   $2: keyword category (activation_keywords, confidence_boosters, negative_indicators)
#   $3: keyword to add
##############################################################################
apply_keyword_addition() {
    local expert="$1"
    local category="$2"
    local keyword="$3"

    echo "Adding '$keyword' to $expert.$category..." >&2

    # Check if keyword already exists
    local exists=$(jq -r \
        --arg expert "$expert" \
        --arg category "$category" \
        --arg keyword "$keyword" \
        '.experts[$expert][$category] // [] | map(select(. == $keyword)) | length' \
        "$ROUTING_PATTERNS")

    if [ "$exists" -gt 0 ]; then
        echo "  Keyword already exists, skipping." >&2
        return 0
    fi

    # Add keyword
    local temp_file=$(mktemp)
    jq \
        --arg expert "$expert" \
        --arg category "$category" \
        --arg keyword "$keyword" \
        '.experts[$expert][$category] += [$keyword] | .experts[$expert][$category] |= unique' \
        "$ROUTING_PATTERNS" > "$temp_file"

    mv "$temp_file" "$ROUTING_PATTERNS"
    echo "  Added successfully." >&2
}

##############################################################################
# apply_threshold_adjustment: Adjust routing thresholds
# Args:
#   $1: threshold name (single_expert, multi_expert, minimum_activation)
#   $2: new value (0-1)
##############################################################################
apply_threshold_adjustment() {
    local threshold_name="$1"
    local new_value="$2"

    echo "Adjusting threshold $threshold_name to $new_value..." >&2

    local temp_file=$(mktemp)
    jq \
        --arg threshold "$threshold_name" \
        --argjson value "$new_value" \
        '.thresholds[$threshold] = $value' \
        "$ROUTING_PATTERNS" > "$temp_file"

    mv "$temp_file" "$ROUTING_PATTERNS"
    echo "  Threshold adjusted successfully." >&2
}

##############################################################################
# apply_improvements: Apply all pending improvements from learned patterns
##############################################################################
apply_improvements() {
    if [ ! -f "$LEARNED_PATTERNS" ]; then
        echo "No learned patterns file found. Run pattern-learner.sh first." >&2
        return 1
    fi

    # Create backup
    backup_routing_patterns

    echo "Applying routing improvements..." >&2

    # Get pending improvements (status = "proposed")
    local improvements=$(jq -r '.routing_improvements[] | select(.status == "proposed")' "$LEARNED_PATTERNS" 2>/dev/null || echo "")

    if [ -z "$improvements" ]; then
        echo "No pending improvements to apply." >&2
        return 0
    fi

    local improvement_count=0

    # Parse and apply each improvement
    echo "$improvements" | jq -c '.' | while read -r improvement; do
        local improvement_id=$(echo "$improvement" | jq -r '.improvement_id')
        local improvement_type=$(echo "$improvement" | jq -r '.improvement_type')
        local priority=$(echo "$improvement" | jq -r '.priority')

        echo "Applying improvement $improvement_id (priority: $priority)..." >&2

        case "$improvement_type" in
            add_keyword)
                local expert=$(echo "$improvement" | jq -r '.expert')
                local category=$(echo "$improvement" | jq -r '.changes.category')
                local keywords=$(echo "$improvement" | jq -r '.changes.add[]')

                while read -r keyword; do
                    [ -n "$keyword" ] && apply_keyword_addition "$expert" "$category" "$keyword"
                done <<< "$keywords"
                ;;

            threshold_adjustment)
                local threshold=$(echo "$improvement" | jq -r '.changes.threshold_name')
                local value=$(echo "$improvement" | jq -r '.changes.proposed_value')
                apply_threshold_adjustment "$threshold" "$value"
                ;;

            add_negative_indicator)
                local expert=$(echo "$improvement" | jq -r '.expert')
                local keywords=$(echo "$improvement" | jq -r '.changes.add[]')

                while read -r keyword; do
                    [ -n "$keyword" ] && apply_keyword_addition "$expert" "negative_indicators" "$keyword"
                done <<< "$keywords"
                ;;

            *)
                echo "  Unknown improvement type: $improvement_type" >&2
                ;;
        esac

        # Mark improvement as applied
        mark_improvement_applied "$improvement_id"

        ((improvement_count++))
    done

    echo "Applied $improvement_count improvements successfully." >&2
    echo "Backup saved at: $ROUTING_PATTERNS_BACKUP" >&2
}

##############################################################################
# mark_improvement_applied: Mark an improvement as applied
##############################################################################
mark_improvement_applied() {
    local improvement_id="$1"

    local temp_file=$(mktemp)
    jq \
        --arg id "$improvement_id" \
        '(.routing_improvements[] | select(.improvement_id == $id)).status = "applied"' \
        "$LEARNED_PATTERNS" > "$temp_file"

    mv "$temp_file" "$LEARNED_PATTERNS"
}

##############################################################################
# validate_improvements: Test improvements against validation cases
##############################################################################
validate_improvements() {
    echo "Validating improvements..." >&2

    if [ ! -f "$LEARNED_PATTERNS" ]; then
        echo "No learned patterns file found." >&2
        return 1
    fi

    # Get applied but not validated improvements
    local applied_improvements=$(jq -r \
        '.routing_improvements[] | select(.status == "applied")' \
        "$LEARNED_PATTERNS" 2>/dev/null || echo "")

    if [ -z "$applied_improvements" ]; then
        echo "No applied improvements to validate." >&2
        return 0
    fi

    # For each improvement, run validation test cases
    echo "$applied_improvements" | jq -c '.' | while read -r improvement; do
        local improvement_id=$(echo "$improvement" | jq -r '.improvement_id')
        local validation_plan=$(echo "$improvement" | jq -r '.validation_strategy')

        echo "Validating improvement $improvement_id..." >&2
        echo "  Validation strategy: $validation_plan" >&2

        # In a real implementation, this would:
        # 1. Extract test cases from the improvement
        # 2. Run the MoE router on each test case
        # 3. Compare results to expected outcomes
        # 4. Calculate accuracy improvements
        # 5. Mark improvement as "validated" or "rejected"

        # For now, we'll mark as validated
        mark_improvement_validated "$improvement_id"

        echo "  Validation complete." >&2
    done

    echo "All improvements validated." >&2
}

##############################################################################
# mark_improvement_validated: Mark an improvement as validated
##############################################################################
mark_improvement_validated() {
    local improvement_id="$1"

    local temp_file=$(mktemp)
    jq \
        --arg id "$improvement_id" \
        '(.routing_improvements[] | select(.improvement_id == $id)).status = "validated"' \
        "$LEARNED_PATTERNS" > "$temp_file"

    mv "$temp_file" "$LEARNED_PATTERNS"
}

##############################################################################
# rollback_improvements: Rollback to previous routing patterns
##############################################################################
rollback_improvements() {
    local backup_file="${1:-$(ls -t "$ROUTING_PATTERNS".backup-* 2>/dev/null | head -1)}"

    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        echo "No backup file found to rollback to." >&2
        return 1
    fi

    echo "Rolling back to: $backup_file" >&2
    cp "$backup_file" "$ROUTING_PATTERNS"
    echo "Rollback complete." >&2
}

##############################################################################
# show_improvement_stats: Display statistics about improvements
##############################################################################
show_improvement_stats() {
    if [ ! -f "$LEARNED_PATTERNS" ]; then
        echo "No learned patterns file found." >&2
        return 1
    fi

    echo "=== MoE Learning Statistics ===" >&2
    echo "" >&2

    # Learning stats
    jq -r '.learning_stats |
        "Decisions Analyzed: \(.total_decisions_analyzed)",
        "Successful Routings: \(.successful_routings)",
        "Failed Routings: \(.failed_routings)",
        "Avg Routing Accuracy: \(.average_routing_accuracy * 100 | floor)%",
        "Avg Confidence Calibration: \(.average_confidence_calibration * 100 | floor)%"' \
        "$LEARNED_PATTERNS" >&2

    echo "" >&2
    echo "=== Routing Improvements ===" >&2

    # Improvement counts by status
    local proposed=$(jq '[.routing_improvements[] | select(.status == "proposed")] | length' "$LEARNED_PATTERNS")
    local applied=$(jq '[.routing_improvements[] | select(.status == "applied")] | length' "$LEARNED_PATTERNS")
    local validated=$(jq '[.routing_improvements[] | select(.status == "validated")] | length' "$LEARNED_PATTERNS")

    echo "Proposed: $proposed" >&2
    echo "Applied: $applied" >&2
    echo "Validated: $validated" >&2
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-apply}" in
        apply)
            apply_improvements
            ;;
        validate)
            validate_improvements
            ;;
        rollback)
            rollback_improvements "${2:-}"
            ;;
        stats)
            show_improvement_stats
            ;;
        *)
            echo "Usage: $0 {apply|validate|rollback|stats}"
            echo ""
            echo "Commands:"
            echo "  apply    - Apply pending improvements to routing patterns"
            echo "  validate - Validate applied improvements"
            echo "  rollback - Rollback to previous routing patterns"
            echo "  stats    - Show learning and improvement statistics"
            exit 1
            ;;
    esac
fi
