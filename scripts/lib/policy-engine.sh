#!/usr/bin/env bash
#
# Policy-as-Code Validation Engine
# Part of Phase 3 Security & Compliance
#
# Evaluates JSON/YAML policy definitions programmatically against
# worker specs, actions, and system configurations.
#
# Features:
# - JSON/YAML policy definitions
# - Condition evaluation: equals, contains, regex, numeric comparisons
# - Pass/fail with detailed explanations
# - Audit logging of all policy evaluations
#
# Usage:
#   source scripts/lib/policy-engine.sh
#   evaluate_policy "worker-spec.json" "security-policy.json"
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
readonly POLICY_DEFINITIONS_DIR="${POLICY_DEFINITIONS_DIR:-$PROJECT_ROOT/coordination/policies/policy-definitions}"
readonly POLICY_AUDIT_LOG="${POLICY_AUDIT_LOG:-$PROJECT_ROOT/coordination/policies/audit-logs/policy-evaluations.jsonl}"
readonly POLICY_RESULTS_DIR="${POLICY_RESULTS_DIR:-$PROJECT_ROOT/coordination/policies/evaluation-results}"

# Ensure directories exist
mkdir -p "$POLICY_DEFINITIONS_DIR" "$PROJECT_ROOT/coordination/policies/audit-logs" "$POLICY_RESULTS_DIR"

# ==============================================================================
# Logging Functions
# ==============================================================================

log_info() {
    echo "[INFO] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

log_error() {
    echo "[ERROR] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

log_warn() {
    echo "[WARN] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "[DEBUG] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
    fi
}

# ==============================================================================
# Policy Schema Definition
# ==============================================================================

# Get the policy schema for validation reference
get_policy_schema() {
    cat <<'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Policy Definition Schema",
  "type": "object",
  "required": ["policy_id", "name", "version", "rules"],
  "properties": {
    "policy_id": {
      "type": "string",
      "pattern": "^[a-z0-9-]+$",
      "description": "Unique policy identifier"
    },
    "name": {
      "type": "string",
      "description": "Human-readable policy name"
    },
    "description": {
      "type": "string",
      "description": "Policy description"
    },
    "version": {
      "type": "string",
      "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$",
      "description": "Semantic version"
    },
    "severity": {
      "type": "string",
      "enum": ["critical", "high", "medium", "low", "info"],
      "description": "Policy severity level"
    },
    "enabled": {
      "type": "boolean",
      "default": true
    },
    "frameworks": {
      "type": "array",
      "items": {
        "type": "string",
        "enum": ["nist-csf", "soc2", "owasp", "cis", "custom"]
      },
      "description": "Compliance frameworks this policy supports"
    },
    "controls": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "description": "Control IDs this policy implements"
    },
    "rules": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["rule_id", "condition"],
        "properties": {
          "rule_id": {
            "type": "string",
            "description": "Unique rule identifier within policy"
          },
          "description": {
            "type": "string"
          },
          "field": {
            "type": "string",
            "description": "JSON path to field to evaluate (dot notation)"
          },
          "condition": {
            "type": "object",
            "properties": {
              "type": {
                "type": "string",
                "enum": ["equals", "not_equals", "contains", "not_contains", "regex", "matches", "greater_than", "less_than", "greater_or_equal", "less_or_equal", "in", "not_in", "exists", "not_exists", "is_type", "all", "any", "none"]
              },
              "value": {
                "description": "Expected value or pattern"
              },
              "conditions": {
                "type": "array",
                "description": "Nested conditions for all/any/none"
              }
            },
            "required": ["type"]
          },
          "message": {
            "type": "string",
            "description": "Custom failure message"
          },
          "remediation": {
            "type": "string",
            "description": "Suggested fix for violation"
          }
        }
      }
    },
    "metadata": {
      "type": "object",
      "properties": {
        "author": { "type": "string" },
        "created_at": { "type": "string", "format": "date-time" },
        "updated_at": { "type": "string", "format": "date-time" },
        "tags": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    }
  }
}
EOF
}

# ==============================================================================
# YAML Support
# ==============================================================================

