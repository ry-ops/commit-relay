#!/usr/bin/env bash
#
# Policy Validator Library
# Part of Phase 4 Item 28: Policy-as-Code Validation
#
# Evaluates policy definitions programmatically against tasks and workers.
# Provides enforcement and audit capabilities.
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Configuration
readonly POLICY_DEFINITIONS="${POLICY_DEFINITIONS:-$PROJECT_ROOT/coordination/governance/policies/policy-definitions.json}"
readonly POLICY_EVALUATION_LOG="${POLICY_EVALUATION_LOG:-$PROJECT_ROOT/coordination/governance/policy-evaluations.jsonl}"
readonly POLICY_VIOLATIONS_LOG="${POLICY_VIOLATIONS_LOG:-$PROJECT_ROOT/coordination/governance/policy-violations.jsonl}"
readonly POLICY_CACHE_FILE="${POLICY_CACHE_FILE:-/tmp/commit-relay-policy-cache.json}"

# Initialize directories
mkdir -p "$(dirname "$POLICY_EVALUATION_LOG")"

#
# Log policy message
#
log_policy() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >&2
}

#
# Get current timestamp
#
get_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

#
# Load policy definitions
#
load_policies() {
    local use_cache="${1:-true}"

    # Check cache
    if [[ "$use_cache" == "true" && -f "$POLICY_CACHE_FILE" ]]; then
        local cache_time=$(stat -f %m "$POLICY_CACHE_FILE" 2>/dev/null || stat -c %Y "$POLICY_CACHE_FILE" 2>/dev/null || echo "0")
        local now=$(date +%s)
        local cache_ttl=300  # 5 minutes

        if [[ $((now - cache_time)) -lt $cache_ttl ]]; then
            cat "$POLICY_CACHE_FILE"
            return 0
        fi
    fi

    # Load from file
    if [[ -f "$POLICY_DEFINITIONS" ]]; then
        local policies=$(cat "$POLICY_DEFINITIONS")
        echo "$policies" > "$POLICY_CACHE_FILE"
        echo "$policies"
    else
        echo '{"policies": []}'
    fi
}

#
# Get policy by ID
#
get_policy() {
    local policy_id="$1"

    local policies=$(load_policies)
    echo "$policies" | jq -r --arg id "$policy_id" '.policies[] | select(.policy_id == $id)'
}

#
# Get policies by category
#
get_policies_by_category() {
    local category="$1"

    local policies=$(load_policies)
    echo "$policies" | jq -r --arg cat "$category" '[.policies[] | select(.category == $cat and .enabled == true)]'
}

