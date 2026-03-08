#!/bin/bash
# Safety Gateway - Main entry point for all safety checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTERS_DIR="$SCRIPT_DIR/filters"
EVALUATORS_DIR="$SCRIPT_DIR/evaluators"

##############################################################################
# check_input: Run all safety filters on input
##############################################################################
check_input() {
    local text="$1"
    local action="${2:-detect}"

    echo "{\"stage\": \"input_check\", \"checks\": [" >&2

    # PII Detection
    local pii_result=$(bash "$FILTERS_DIR/pii-detector.sh" "$text" "$action")
    local pii_safe=$(echo "$pii_result" | jq -r '.safe')
    echo "  PII: $([ "$pii_safe" = true ] && echo "✓" || echo "✗")" >&2

    # Prompt Injection Defense
    local injection_result=$(bash "$FILTERS_DIR/prompt-injection-defense.sh" "$text" "$action")
    local injection_safe=$(echo "$injection_result" | jq -r '.safe')
    echo "  Injection: $([ "$injection_safe" = true ] && echo "✓" || echo "✗")" >&2

    # Secrets Detection
    local secrets_result=$(bash "$FILTERS_DIR/secrets-detector.sh" "$text" "$action")
    local secrets_safe=$(echo "$secrets_result" | jq -r '.safe')
    echo "  Secrets: $([ "$secrets_safe" = true ] && echo "✓" || echo "✗")" >&2

    echo "]}" >&2

    # Combine results
    local all_safe="true"
    [ "$pii_safe" = false ] && all_safe="false"
    [ "$injection_safe" = false ] && all_safe="false"
    [ "$secrets_safe" = false ] && all_safe="false"

    # Get redacted text if available
    local final_text="$text"
    if [ "$action" = "redact" ]; then
        final_text=$(echo "$pii_result" | jq -r '.redacted_text')
        final_text=$(echo "$secrets_result" | jq -r '.redacted_text')
    fi

    local result=$(jq -n \
        --argjson safe "$all_safe" \
        --argjson pii "$pii_result" \
        --argjson injection "$injection_result" \
        --argjson secrets "$secrets_result" \
        --arg text "$final_text" \
        '{
            safe: $safe,
            processed_text: $text,
            checks: {
                pii: $pii,
                prompt_injection: $injection,
                secrets: $secrets
            },
            recommendation: (if $safe then "allow" else "block" end)
        }')

    echo "$result"
}

##############################################################################
# check_output: Run quality evaluations on output
##############################################################################
check_output() {
    local text="$1"
    local expected_format="${2:-text}"
    local task_type="${3:-general}"

    echo "{\"stage\": \"output_check\", \"evaluations\": [" >&2

    # PII Detection (on output too)
    local pii_result=$(bash "$FILTERS_DIR/pii-detector.sh" "$text" "detect")
    local pii_safe=$(echo "$pii_result" | jq -r '.safe')
    echo "  PII: $([ "$pii_safe" = true ] && echo "✓" || echo "✗")" >&2

    # Secrets Detection (on output)
    local secrets_result=$(bash "$FILTERS_DIR/secrets-detector.sh" "$text" "detect")
    local secrets_safe=$(echo "$secrets_result" | jq -r '.safe')
    echo "  Secrets: $([ "$secrets_safe" = true ] && echo "✓" || echo "✗")" >&2

    # Quality Scoring
    local quality_result=$(bash "$EVALUATORS_DIR/quality-scorer.sh" "$text" "$expected_format" "$task_type")
    local quality_score=$(echo "$quality_result" | jq -r '.overall_quality')
    echo "  Quality: $quality_score" >&2

    echo "]}" >&2

    # Combine results
    local all_safe="true"
    [ "$pii_safe" = false ] && all_safe="false"
    [ "$secrets_safe" = false ] && all_safe="false"

    local meets_quality=$(echo "$quality_score >= 0.7" | bc -l)

    local result=$(jq -n \
        --argjson safe "$all_safe" \
        --argjson quality_ok "$meets_quality" \
        --argjson pii "$pii_result" \
        --argjson secrets "$secrets_result" \
        --argjson quality "$quality_result" \
        '{
            safe: $safe,
            quality_acceptable: ($quality_ok == 1),
            evaluations: {
                pii: $pii,
                secrets: $secrets,
                quality: $quality
            },
            recommendation: (if ($safe and ($quality_ok == 1)) then "accept" else "reject" end)
        }')

    echo "$result"
}

##############################################################################
# full_check: Complete safety check (input + output)
##############################################################################
full_check() {
    local input="$1"
    local output="$2"
    local expected_format="${3:-text}"

    local input_check=$(check_input "$input" "detect")
    local output_check=$(check_output "$output" "$expected_format")

    local input_safe=$(echo "$input_check" | jq -r '.safe')
    local output_safe=$(echo "$output_check" | jq -r '.safe')
    local quality_ok=$(echo "$output_check" | jq -r '.quality_acceptable')

    local overall_safe="true"
    [ "$input_safe" = false ] && overall_safe="false"
    [ "$output_safe" = false ] && overall_safe="false"
    [ "$quality_ok" = false ] && overall_safe="false"

    local result=$(jq -n \
        --argjson input "$input_check" \
        --argjson output "$output_check" \
        --argjson safe "$overall_safe" \
        '{
            overall_safe: $safe,
            input_checks: $input,
            output_checks: $output,
            recommendation: (if $safe then "accept" else "reject" end)
        }')

    echo "$result"
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-help}" in
        check-input)
            check_input "${2:-}" "${3:-detect}"
            ;;
        check-output)
            check_output "${2:-}" "${3:-text}" "${4:-general}"
            ;;
        full-check)
            full_check "${2:-}" "${3:-}" "${4:-text}"
            ;;
        help|--help|-h)
            cat <<EOF
Safety Gateway - Enterprise-grade safety checks

Usage: $0 <command> [options]

Commands:
  check-input <text> [action]
      Run safety filters on input text
      action: detect (default) | redact | block

  check-output <text> [format] [task_type]
      Run quality evaluations on output text
      format: text (default) | json | markdown

  full-check <input> <output> [format]
      Run complete safety check on input and output

Examples:
  $0 check-input "User prompt with email@example.com"
  $0 check-output '{"result": "success"}' json
  $0 full-check "input text" "output text" text
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
fi