# Convert YAML to JSON (requires yq or python)
yaml_to_json() {
    local yaml_file="$1"

    # Try yq first (faster)
    if command -v yq &>/dev/null; then
        yq -o=json "$yaml_file"
        return $?
    fi

    # Fall back to Python
    if command -v python3 &>/dev/null; then
        python3 -c "
import yaml
import json
import sys
with open('$yaml_file') as f:
    print(json.dumps(yaml.safe_load(f)))
"
        return $?
    fi

    log_error "Neither yq nor python3 with pyyaml available for YAML parsing"
    return 1
}

# ==============================================================================
# Condition Evaluation Functions
# ==============================================================================

# Extract value from JSON using jq path
extract_value() {
    local json="$1"
    local field_path="$2"

    # Convert dot notation to jq path
    local jq_path
    if [[ "$field_path" == "." || -z "$field_path" ]]; then
        jq_path="."
    else
        jq_path=".$field_path"
    fi

    echo "$json" | jq -r "$jq_path // null" 2>/dev/null
}

# Check if value exists (not null or empty)
value_exists() {
    local value="$1"
    [[ -n "$value" && "$value" != "null" ]]
}

# Evaluate a single condition
evaluate_condition() {
    local actual_value="$1"
    local condition_type="$2"
    local expected_value="$3"
    local json_context="${4:-}"

    case "$condition_type" in
        equals|eq)
            [[ "$actual_value" == "$expected_value" ]]
            ;;
        not_equals|neq)
            [[ "$actual_value" != "$expected_value" ]]
            ;;
        contains)
            [[ "$actual_value" == *"$expected_value"* ]]
            ;;
        not_contains)
            [[ "$actual_value" != *"$expected_value"* ]]
            ;;
        regex|matches)
            echo "$actual_value" | grep -qE "$expected_value"
            ;;
        greater_than|gt)
            [[ -n "$actual_value" && "$actual_value" != "null" ]] && \
            (( $(echo "$actual_value > $expected_value" | bc -l 2>/dev/null || echo 0) == 1 ))
            ;;
        less_than|lt)
            [[ -n "$actual_value" && "$actual_value" != "null" ]] && \
            (( $(echo "$actual_value < $expected_value" | bc -l 2>/dev/null || echo 0) == 1 ))
            ;;
        greater_or_equal|gte)
            [[ -n "$actual_value" && "$actual_value" != "null" ]] && \
            (( $(echo "$actual_value >= $expected_value" | bc -l 2>/dev/null || echo 0) == 1 ))
            ;;
        less_or_equal|lte)
            [[ -n "$actual_value" && "$actual_value" != "null" ]] && \
            (( $(echo "$actual_value <= $expected_value" | bc -l 2>/dev/null || echo 0) == 1 ))
            ;;
        in)
            # Check if value is in a JSON array
            echo "$expected_value" | jq -e --arg v "$actual_value" 'index($v) != null' &>/dev/null
            ;;
        not_in)
            ! echo "$expected_value" | jq -e --arg v "$actual_value" 'index($v) != null' &>/dev/null
            ;;
        exists)
            value_exists "$actual_value"
            ;;
        not_exists)
            ! value_exists "$actual_value"
            ;;
        is_type)
            local actual_type
            if [[ -z "$json_context" ]]; then
                # Infer type from value
                if [[ "$actual_value" =~ ^[0-9]+$ ]]; then
                    actual_type="number"
                elif [[ "$actual_value" =~ ^(true|false)$ ]]; then
                    actual_type="boolean"
                elif [[ "$actual_value" == "null" ]]; then
                    actual_type="null"
                elif [[ "$actual_value" =~ ^\[.*\]$ ]]; then
                    actual_type="array"
                elif [[ "$actual_value" =~ ^\{.*\}$ ]]; then
                    actual_type="object"
                else
                    actual_type="string"
                fi
            else
                actual_type=$(echo "$json_context" | jq -r "type" 2>/dev/null || echo "unknown")
            fi
            [[ "$actual_type" == "$expected_value" ]]
            ;;
        *)
            log_error "Unknown condition type: $condition_type"
            return 1
            ;;
    esac
}