#
# Evaluate a simple condition
# Supports basic comparisons and checks
#
evaluate_condition() {
    local condition="$1"
    local context="$2"
    local params="$3"

    # Replace condition variables with actual values
    # This is a simplified evaluator - production would use a proper expression parser

    # Extract the comparison operator
    if [[ "$condition" == *"<="* ]]; then
        local left=$(echo "$condition" | cut -d'<' -f1 | tr -d ' ')
        local right=$(echo "$condition" | cut -d'=' -f2 | tr -d ' ')
        local op="le"
    elif [[ "$condition" == *">="* ]]; then
        local left=$(echo "$condition" | cut -d'>' -f1 | tr -d ' ')
        local right=$(echo "$condition" | cut -d'=' -f2 | tr -d ' ')
        local op="ge"
    elif [[ "$condition" == *"<"* ]]; then
        local left=$(echo "$condition" | cut -d'<' -f1 | tr -d ' ')
        local right=$(echo "$condition" | cut -d'<' -f2 | tr -d ' ')
        local op="lt"
    elif [[ "$condition" == *">"* ]]; then
        local left=$(echo "$condition" | cut -d'>' -f1 | tr -d ' ')
        local right=$(echo "$condition" | cut -d'>' -f2 | tr -d ' ')
        local op="gt"
    elif [[ "$condition" == *"=="* ]]; then
        local left=$(echo "$condition" | cut -d'=' -f1 | tr -d ' ')
        local right=$(echo "$condition" | cut -d'=' -f3 | tr -d ' ')
        local op="eq"
    elif [[ "$condition" == *"!="* ]]; then
        local left=$(echo "$condition" | cut -d'!' -f1 | tr -d ' ')
        local right=$(echo "$condition" | cut -d'=' -f2 | tr -d ' ')
        local op="ne"
    elif [[ "$condition" == "!"* ]]; then
        # Negation
        local inner="${condition:1}"
        if evaluate_condition "$inner" "$context" "$params"; then
            return 1
        else
            return 0
        fi
    else
        # Boolean check
        local value=$(resolve_variable "$condition" "$context" "$params")
        if [[ "$value" == "true" ]]; then
            return 0
        else
            return 1
        fi
    fi

    # Resolve variable values
    local left_val=$(resolve_variable "$left" "$context" "$params")
    local right_val=$(resolve_variable "$right" "$context" "$params")

    # Perform comparison
    case "$op" in
        "le")
            [[ $(echo "$left_val <= $right_val" | bc -l 2>/dev/null) -eq 1 ]]
            ;;
        "ge")
            [[ $(echo "$left_val >= $right_val" | bc -l 2>/dev/null) -eq 1 ]]
            ;;
        "lt")
            [[ $(echo "$left_val < $right_val" | bc -l 2>/dev/null) -eq 1 ]]
            ;;
        "gt")
            [[ $(echo "$left_val > $right_val" | bc -l 2>/dev/null) -eq 1 ]]
            ;;
        "eq")
            [[ "$left_val" == "$right_val" ]]
            ;;
        "ne")
            [[ "$left_val" != "$right_val" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

#
# Resolve a variable reference to its value
#
resolve_variable() {
    local var="$1"
    local context="$2"
    local params="$3"

    # Check for policy parameter reference
    if [[ "$var" == policy.* ]]; then
        local param_name="${var#policy.}"
        echo "$params" | jq -r ".$param_name // empty"
        return
    fi

    # Check for context reference
    if [[ "$var" == task.* || "$var" == worker.* || "$var" == system.* || "$var" == queue.* ]]; then
        local path="${var//./ | .}"
        echo "$context" | jq -r ".$path // empty"
        return
    fi

    # Return as literal
    echo "$var"
}

#
# Evaluate a single policy rule
#
evaluate_rule() {
    local rule="$1"
    local context="$2"

    local rule_id=$(echo "$rule" | jq -r '.rule_id')
    local condition=$(echo "$rule" | jq -r '.condition')
    local params=$(echo "$rule" | jq '.params')
    local action=$(echo "$rule" | jq -r '.action')
    local message=$(echo "$rule" | jq -r '.message')

    local result="pass"
    local details=""

    # Evaluate the condition
    if ! evaluate_condition "$condition" "$context" "$params" 2>/dev/null; then
        result="fail"
        details="$message"
    fi

    jq -n \
        --arg rule_id "$rule_id" \
        --arg result "$result" \
        --arg action "$action" \
        --arg details "$details" \
        '{
            rule_id: $rule_id,
            result: $result,
            action: $action,
            details: $details
        }'
}

#
# Validate context against a specific policy
#
validate_against_policy() {
    local policy_id="$1"
    local context="$2"

    local policy=$(get_policy "$policy_id")

    if [[ -z "$policy" || "$policy" == "null" ]]; then
        log_policy "ERROR" "Policy not found: $policy_id"
        return 1
    fi

    local policy_name=$(echo "$policy" | jq -r '.name')
    local policy_severity=$(echo "$policy" | jq -r '.severity')

    local evaluation_id="eval-$(date +%s%N | cut -b1-13)"
    local rule_results="[]"
    local overall_result="pass"
    local violations=0
    local warnings=0

    # Evaluate each rule
    local rules=$(echo "$policy" | jq -c '.rules[]')

    while IFS= read -r rule; do
        local rule_result=$(evaluate_rule "$rule" "$context")
        rule_results=$(echo "$rule_results" | jq --argjson result "$rule_result" '. += [$result]')

        local result_status=$(echo "$rule_result" | jq -r '.result')
        local action=$(echo "$rule_result" | jq -r '.action')

        if [[ "$result_status" == "fail" ]]; then
            case "$action" in
                "reject"|"require_approval")
                    overall_result="fail"
                    violations=$((violations + 1))
                    ;;
                "warn")
                    warnings=$((warnings + 1))
                    ;;
                *)
                    warnings=$((warnings + 1))
                    ;;
            esac
        fi
    done <<< "$rules"

    # Create evaluation record
    local evaluation=$(jq -n \
        --arg evaluation_id "$evaluation_id" \
        --arg policy_id "$policy_id" \
        --arg policy_name "$policy_name" \
        --arg severity "$policy_severity" \
        --arg result "$overall_result" \
        --argjson violations "$violations" \
        --argjson warnings "$warnings" \
        --argjson rule_results "$rule_results" \
        --arg timestamp "$(get_timestamp)" \
        '{
            evaluation_id: $evaluation_id,
            policy_id: $policy_id,
            policy_name: $policy_name,
            severity: $severity,
            result: $result,
            violations: $violations,
            warnings: $warnings,
            rule_results: $rule_results,
            evaluated_at: $timestamp
        }')

    # Log evaluation
    echo "$evaluation" >> "$POLICY_EVALUATION_LOG"

    # Log violations separately
    if [[ $violations -gt 0 ]]; then
        echo "$evaluation" >> "$POLICY_VIOLATIONS_LOG"
    fi

    echo "$evaluation"
}

