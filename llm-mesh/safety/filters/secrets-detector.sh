#!/bin/bash
# Secrets Detector - Prevents credential leakage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFETY_HOME="$SCRIPT_DIR/.."
PERFORMANCE_LOG="$SAFETY_HOME/learning/filter-performance.jsonl"

# Secret patterns
declare -A SECRET_PATTERNS=(
    ["api_key"]='(api[_-]?key|apikey)["\s:=]+[a-zA-Z0-9_-]{20,}'
    ["bearer_token"]='Bearer\s+[a-zA-Z0-9_-]{20,}'
    ["aws_key"]='AKIA[0-9A-Z]{16}'
    ["github_token"]='gh[ps]_[a-zA-Z0-9]{36,}'
    ["private_key"]='-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----'
    ["password"]='(password|passwd|pwd)["\s:=]+[^\s]{8,}'
)

##############################################################################
# detect_secrets: Scan for secrets/credentials
##############################################################################
detect_secrets() {
    local text="$1"
    local action="${2:-detect}"  # detect|redact|block|alert
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    local detections=()
    local secrets_found=false
    local redacted_text="$text"
    local severity="none"

    # Scan for each secret type
    for secret_type in "${!SECRET_PATTERNS[@]}"; do
        local pattern="${SECRET_PATTERNS[$secret_type]}"

        if echo "$text" | grep -qiE "$pattern"; then
            secrets_found=true
            detections+=("$secret_type")
            severity="critical"

            if [ "$action" = "redact" ]; then
                redacted_text=$(echo "$redacted_text" | sed -E "s/$pattern/[SECRET_${secret_type^^}_REDACTED]/gi")
            fi
        fi
    done

    local detections_json=$(printf '%s\n' "${detections[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

    local result=$(jq -n \
        --arg timestamp "$timestamp" \
        --argjson safe "$([ "$secrets_found" = false ] && echo true || echo false)" \
        --argjson detections "$detections_json" \
        --arg severity "$severity" \
        --arg redacted "$redacted_text" \
        --arg recommendation "$([ "$secrets_found" = true ] && echo "block_and_alert" || echo "allow")" \
        '{
            timestamp: $timestamp,
            filter: "secrets-detector",
            safe: $safe,
            secrets_detected: (if $safe then false else true end),
            secret_types: $detections,
            severity: $severity,
            redacted_text: $redacted,
            recommendation: $recommendation,
            action: "'"$action"'"
        }')

    # Log performance
    track_performance "secrets-detector" "$secrets_found"

    # Alert if secrets found
    if [ "$secrets_found" = true ]; then
        echo "[SECURITY ALERT] Secrets detected in content!" >&2
    fi

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
            secrets_detected: $detected,
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
        echo "  action: detect (default) | redact | block | alert"
        exit 1
    fi

    detect_secrets "$@"
fi