# Evaluate complex nested conditions (all, any, none)
evaluate_complex_condition() {
    local json="$1"
    local condition_json="$2"

    local condition_type
    condition_type=$(echo "$condition_json" | jq -r '.type')

    case "$condition_type" in
        all)
            # All sub-conditions must pass
            local conditions
            conditions=$(echo "$condition_json" | jq -c '.conditions[]')

            while IFS= read -r sub_condition; do
                if ! evaluate_rule_condition "$json" "$sub_condition"; then
                    return 1
                fi
            done <<< "$conditions"
            return 0
            ;;
        any)
            # At least one sub-condition must pass
            local conditions
            conditions=$(echo "$condition_json" | jq -c '.conditions[]')

            while IFS= read -r sub_condition; do
                if evaluate_rule_condition "$json" "$sub_condition"; then
                    return 0
                fi
            done <<< "$conditions"
            return 1
            ;;
        none)
            # No sub-conditions should pass
            local conditions
            conditions=$(echo "$condition_json" | jq -c '.conditions[]')

            while IFS= read -r sub_condition; do
                if evaluate_rule_condition "$json" "$sub_condition"; then
                    return 1
                fi
            done <<< "$conditions"
            return 0
            ;;
        *)
            # Simple condition
            local field
            field=$(echo "$condition_json" | jq -r '.field // "."')
            local expected
            expected=$(echo "$condition_json" | jq -r '.value // ""')
            local actual
            actual=$(extract_value "$json" "$field")

            evaluate_condition "$actual" "$condition_type" "$expected" "$json"
            ;;
    esac
}

# Evaluate a single rule's condition
evaluate_rule_condition() {
    local json="$1"
    local condition_json="$2"

    local condition_type
    condition_type=$(echo "$condition_json" | jq -r '.type')

    if [[ "$condition_type" == "all" || "$condition_type" == "any" || "$condition_type" == "none" ]]; then
        evaluate_complex_condition "$json" "$condition_json"
    else
        local field
        field=$(echo "$condition_json" | jq -r '.field // "."')
        local expected
        expected=$(echo "$condition_json" | jq -r '.value // ""')
        local actual
        actual=$(extract_value "$json" "$field")

        evaluate_condition "$actual" "$condition_type" "$expected"
    fi
}

# ==============================================================================
# Policy Evaluation Functions
# ==============================================================================

# Evaluate a single rule against target JSON
evaluate_rule() {
    local target_json="$1"
    local rule_json="$2"

    local rule_id
    rule_id=$(echo "$rule_json" | jq -r '.rule_id')
    local description
    description=$(echo "$rule_json" | jq -r '.description // "No description"')
    local condition
    condition=$(echo "$rule_json" | jq -c '.condition')
    local field
    field=$(echo "$rule_json" | jq -r '.field // "."')

    log_debug "Evaluating rule: $rule_id"

    # Get actual value for reporting
    local actual_value
    actual_value=$(extract_value "$target_json" "$field")

    # Evaluate the condition
    local result="pass"
    local message=""

    if ! evaluate_rule_condition "$target_json" "$condition"; then
        result="fail"
        message=$(echo "$rule_json" | jq -r '.message // "Condition not satisfied"')
    fi

    # Build result JSON
    local condition_type
    condition_type=$(echo "$condition" | jq -r '.type')
    local expected_value
    expected_value=$(echo "$condition" | jq -r '.value // ""')

    jq -n \
        --arg rule_id "$rule_id" \
        --arg description "$description" \
        --arg result "$result" \
        --arg field "$field" \
        --arg actual "$actual_value" \
        --arg expected "$expected_value" \
        --arg condition_type "$condition_type" \
        --arg message "$message" \
        --arg remediation "$(echo "$rule_json" | jq -r '.remediation // ""')" \
        '{
            rule_id: $rule_id,
            description: $description,
            result: $result,
            field: $field,
            actual_value: $actual,
            expected_value: $expected,
            condition_type: $condition_type,
            message: (if $message != "" then $message else null end),
            remediation: (if $remediation != "" then $remediation else null end)
        }'
}

