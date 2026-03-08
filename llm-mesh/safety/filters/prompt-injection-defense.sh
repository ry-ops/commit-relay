#!/bin/bash
# Prompt Injection Defense - Prevents malicious prompt manipulation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFETY_HOME="$SCRIPT_DIR/.."
PERFORMANCE_LOG="$SAFETY_HOME/learning/filter-performance.jsonl"

# Injection attack patterns
declare -A INJECTION_PATTERNS=(
    ["system_override"]='(ignore|forget|disregard).*(previous|above|system|instructions)'
    ["jailbreak"]='(DAN|developer mode|jailbreak|unrestricted)'
    ["role_confusion"]='(you are now|act as|pretend to be|roleplay)'
    ["delimiter_injection"]='(```|---|===|\[SYSTEM\]|\[INST\])'
    ["instruction_bypass"]='(but actually|however really|instead do)'
)

##############################################################################
# detect_injection: Scan for prompt injection attempts
##############################################################################
detect_injection() {
    local text="$1"
    local action="${2:-detect}"  # detect|block|sanitize
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    local text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    local detections=()
    local attack_detected=false
    local risk_score=0

    # Scan for each attack type
    for attack_type in "${!INJECTION_PATTERNS[@]}"; do
        local pattern="${INJECTION_PATTERNS[$attack_type]}"

        if echo "$text_lower" | grep -qiE "$pattern"; then
            attack_detected=true
            detections+=("$attack_type")
            risk_score=$((risk_score + 20))
        fi
    done

    # Cap risk score at 100
    [ $risk_score -gt 100 ] && risk_score=100

    local detections_json=$(printf '%s\n' "${detections[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

    local result=$(jq -n \
        --arg timestamp "$timestamp" \
        --argjson safe "$([ "$attack_detected" = false ] && echo true || echo false)" \
        --argjson detections "$detections_json" \
        --argjson risk "$((risk_score))" \
        --arg recommendation "$([ "$attack_detected" = true ] && echo "block" || echo "allow")" \
        '{
            timestamp: $timestamp,
            filter: "prompt-injection-defense",
            safe: $safe,
            attack_detected: (if $safe then false else true end),
            attack_types: $detections,
            risk_score: ($risk / 100),
            recommendation: $recommendation,
            action: "'"$action"'"
        }')

    # Log performance
    track_performance "prompt-injection-defense" "$attack_detected"

    echo "$result"
}

##############################################################################
# track_performance: Track filter performance
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
            attack_detected: $detected,
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
        echo "  action: detect (default) | block | sanitize"
        exit 1
    fi

    detect_injection "$@"
fi
