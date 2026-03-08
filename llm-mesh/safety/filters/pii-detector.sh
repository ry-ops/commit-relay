#!/bin/bash
# PII Detector - Detects and redacts personally identifiable information

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFETY_HOME="$SCRIPT_DIR/.."
PATTERNS_FILE="$SAFETY_HOME/learning/pii-patterns.json"
PERFORMANCE_LOG="$SAFETY_HOME/learning/filter-performance.jsonl"

# PII Patterns (regex-based)
declare -A PII_PATTERNS=(
    ["email"]='[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
    ["phone"]='(\+?1[-.]?)?\(?([0-9]{3})\)?[-.]?([0-9]{3})[-.]?([0-9]{4})'
    ["ssn"]='[0-9]{3}-[0-9]{2}-[0-9]{4}'
    ["credit_card"]='[0-9]{4}[-\s]?[0-9]{4}[-\s]?[0-9]{4}[-\s]?[0-9]{4}'
    ["ip_address"]='([0-9]{1,3}\.){3}[0-9]{1,3}'
)

##############################################################################
# detect_pii: Scan text for PII
# Args:
#   $1: text to scan
#   $2: action (detect|redact|alert)
# Output: JSON with detected PII
##############################################################################
detect_pii() {
    local text="$1"
    local action="${2:-detect}"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    local detections=()
    local redacted_text="$text"
    local pii_found=false

    # Scan for each PII type
    for pii_type in "${!PII_PATTERNS[@]}"; do
        local pattern="${PII_PATTERNS[$pii_type]}"

        if echo "$text" | grep -qE "$pattern"; then
            pii_found=true
            detections+=("$pii_type")

            if [ "$action" = "redact" ]; then
                redacted_text=$(echo "$redacted_text" | sed -E "s/$pattern/[PII_${pii_type^^}_REDACTED]/g")
            fi
        fi
    done

    # Build result
    local detections_json=$(printf '%s\n' "${detections[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

    local result=$(jq -n \
        --arg timestamp "$timestamp" \
        --argjson safe "$([ "$pii_found" = false ] && echo true || echo false)" \
        --argjson detections "$detections_json" \
        --arg original_length "${#text}" \
        --arg redacted_length "${#redacted_text}" \
        --arg redacted "$redacted_text" \
        '{
            timestamp: $timestamp,
            filter: "pii-detector",
            safe: $safe,
            pii_detected: (if $safe then false else true end),
            types_detected: $detections,
            original_length: ($original_length | tonumber),
            redacted_length: ($redacted_length | tonumber),
            redacted_text: $redacted,
            action: "'"$action"'"
        }')

    # Log performance
    track_performance "pii-detector" "$pii_found"

    echo "$result"
}

##############################################################################
# track_performance: Track filter performance for learning
##############################################################################
track_performance() {
    local filter="$1"
    local detected="$2"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    mkdir -p "$(dirname "$PERFORMANCE_LOG")"

    local perf_record=$(jq -n \
        --arg ts "$timestamp" \
        --arg filter "$filter" \
        --argjson detected "$([ "$detected" = true ] && echo true || echo false)" \
        '{
            timestamp: $ts,
            filter: $filter,
            detected: $detected,
            check_performed: true
        }')

    echo "$perf_record" >> "$PERFORMANCE_LOG"
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <text> [action]"
        echo "  action: detect (default) | redact | alert"
        exit 1
    fi

    detect_pii "$@"
fi