# Evaluate a complete policy against target JSON
evaluate_policy() {
    local target_path="$1"
    local policy_path="$2"

    # Read target (can be JSON file or inline JSON)
    local target_json
    if [[ -f "$target_path" ]]; then
        target_json=$(cat "$target_path")
    else
        target_json="$target_path"
    fi

    # Read policy (support JSON and YAML)
    local policy_json
    if [[ -f "$policy_path" ]]; then
        if [[ "$policy_path" == *.yaml || "$policy_path" == *.yml ]]; then
            policy_json=$(yaml_to_json "$policy_path")
        else
            policy_json=$(cat "$policy_path")
        fi
    else
        policy_json="$policy_path"
    fi

    # Validate policy JSON
    if ! echo "$policy_json" | jq empty 2>/dev/null; then
        log_error "Invalid policy JSON"
        return 1
    fi

    # Check if policy is enabled
    local enabled
    enabled=$(echo "$policy_json" | jq -r '.enabled // true')
    if [[ "$enabled" == "false" ]]; then
        log_info "Policy is disabled, skipping"
        return 0
    fi

    # Extract policy metadata
    local policy_id
    policy_id=$(echo "$policy_json" | jq -r '.policy_id')
    local policy_name
    policy_name=$(echo "$policy_json" | jq -r '.name')
    local severity
    severity=$(echo "$policy_json" | jq -r '.severity // "medium"')
    local version
    version=$(echo "$policy_json" | jq -r '.version // "1.0.0"')

    log_info "Evaluating policy: $policy_name ($policy_id) v$version"

    # Evaluate all rules
    local rules
    rules=$(echo "$policy_json" | jq -c '.rules[]')
    local rule_results=()
    local pass_count=0
    local fail_count=0

    while IFS= read -r rule; do
        local result
        result=$(evaluate_rule "$target_json" "$rule")
        rule_results+=("$result")

        if [[ $(echo "$result" | jq -r '.result') == "pass" ]]; then
            ((pass_count++))
        else
            ((fail_count++))
        fi
    done <<< "$rules"

    # Determine overall result
    local overall_result="pass"
    if [[ $fail_count -gt 0 ]]; then
        overall_result="fail"
    fi

    # Calculate compliance percentage
    local total_rules=$((pass_count + fail_count))
    local compliance_percentage=100
    if [[ $total_rules -gt 0 ]]; then
        compliance_percentage=$(echo "scale=2; ($pass_count * 100) / $total_rules" | bc)
    fi

    # Build evaluation result
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local evaluation_result
    evaluation_result=$(jq -n \
        --arg evaluation_id "eval-$(date +%s)-$$" \
        --arg timestamp "$timestamp" \
        --arg policy_id "$policy_id" \
        --arg policy_name "$policy_name" \
        --arg version "$version" \
        --arg severity "$severity" \
        --arg target "$(basename "${target_path:-inline}")" \
        --arg overall_result "$overall_result" \
        --argjson pass_count "$pass_count" \
        --argjson fail_count "$fail_count" \
        --arg compliance_percentage "$compliance_percentage" \
        --argjson frameworks "$(echo "$policy_json" | jq '.frameworks // []')" \
        --argjson controls "$(echo "$policy_json" | jq '.controls // []')" \
        --argjson rule_results "$(printf '%s\n' "${rule_results[@]}" | jq -s '.')" \
        '{
            evaluation_id: $evaluation_id,
            timestamp: $timestamp,
            policy: {
                id: $policy_id,
                name: $policy_name,
                version: $version,
                severity: $severity,
                frameworks: $frameworks,
                controls: $controls
            },
            target: $target,
            result: $overall_result,
            summary: {
                total_rules: ($pass_count + $fail_count),
                passed: $pass_count,
                failed: $fail_count,
                compliance_percentage: ($compliance_percentage | tonumber)
            },
            rule_results: $rule_results
        }')

    # Log evaluation for audit
    log_policy_evaluation "$evaluation_result"

    # Output result
    echo "$evaluation_result"

    # Return non-zero if policy failed
    [[ "$overall_result" == "pass" ]]
}

