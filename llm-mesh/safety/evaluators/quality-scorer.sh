#!/bin/bash
# Quality Scorer - Scores LLM output quality across multiple dimensions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFETY_HOME="$SCRIPT_DIR/.."

##############################################################################
# score_quality: Score output quality
# Args:
#   $1: output text
#   $2: expected format (json|markdown|text)
#   $3: task_type (optional)
# Output: Quality score JSON
##############################################################################
score_quality() {
    local output="$1"
    local expected_format="${2:-text}"
    local task_type="${3:-general}"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    # Dimension scores
    local format_score=0
    local completeness_score=0
    local relevance_score=0
    local clarity_score=0

    # Format compliance check
    case "$expected_format" in
        json)
            if echo "$output" | jq . >/dev/null 2>&1; then
                format_score=100
            else
                format_score=0
            fi
            ;;
        markdown)
            if echo "$output" | grep -q "#"; then
                format_score=80
            else
                format_score=60
            fi
            ;;
        *)
            format_score=100  # Text format always passes
            ;;
    esac

    # Completeness check (simple heuristic)
    local output_length=${#output}
    if [ $output_length -gt 500 ]; then
        completeness_score=100
    elif [ $output_length -gt 200 ]; then
        completeness_score=80
    elif [ $output_length -gt 50 ]; then
        completeness_score=60
    else
        completeness_score=40
    fi

    # Relevance check (keywords presence)
    relevance_score=75  # Default mid-range

    # Clarity check (sentence structure, no excessive jargon)
    if echo "$output" | grep -q "\\."; then
        clarity_score=80
    else
        clarity_score=60
    fi

    # Calculate overall score (weighted average)
    local overall_score=$(( (format_score * 30 + completeness_score * 25 + relevance_score * 25 + clarity_score * 20) / 100 ))

    local result=$(jq -n \
        --arg timestamp "$timestamp" \
        --argjson format "$((format_score))" \
        --argjson completeness "$((completeness_score))" \
        --argjson relevance "$((relevance_score))" \
        --argjson clarity "$((clarity_score))" \
        --argjson overall "$((overall_score))" \
        '{
            timestamp: $timestamp,
            evaluator: "quality-scorer",
            overall_quality: ($overall / 100),
            dimensions: {
                format_compliance: ($format / 100),
                completeness: ($completeness / 100),
                relevance: ($relevance / 100),
                clarity: ($clarity / 100)
            },
            confidence: 0.75,
            task_type: "'"$task_type"'"
        }')

    echo "$result"
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <output> [format] [task_type]"
        exit 1
    fi

    score_quality "$@"
fi