#
# Validate context against all applicable policies
#
validate_all_policies() {
    local context="$1"
    local categories="${2:-all}"

    local policies=$(load_policies)
    local all_evaluations="[]"
    local overall_pass=true
    local total_violations=0
    local total_warnings=0

    # Get applicable policies
    local policy_list
    if [[ "$categories" == "all" ]]; then
        policy_list=$(echo "$policies" | jq -c '.policies[] | select(.enabled == true)')
    else
        policy_list=$(echo "$policies" | jq -c --arg cats "$categories" '
            .policies[] | select(.enabled == true and (.category | inside($cats)))
        ')
    fi

    # Evaluate each policy
    while IFS= read -r policy; do
        if [[ -z "$policy" ]]; then
            continue
        fi

        local policy_id=$(echo "$policy" | jq -r '.policy_id')
        local evaluation=$(validate_against_policy "$policy_id" "$context")

        all_evaluations=$(echo "$all_evaluations" | jq --argjson eval "$evaluation" '. += [$eval]')

        local result=$(echo "$evaluation" | jq -r '.result')
        local violations=$(echo "$evaluation" | jq -r '.violations')
        local warnings=$(echo "$evaluation" | jq -r '.warnings')

        total_violations=$((total_violations + violations))
        total_warnings=$((total_warnings + warnings))

        if [[ "$result" == "fail" ]]; then
            overall_pass=false
        fi
    done <<< "$policy_list"

    # Summary
    local overall_result="pass"
    if [[ "$overall_pass" == "false" ]]; then
        overall_result="fail"
    elif [[ $total_warnings -gt 0 ]]; then
        overall_result="pass_with_warnings"
    fi

    jq -n \
        --arg result "$overall_result" \
        --argjson total_violations "$total_violations" \
        --argjson total_warnings "$total_warnings" \
        --argjson evaluations "$all_evaluations" \
        --arg timestamp "$(get_timestamp)" \
        '{
            overall_result: $result,
            total_violations: $total_violations,
            total_warnings: $total_warnings,
            evaluations: $evaluations,
            evaluated_at: $timestamp
        }'
}

#
# Quick validation check (returns exit code)
#
quick_validate() {
    local context="$1"
    local policy_id="${2:-}"

    local result
    if [[ -n "$policy_id" ]]; then
        result=$(validate_against_policy "$policy_id" "$context" | jq -r '.result')
    else
        result=$(validate_all_policies "$context" | jq -r '.overall_result')
    fi

    if [[ "$result" == "pass" || "$result" == "pass_with_warnings" ]]; then
        return 0
    else
        return 1
    fi
}

#
# Get policy compliance summary
#
get_compliance_summary() {
    local policies=$(load_policies)
    local enabled_count=$(echo "$policies" | jq '[.policies[] | select(.enabled == true)] | length')
    local total_rules=$(echo "$policies" | jq '[.policies[] | select(.enabled == true) | .rules[]] | length')

    # Count by category
    local by_category=$(echo "$policies" | jq '
        [.policies[] | select(.enabled == true)]
        | group_by(.category)
        | map({(.[0].category): length})
        | add
    ')

    # Count by severity
    local by_severity=$(echo "$policies" | jq '
        [.policies[] | select(.enabled == true)]
        | group_by(.severity)
        | map({(.[0].severity): length})
        | add
    ')

    jq -n \
        --argjson enabled "$enabled_count" \
        --argjson rules "$total_rules" \
        --argjson by_category "$by_category" \
        --argjson by_severity "$by_severity" \
        --arg timestamp "$(get_timestamp)" \
        '{
            enabled_policies: $enabled,
            total_rules: $rules,
            by_category: $by_category,
            by_severity: $by_severity,
            generated_at: $timestamp
        }'
}

#
# List recent violations
#
list_violations() {
    local limit="${1:-20}"

    if [[ -f "$POLICY_VIOLATIONS_LOG" ]]; then
        tail -n "$limit" "$POLICY_VIOLATIONS_LOG" | jq -s '.'
    else
        echo "[]"
    fi
}

#
# Clear policy cache
#
clear_cache() {
    rm -f "$POLICY_CACHE_FILE"
    log_policy "INFO" "Policy cache cleared"
}

# Export functions
export -f load_policies
export -f get_policy
export -f get_policies_by_category
export -f validate_against_policy
export -f validate_all_policies
export -f quick_validate
export -f get_compliance_summary
export -f list_violations
export -f clear_cache