# Evaluate all policies in a directory against a target
evaluate_all_policies() {
    local target_path="$1"
    local policy_dir="${2:-$POLICY_DEFINITIONS_DIR}"

    local results=()
    local total_pass=0
    local total_fail=0

    # Find all policy files
    local policy_files
    policy_files=$(find "$policy_dir" -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | sort)

    if [[ -z "$policy_files" ]]; then
        log_warn "No policy files found in $policy_dir"
        return 0
    fi

    log_info "Evaluating $(echo "$policy_files" | wc -l | tr -d ' ') policies..."

    while IFS= read -r policy_file; do
        local result
        if result=$(evaluate_policy "$target_path" "$policy_file" 2>/dev/null); then
            ((total_pass++))
        else
            ((total_fail++))
        fi

        if [[ -n "$result" ]]; then
            results+=("$result")
        fi
    done <<< "$policy_files"

    # Build aggregate result
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq -n \
        --arg timestamp "$timestamp" \
        --arg target "$(basename "$target_path")" \
        --argjson total_policies "$((total_pass + total_fail))" \
        --argjson passed "$total_pass" \
        --argjson failed "$total_fail" \
        --argjson policy_results "$(printf '%s\n' "${results[@]}" | jq -s '.')" \
        '{
            timestamp: $timestamp,
            target: $target,
            overall_result: (if $failed > 0 then "fail" else "pass" end),
            summary: {
                total_policies: $total_policies,
                passed: $passed,
                failed: $failed,
                compliance_percentage: (if $total_policies > 0 then (($passed * 100) / $total_policies) else 100 end)
            },
            policy_results: $policy_results
        }'
}

# ==============================================================================
# Audit Logging
# ==============================================================================

# Log policy evaluation to audit log
log_policy_evaluation() {
    local evaluation_result="$1"

    # Append to audit log (JSONL format)
    echo "$evaluation_result" >> "$POLICY_AUDIT_LOG"

    log_debug "Logged policy evaluation to audit log"
}

# Get audit log entries
get_audit_log() {
    local limit="${1:-100}"
    local filter="${2:-}"

    if [[ ! -f "$POLICY_AUDIT_LOG" ]]; then
        echo "[]"
        return
    fi

    if [[ -n "$filter" ]]; then
        tail -n "$limit" "$POLICY_AUDIT_LOG" | jq -s --arg f "$filter" '[.[] | select(tostring | contains($f))]'
    else
        tail -n "$limit" "$POLICY_AUDIT_LOG" | jq -s '.'
    fi
}

# Get policy evaluation history for a specific policy
get_policy_history() {
    local policy_id="$1"
    local limit="${2:-50}"

    if [[ ! -f "$POLICY_AUDIT_LOG" ]]; then
        echo "[]"
        return
    fi

    grep "\"policy_id\":\"$policy_id\"" "$POLICY_AUDIT_LOG" | tail -n "$limit" | jq -s '.'
}

# ==============================================================================
# Policy Management Functions
# ==============================================================================

