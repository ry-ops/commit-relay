#!/bin/bash
# scripts/lib/worker-reflection.sh
# Worker Self-Correction via Reflection
# Phase 2 Enhancement #17
#
# Provides reflection phase after task completion where workers
# validate their own output before marking tasks complete.
#
# Features:
# - Output validation checks
# - Acceptance criteria verification
# - Error detection and self-correction
# - Configurable retry limits
#
# Usage:
#   source scripts/lib/worker-reflection.sh
#   perform_reflection "$worker_id" "$task_id" "$output_location"

set -euo pipefail

# Prevent re-sourcing
if [ -n "${WORKER_REFLECTION_LOADED:-}" ]; then
    return 0
fi
WORKER_REFLECTION_LOADED=1

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Default retry configuration
MAX_REFLECTION_RETRIES="${MAX_REFLECTION_RETRIES:-3}"
REFLECTION_TIMEOUT="${REFLECTION_TIMEOUT:-60}"

# Source logging
source "$SCRIPT_DIR/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_debug() { echo "[DEBUG] $1"; }
}

# Reflection results directory
REFLECTION_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/reflections"
mkdir -p "$REFLECTION_DIR"

##############################################################################
# check_output_exists: Verify that output was produced
# Args:
#   $1: output_location - Path or identifier for output
# Returns: 0 if exists, 1 otherwise
##############################################################################
check_output_exists() {
    local output_location="$1"

    if [ -z "$output_location" ]; then
        return 1
    fi

    # Check if it's a file path
    if [[ "$output_location" == /* ]]; then
        if [ -f "$output_location" ] || [ -d "$output_location" ]; then
            return 0
        fi
        return 1
    fi

    # Check if it's a relative path in commit-relay
    if [ -f "$COMMIT_RELAY_HOME/$output_location" ] || [ -d "$COMMIT_RELAY_HOME/$output_location" ]; then
        return 0
    fi

    return 1
}

##############################################################################
# check_acceptance_criteria: Verify output meets acceptance criteria
# Args:
#   $1: worker_id
#   $2: task_id
#   $3: output_location
# Returns: JSON with check results
##############################################################################
check_acceptance_criteria() {
    local worker_id="$1"
    local task_id="$2"
    local output_location="$3"

    local checks_passed=0
    local checks_total=0
    local failed_checks=()

    # Get worker spec to find acceptance criteria
    local worker_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        worker_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/completed/${worker_id}.json"
    fi

    # Default criteria if no spec found
    local has_criteria=false

    if [ -f "$worker_spec" ]; then
        # Check if deliverables are specified
        local deliverables=$(jq -r '.deliverables // []' "$worker_spec")
        local deliverable_count=$(echo "$deliverables" | jq 'length')

        if [ "$deliverable_count" -gt 0 ]; then
            has_criteria=true
            ((checks_total += deliverable_count))

            # Check each deliverable
            for i in $(seq 0 $((deliverable_count - 1))); do
                local deliverable=$(echo "$deliverables" | jq -r ".[$i]")
                local del_type=$(echo "$deliverable" | jq -r '.type // "unknown"')
                local del_path=$(echo "$deliverable" | jq -r '.path // ""')

                if [ -n "$del_path" ]; then
                    if check_output_exists "$del_path"; then
                        ((checks_passed++))
                    else
                        failed_checks+=("Missing deliverable: $del_path")
                    fi
                else
                    # If no specific path, count as passed
                    ((checks_passed++))
                fi
            done
        fi
    fi

    # Basic output checks
    ((checks_total++))
    if check_output_exists "$output_location"; then
        ((checks_passed++))
    else
        failed_checks+=("Output location not found: $output_location")
    fi

    # Check for error markers in output
    if [ -f "$output_location" ]; then
        ((checks_total++))
        local error_count=$(grep -c -i "error\|failed\|exception" "$output_location" 2>/dev/null || echo "0")
        if [ "$error_count" -eq 0 ]; then
            ((checks_passed++))
        else
            failed_checks+=("Output contains $error_count error markers")
        fi

        # Check for empty output
        ((checks_total++))
        local file_size=$(wc -c < "$output_location" | tr -d ' ')
        if [ "$file_size" -gt 0 ]; then
            ((checks_passed++))
        else
            failed_checks+=("Output file is empty")
        fi
    fi

    # Build result JSON
    local failed_json="[]"
    if [ ${#failed_checks[@]} -gt 0 ]; then
        failed_json=$(printf '%s\n' "${failed_checks[@]}" | jq -R . | jq -s .)
    fi

    jq -n \
        --argjson passed "$checks_passed" \
        --argjson total "$checks_total" \
        --argjson failed "$failed_json" \
        --argjson has_criteria "$has_criteria" \
        '{
            checks_passed: $passed,
            checks_total: $total,
            success_rate: (if $total > 0 then ($passed / $total * 100) else 0 end),
            failed_checks: $failed,
            has_explicit_criteria: $has_criteria
        }'
}

##############################################################################
# detect_errors: Scan output for errors and issues
# Args:
#   $1: output_location
# Returns: JSON with detected errors
##############################################################################
detect_errors() {
    local output_location="$1"
    local errors=()
    local warnings=()

    if [ -f "$output_location" ]; then
        # Check for common error patterns
        while IFS= read -r line; do
            if echo "$line" | grep -qi "error\|failed\|exception\|fatal"; then
                errors+=("$line")
            elif echo "$line" | grep -qi "warn\|deprecated\|caution"; then
                warnings+=("$line")
            fi
        done < <(tail -100 "$output_location" 2>/dev/null)
    fi

    # Check for log files in output directory
    if [ -d "$output_location" ]; then
        for log_file in "$output_location"/*.log "$output_location"/*.err; do
            if [ -f "$log_file" ]; then
                local log_errors=$(grep -i "error\|failed" "$log_file" 2>/dev/null | head -5)
                if [ -n "$log_errors" ]; then
                    errors+=("From $log_file: $log_errors")
                fi
            fi
        done
    fi

    # Build result JSON (limit to first 10 of each)
    local errors_json="[]"
    local warnings_json="[]"

    if [ ${#errors[@]} -gt 0 ]; then
        errors_json=$(printf '%s\n' "${errors[@]:0:10}" | jq -R . | jq -s .)
    fi

    if [ ${#warnings[@]} -gt 0 ]; then
        warnings_json=$(printf '%s\n' "${warnings[@]:0:10}" | jq -R . | jq -s .)
    fi

    jq -n \
        --argjson errors "$errors_json" \
        --argjson warnings "$warnings_json" \
        '{
            error_count: ($errors | length),
            warning_count: ($warnings | length),
            errors: $errors,
            warnings: $warnings,
            needs_correction: (($errors | length) > 0)
        }'
}

##############################################################################
# generate_correction_suggestions: Generate suggestions for fixing issues
# Args:
#   $1: acceptance_results (JSON)
#   $2: error_results (JSON)
# Returns: JSON with correction suggestions
##############################################################################
generate_correction_suggestions() {
    local acceptance_results="$1"
    local error_results="$2"

    local suggestions=()

    # Analyze failed checks
    local failed_checks=$(echo "$acceptance_results" | jq -r '.failed_checks[]' 2>/dev/null)
    while IFS= read -r check; do
        if [ -n "$check" ]; then
            if echo "$check" | grep -q "Missing deliverable"; then
                suggestions+=("Create the missing output file or directory")
            elif echo "$check" | grep -q "empty"; then
                suggestions+=("Ensure the task produces non-empty output")
            elif echo "$check" | grep -q "error markers"; then
                suggestions+=("Review and fix errors in the output")
            fi
        fi
    done <<< "$failed_checks"

    # Analyze errors
    local error_count=$(echo "$error_results" | jq -r '.error_count')
    if [ "$error_count" -gt 0 ]; then
        suggestions+=("Fix $error_count errors detected in output")
        suggestions+=("Check logs for stack traces and error details")
    fi

    # Build result JSON
    local suggestions_json="[]"
    if [ ${#suggestions[@]} -gt 0 ]; then
        suggestions_json=$(printf '%s\n' "${suggestions[@]}" | jq -R . | jq -s 'unique')
    fi

    jq -n \
        --argjson suggestions "$suggestions_json" \
        '{
            suggestion_count: ($suggestions | length),
            suggestions: $suggestions
        }'
}

##############################################################################
# perform_reflection: Main reflection function
# Args:
#   $1: worker_id
#   $2: task_id
#   $3: output_location
#   $4: retry_count (optional, default 0)
# Returns: JSON reflection result
##############################################################################
perform_reflection() {
    local worker_id="$1"
    local task_id="$2"
    local output_location="$3"
    local retry_count="${4:-0}"

    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")

    log_info "[Reflection] Starting reflection for worker $worker_id, task $task_id (attempt $((retry_count + 1)))"

    # Step 1: Check acceptance criteria
    local acceptance_results=$(check_acceptance_criteria "$worker_id" "$task_id" "$output_location")
    local success_rate=$(echo "$acceptance_results" | jq -r '.success_rate')

    # Step 2: Detect errors
    local error_results=$(detect_errors "$output_location")
    local needs_correction=$(echo "$error_results" | jq -r '.needs_correction')

    # Step 3: Generate correction suggestions if needed
    local correction_suggestions='{"suggestion_count": 0, "suggestions": []}'
    if [ "$needs_correction" = "true" ] || [ "$(echo "$success_rate < 100" | bc -l)" -eq 1 ]; then
        correction_suggestions=$(generate_correction_suggestions "$acceptance_results" "$error_results")
    fi

    # Step 4: Determine overall result
    local reflection_passed=false
    local recommendation="complete"

    if [ "$needs_correction" = "false" ] && [ "$(echo "$success_rate >= 80" | bc -l)" -eq 1 ]; then
        reflection_passed=true
        if [ "$(echo "$success_rate < 100" | bc -l)" -eq 1 ]; then
            recommendation="complete_with_warnings"
        fi
    elif [ "$retry_count" -ge "$MAX_REFLECTION_RETRIES" ]; then
        recommendation="fail_max_retries"
    else
        recommendation="retry_with_corrections"
    fi

    # Build reflection result
    local reflection_result=$(jq -n \
        --arg worker_id "$worker_id" \
        --arg task_id "$task_id" \
        --arg timestamp "$timestamp" \
        --argjson retry_count "$retry_count" \
        --argjson max_retries "$MAX_REFLECTION_RETRIES" \
        --argjson passed "$reflection_passed" \
        --arg recommendation "$recommendation" \
        --argjson acceptance "$acceptance_results" \
        --argjson errors "$error_results" \
        --argjson corrections "$correction_suggestions" \
        '{
            worker_id: $worker_id,
            task_id: $task_id,
            timestamp: $timestamp,
            reflection_attempt: ($retry_count + 1),
            max_attempts: $max_retries,
            passed: $passed,
            recommendation: $recommendation,
            acceptance_check: $acceptance,
            error_detection: $errors,
            correction_suggestions: $corrections
        }')

    # Save reflection result
    local reflection_file="$REFLECTION_DIR/${worker_id}-reflection-$(date +%Y%m%d%H%M%S).json"
    echo "$reflection_result" | jq '.' > "$reflection_file"

    log_info "[Reflection] Result: passed=$reflection_passed, recommendation=$recommendation"

    # Emit dashboard event
    local events_file="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
    if [ -w "$(dirname "$events_file")" ] || [ -w "$events_file" ]; then
        local event_json=$(jq -n \
            --arg timestamp "$timestamp" \
            --arg worker_id "$worker_id" \
            --arg task_id "$task_id" \
            --argjson passed "$reflection_passed" \
            --arg recommendation "$recommendation" \
            '{
                timestamp: $timestamp,
                type: "worker_reflection",
                data: {
                    worker_id: $worker_id,
                    task_id: $task_id,
                    passed: $passed,
                    recommendation: $recommendation
                }
            }')
        echo "$event_json" >> "$events_file" 2>/dev/null || true
    fi

    echo "$reflection_result"
}

##############################################################################
# should_retry_after_reflection: Check if worker should retry
# Args:
#   $1: reflection_result (JSON)
# Returns: 0 if should retry, 1 otherwise
##############################################################################
should_retry_after_reflection() {
    local reflection_result="$1"
    local recommendation=$(echo "$reflection_result" | jq -r '.recommendation')

    case "$recommendation" in
        retry_with_corrections)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

##############################################################################
# get_correction_context: Get context for worker to make corrections
# Args:
#   $1: reflection_result (JSON)
# Returns: Formatted correction context string
##############################################################################
get_correction_context() {
    local reflection_result="$1"

    local suggestions=$(echo "$reflection_result" | jq -r '.correction_suggestions.suggestions[]' 2>/dev/null)
    local errors=$(echo "$reflection_result" | jq -r '.error_detection.errors[]' 2>/dev/null)
    local failed_checks=$(echo "$reflection_result" | jq -r '.acceptance_check.failed_checks[]' 2>/dev/null)

    local context="SELF-CORRECTION NEEDED:\n\n"

    if [ -n "$failed_checks" ]; then
        context+="Failed Checks:\n"
        while IFS= read -r check; do
            [ -n "$check" ] && context+="- $check\n"
        done <<< "$failed_checks"
        context+="\n"
    fi

    if [ -n "$errors" ]; then
        context+="Detected Errors:\n"
        while IFS= read -r error; do
            [ -n "$error" ] && context+="- $error\n"
        done <<< "$errors"
        context+="\n"
    fi

    if [ -n "$suggestions" ]; then
        context+="Suggested Corrections:\n"
        while IFS= read -r suggestion; do
            [ -n "$suggestion" ] && context+="- $suggestion\n"
        done <<< "$suggestions"
    fi

    echo -e "$context"
}

##############################################################################
# Export Functions
##############################################################################
export -f check_output_exists
export -f check_acceptance_criteria
export -f detect_errors
export -f generate_correction_suggestions
export -f perform_reflection
export -f should_retry_after_reflection
export -f get_correction_context

##############################################################################
# CLI Interface
##############################################################################
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        reflect)
            if [ $# -lt 4 ]; then
                echo "Usage: $0 reflect <worker_id> <task_id> <output_location> [retry_count]"
                exit 1
            fi
            perform_reflection "$2" "$3" "$4" "${5:-0}"
            ;;
        check-output)
            if check_output_exists "$2"; then
                echo "Output exists: $2"
                exit 0
            else
                echo "Output not found: $2"
                exit 1
            fi
            ;;
        check-criteria)
            if [ $# -lt 4 ]; then
                echo "Usage: $0 check-criteria <worker_id> <task_id> <output_location>"
                exit 1
            fi
            check_acceptance_criteria "$2" "$3" "$4"
            ;;
        detect-errors)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 detect-errors <output_location>"
                exit 1
            fi
            detect_errors "$2"
            ;;
        help|*)
            echo "Worker Self-Correction via Reflection"
            echo ""
            echo "Usage: worker-reflection.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  reflect <worker_id> <task_id> <output> [retry]  Perform full reflection"
            echo "  check-output <path>                              Check if output exists"
            echo "  check-criteria <worker> <task> <output>          Check acceptance criteria"
            echo "  detect-errors <output>                           Detect errors in output"
            echo ""
            echo "Environment Variables:"
            echo "  MAX_REFLECTION_RETRIES  Maximum retry attempts (default: 3)"
            echo "  REFLECTION_TIMEOUT      Timeout in seconds (default: 60)"
            ;;
    esac
fi