# List all available policies
list_policies() {
    local policy_dir="${1:-$POLICY_DEFINITIONS_DIR}"

    local policies=()

    for policy_file in "$policy_dir"/*.json "$policy_dir"/*.yaml "$policy_dir"/*.yml; do
        [[ -f "$policy_file" ]] || continue

        local policy_json
        if [[ "$policy_file" == *.yaml || "$policy_file" == *.yml ]]; then
            policy_json=$(yaml_to_json "$policy_file" 2>/dev/null) || continue
        else
            policy_json=$(cat "$policy_file")
        fi

        local summary
        summary=$(echo "$policy_json" | jq '{
            policy_id: .policy_id,
            name: .name,
            version: .version,
            severity: .severity,
            enabled: (.enabled // true),
            rules_count: (.rules | length),
            frameworks: .frameworks,
            file: "'"$(basename "$policy_file")"'"
        }')

        policies+=("$summary")
    done

    printf '%s\n' "${policies[@]}" | jq -s '.'
}

# Validate a policy definition
validate_policy_definition() {
    local policy_path="$1"

    local policy_json
    if [[ "$policy_path" == *.yaml || "$policy_path" == *.yml ]]; then
        policy_json=$(yaml_to_json "$policy_path")
    else
        policy_json=$(cat "$policy_path")
    fi

    local errors=()

    # Check required fields
    local required_fields=("policy_id" "name" "version" "rules")
    for field in "${required_fields[@]}"; do
        local value
        value=$(echo "$policy_json" | jq -r ".$field // empty")
        if [[ -z "$value" ]]; then
            errors+=("Missing required field: $field")
        fi
    done

    # Validate policy_id format
    local policy_id
    policy_id=$(echo "$policy_json" | jq -r '.policy_id // ""')
    if [[ -n "$policy_id" ]] && ! echo "$policy_id" | grep -qE '^[a-z0-9-]+$'; then
        errors+=("Invalid policy_id format: must be lowercase alphanumeric with hyphens")
    fi

    # Validate version format
    local version
    version=$(echo "$policy_json" | jq -r '.version // ""')
    if [[ -n "$version" ]] && ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        errors+=("Invalid version format: must be semver (e.g., 1.0.0)")
    fi

    # Validate severity
    local severity
    severity=$(echo "$policy_json" | jq -r '.severity // ""')
    if [[ -n "$severity" ]] && ! echo "$severity" | grep -qE '^(critical|high|medium|low|info)$'; then
        errors+=("Invalid severity: must be critical, high, medium, low, or info")
    fi

    # Validate rules
    local rules_count
    rules_count=$(echo "$policy_json" | jq '.rules | length')
    if [[ "$rules_count" -eq 0 ]]; then
        errors+=("Policy must have at least one rule")
    fi

    # Validate each rule
    local rule_ids=()
    local rules
    rules=$(echo "$policy_json" | jq -c '.rules[]' 2>/dev/null)

    while IFS= read -r rule; do
        local rule_id
        rule_id=$(echo "$rule" | jq -r '.rule_id // ""')

        if [[ -z "$rule_id" ]]; then
            errors+=("Rule missing rule_id")
            continue
        fi

        # Check for duplicate rule IDs
        if [[ " ${rule_ids[*]} " =~ " ${rule_id} " ]]; then
            errors+=("Duplicate rule_id: $rule_id")
        fi
        rule_ids+=("$rule_id")

        # Check condition exists
        local has_condition
        has_condition=$(echo "$rule" | jq 'has("condition")')
        if [[ "$has_condition" != "true" ]]; then
            errors+=("Rule $rule_id missing condition")
        fi

        # Validate condition type
        local condition_type
        condition_type=$(echo "$rule" | jq -r '.condition.type // ""')
        local valid_types="equals not_equals contains not_contains regex matches greater_than less_than greater_or_equal less_or_equal in not_in exists not_exists is_type all any none"
        if [[ -n "$condition_type" ]] && ! echo "$valid_types" | grep -qw "$condition_type"; then
            errors+=("Rule $rule_id has invalid condition type: $condition_type")
        fi
    done <<< "$rules"

    # Build validation result
    if [[ ${#errors[@]} -eq 0 ]]; then
        jq -n '{
            valid: true,
            message: "Policy definition is valid",
            errors: []
        }'
        return 0
    else
        jq -n \
            --argjson errors "$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)" \
            '{
                valid: false,
                message: "Policy definition has validation errors",
                errors: $errors
            }'
        return 1
    fi
}

# ==============================================================================
# Compliance Report Generation
# ==============================================================================

# Generate compliance summary by framework
generate_compliance_summary() {
    local target_path="$1"

    # Evaluate all policies
    local results
    results=$(evaluate_all_policies "$target_path")

    # Group results by framework
    local frameworks=("nist-csf" "soc2" "owasp" "cis" "custom")
    local framework_results=()

    for framework in "${frameworks[@]}"; do
        local framework_data
        framework_data=$(echo "$results" | jq --arg fw "$framework" '
            .policy_results
            | [.[] | select(.policy.frameworks[]? == $fw)]
            | {
                framework: $fw,
                total_policies: length,
                passed: [.[] | select(.result == "pass")] | length,
                failed: [.[] | select(.result == "fail")] | length,
                compliance_percentage: (
                    if length > 0 then
                        (([.[] | select(.result == "pass")] | length) * 100 / length)
                    else 100
                    end
                )
            }
        ')
        framework_results+=("$framework_data")
    done

    # Build summary
    jq -n \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson overall "$(echo "$results" | jq '.summary')" \
        --argjson frameworks "$(printf '%s\n' "${framework_results[@]}" | jq -s '.')" \
        '{
            timestamp: $timestamp,
            overall: $overall,
            by_framework: $frameworks
        }'
}

# ==============================================================================
# Export Functions
# ==============================================================================

export -f evaluate_policy
export -f evaluate_all_policies
export -f evaluate_rule
export -f list_policies
export -f validate_policy_definition
export -f get_audit_log
export -f get_policy_history
export -f generate_compliance_summary
export -f get_policy_schema

log_info "Policy engine loaded successfully"
