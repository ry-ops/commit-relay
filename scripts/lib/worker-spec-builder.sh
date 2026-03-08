#!/bin/bash
# scripts/lib/worker-spec-builder.sh
# Worker Specification Builder - Safe worker spec creation with validation
#
# Purpose:
# - Provide safe API for creating worker specifications
# - Automatic validation before writing
# - Default values for all required fields
# - Prevents 2025-11-11 incident pattern
#
# Usage:
#   source scripts/lib/worker-spec-builder.sh
#   build_worker_spec --worker-id "worker-001" --task-id "task-123" \
#                     --worker-type "implementation-worker" \
#                     --output "path/to/spec.json"

set -eo pipefail

# Prevent re-sourcing
if [ -n "${WORKER_SPEC_BUILDER_LOADED:-}" ]; then
    return 0
fi
WORKER_SPEC_BUILDER_LOADED=1

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Simple validation functions (standalone - doesn't require full init-common.sh)
validate_json_syntax() {
    local json_data="$1"
    echo "$json_data" | jq empty 2>/dev/null
}

validate_template_vars() {
    local content="$1"
    # Check for uninitialized variable pattern
    if echo "$content" | grep -q ', ,'; then
        return 1
    fi
    return 0
}

safe_write_json() {
    local json_data="$1"
    local output_path="$2"

    # Validate JSON syntax
    if ! validate_json_syntax "$json_data"; then
        echo "ERROR: Invalid JSON syntax" >&2
        return 1
    fi

    # Validate no template variables
    if ! validate_template_vars "$json_data"; then
        echo "ERROR: Uninitialized variables detected" >&2
        return 1
    fi

    # Write atomically
    local temp_file="${output_path}.tmp.$$"
    echo "$json_data" | jq -c '.' > "$temp_file" || return 1
    mv "$temp_file" "$output_path" || return 1

    return 0
}

# Try to load full validation service if available (for schema validation)
if [ -f "$SCRIPT_DIR/validation-service.sh" ]; then
    # Set up minimal logging stubs to prevent errors
    log_debug() { :; }
    log_info() { :; }
    log_error() { echo "ERROR: $*" >&2; }

    source "$SCRIPT_DIR/validation-service.sh" 2>/dev/null || true
fi

# Default values for worker specs
DEFAULT_TOKEN_BUDGET=10000
DEFAULT_TIMEOUT_MINUTES=30
DEFAULT_MAX_RETRIES=1
DEFAULT_SCOPE="{}"
DEFAULT_CONTEXT="{}"
DEFAULT_CHECKPOINT_CRITERIA="[]"

# ============================================================================
# Checkpoint Criteria Management (Phase 3 - Item 23)
# ============================================================================

# Add checkpoint criteria to task specifications
# Enables goal decomposition with verification between steps
build_checkpoint_criteria() {
    local step_name="$1"
    local verification_type="$2"
    local success_condition="$3"
    local timeout_seconds="${4:-300}"
    local required="${5:-true}"

    jq -nc \
        --arg step "$step_name" \
        --arg type "$verification_type" \
        --arg condition "$success_condition" \
        --argjson timeout "$timeout_seconds" \
        --arg required "$required" \
        '{
            step: $step,
            verification_type: $type,
            success_condition: $condition,
            timeout_seconds: $timeout,
            required: ($required == "true"),
            validated_at: null,
            validation_result: null
        }'
}

# Validate checkpoint between steps
validate_checkpoint() {
    local spec_file="$1"
    local step_name="$2"

    if [ ! -f "$spec_file" ]; then
        echo "ERROR: Spec file not found: $spec_file" >&2
        return 1
    fi

    local checkpoint=$(jq --arg step "$step_name" '.checkpoint_criteria[] | select(.step == $step)' "$spec_file")

    if [ -z "$checkpoint" ] || [ "$checkpoint" = "null" ]; then
        echo "ERROR: Checkpoint not found for step: $step_name" >&2
        return 1
    fi

    local verification_type=$(echo "$checkpoint" | jq -r '.verification_type')
    local success_condition=$(echo "$checkpoint" | jq -r '.success_condition')
    local validation_result="false"
    local validation_message=""

    case "$verification_type" in
        "file_exists")
            if [ -f "$success_condition" ]; then
                validation_result="true"
                validation_message="File exists: $success_condition"
            else
                validation_message="File not found: $success_condition"
            fi
            ;;
        "command_success")
            if eval "$success_condition" >/dev/null 2>&1; then
                validation_result="true"
                validation_message="Command succeeded"
            else
                validation_message="Command failed: $success_condition"
            fi
            ;;
        "json_field")
            local field_path=$(echo "$success_condition" | cut -d'=' -f1)
            local expected_value=$(echo "$success_condition" | cut -d'=' -f2)
            local actual_value=$(jq -r "$field_path" "$spec_file" 2>/dev/null)
            if [ "$actual_value" = "$expected_value" ]; then
                validation_result="true"
                validation_message="Field matches: $field_path = $expected_value"
            else
                validation_message="Field mismatch: $field_path (expected: $expected_value, got: $actual_value)"
            fi
            ;;
        "custom")
            # Custom validation - success_condition is a script path
            if [ -x "$success_condition" ] && "$success_condition"; then
                validation_result="true"
                validation_message="Custom validation passed"
            else
                validation_message="Custom validation failed"
            fi
            ;;
        *)
            validation_message="Unknown verification type: $verification_type"
            ;;
    esac

    # Update the spec file with validation result
    local temp_file="${spec_file}.tmp.$$"
    jq --arg step "$step_name" \
       --arg result "$validation_result" \
       --arg message "$validation_message" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '(.checkpoint_criteria[] | select(.step == $step)) |= . + {
           validated_at: $timestamp,
           validation_result: ($result == "true"),
           validation_message: $message
       }' "$spec_file" > "$temp_file"
    mv "$temp_file" "$spec_file"

    if [ "$validation_result" = "true" ]; then
        echo "PASS: $validation_message"
        return 0
    else
        echo "FAIL: $validation_message" >&2
        return 1
    fi
}

# Get all checkpoints for a spec
get_checkpoints() {
    local spec_file="$1"

    if [ ! -f "$spec_file" ]; then
        echo "[]"
        return
    fi

    jq -c '.checkpoint_criteria // []' "$spec_file"
}

# Get configuration for worker type
get_worker_type_config() {
    local worker_type="$1"
    local config_key="$2"

    case "$worker_type" in
        implementation-worker)
            case "$config_key" in
                token_budget) echo "8000" ;;
                timeout) echo "15" ;;
                *) return 1 ;;
            esac
            ;;
        test-worker)
            case "$config_key" in
                token_budget) echo "5000" ;;
                timeout) echo "20" ;;
                *) return 1 ;;
            esac
            ;;
        documentation-worker)
            case "$config_key" in
                token_budget) echo "5000" ;;
                timeout) echo "15" ;;
                *) return 1 ;;
            esac
            ;;
        code-reviewer)
            case "$config_key" in
                token_budget) echo "10000" ;;
                timeout) echo "45" ;;
                *) return 1 ;;
            esac
            ;;
        refactoring-worker)
            case "$config_key" in
                token_budget) echo "6000" ;;
                timeout) echo "20" ;;
                *) return 1 ;;
            esac
            ;;
        debugging-worker)
            case "$config_key" in
                token_budget) echo "5000" ;;
                timeout) echo "15" ;;
                *) return 1 ;;
            esac
            ;;
        research-worker)
            case "$config_key" in
                token_budget) echo "4000" ;;
                timeout) echo "10" ;;
                *) return 1 ;;
            esac
            ;;
        integration-worker)
            case "$config_key" in
                token_budget) echo "6000" ;;
                timeout) echo "20" ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# Build worker specification
# Returns: JSON string (validated)
build_worker_spec() {
    local worker_id=""
    local worker_type=""
    local task_id=""
    local created_by="${COMMIT_RELAY_PRINCIPAL:-system}"
    local execution_manager="null"
    local scope_json="$DEFAULT_SCOPE"
    local context_json="$DEFAULT_CONTEXT"
    local token_budget=""
    local timeout_minutes=""
    local max_retries="$DEFAULT_MAX_RETRIES"
    local output_file=""
    local checkpoint_criteria="$DEFAULT_CHECKPOINT_CRITERIA"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --worker-id)
                worker_id="$2"
                shift 2
                ;;
            --worker-type)
                worker_type="$2"
                shift 2
                ;;
            --task-id)
                task_id="$2"
                shift 2
                ;;
            --created-by)
                created_by="$2"
                shift 2
                ;;
            --execution-manager)
                execution_manager="\"$2\""
                shift 2
                ;;
            --scope)
                scope_json="$2"
                shift 2
                ;;
            --context)
                context_json="$2"
                shift 2
                ;;
            --token-budget)
                token_budget="$2"
                shift 2
                ;;
            --timeout-minutes)
                timeout_minutes="$2"
                shift 2
                ;;
            --max-retries)
                max_retries="$2"
                shift 2
                ;;
            --output)
                output_file="$2"
                shift 2
                ;;
            --checkpoint-criteria)
                checkpoint_criteria="$2"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Validate required fields
    if [ -z "$worker_id" ]; then
        echo "ERROR: --worker-id is required" >&2
        return 1
    fi

    if [ -z "$worker_type" ]; then
        echo "ERROR: --worker-type is required" >&2
        return 1
    fi

    if [ -z "$task_id" ]; then
        echo "ERROR: --task-id is required" >&2
        return 1
    fi

    # Validate worker_id format
    if ! echo "$worker_id" | grep -q '^worker-[a-z]*-[0-9A-Za-z]*$'; then
        echo "ERROR: Invalid worker_id format: $worker_id" >&2
        echo "Expected: worker-<type>-<id>" >&2
        return 1
    fi

    # Get defaults from worker type config if not specified
    if [ -z "$token_budget" ]; then
        token_budget=$(get_worker_type_config "$worker_type" "token_budget" || echo "$DEFAULT_TOKEN_BUDGET")
    fi

    if [ -z "$timeout_minutes" ]; then
        timeout_minutes=$(get_worker_type_config "$worker_type" "timeout" || echo "$DEFAULT_TIMEOUT_MINUTES")
    fi

    # Validate scope and context are valid JSON
    if ! echo "$scope_json" | jq empty 2>/dev/null; then
        echo "ERROR: --scope is not valid JSON" >&2
        return 1
    fi

    if ! echo "$context_json" | jq empty 2>/dev/null; then
        echo "ERROR: --context is not valid JSON" >&2
        return 1
    fi

    # Validate checkpoint_criteria is valid JSON array
    if ! echo "$checkpoint_criteria" | jq empty 2>/dev/null; then
        echo "ERROR: --checkpoint-criteria is not valid JSON" >&2
        return 1
    fi

    # Build the worker spec JSON
    local created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local worker_spec=$(cat <<EOF
{
  "worker_id": "$worker_id",
  "worker_type": "$worker_type",
  "created_by": "$created_by",
  "execution_manager": $execution_manager,
  "created_at": "$created_at",
  "task_id": "$task_id",
  "status": "pending",
  "scope": $scope_json,
  "context": $context_json,
  "resources": {
    "token_budget": $token_budget,
    "timeout_minutes": $timeout_minutes,
    "max_retries": $max_retries
  },
  "deliverables": [],
  "prompt_template": "agents/prompts/workers/${worker_type}.md",
  "execution": {
    "started_at": null,
    "completed_at": null,
    "tokens_used": 0,
    "duration_minutes": 0,
    "session_id": null
  },
  "results": {
    "status": null,
    "output_location": null,
    "summary": null,
    "artifacts": []
  },
  "checkpoint_criteria": $checkpoint_criteria
}
EOF
)

    # Validate the generated JSON
    if ! validate_json_syntax "$worker_spec"; then
        echo "ERROR: Generated worker spec has invalid JSON syntax" >&2
        return 1
    fi

    # Validate against schema if available
    if type validate_worker_spec >/dev/null 2>&1; then
        # Create temp file for validation
        local temp_spec="/tmp/worker-spec-$$.json"
        echo "$worker_spec" | jq -c '.' > "$temp_spec"

        if ! validate_worker_spec "$temp_spec"; then
            rm -f "$temp_spec"
            echo "ERROR: Generated worker spec failed schema validation" >&2
            return 1
        fi

        rm -f "$temp_spec"
    fi

    # Write to output file if specified
    if [ -n "$output_file" ]; then
        if ! safe_write_json "$worker_spec" "$output_file"; then
            echo "ERROR: Failed to write worker spec to $output_file" >&2
            return 1
        fi
    else
        # Output to stdout (compact JSON)
        echo "$worker_spec" | jq -c '.'
    fi

    return 0
}

# Quick builder for common worker types
create_implementation_worker() {
    local worker_id="$1"
    local task_id="$2"
    local output_file="$3"

    build_worker_spec \
        --worker-id "$worker_id" \
        --worker-type "implementation-worker" \
        --task-id "$task_id" \
        --output "$output_file"
}

create_test_worker() {
    local worker_id="$1"
    local task_id="$2"
    local output_file="$3"

    build_worker_spec \
        --worker-id "$worker_id" \
        --worker-type "test-worker" \
        --task-id "$task_id" \
        --output "$output_file"
}

create_documentation_worker() {
    local worker_id="$1"
    local task_id="$2"
    local output_file="$3"

    build_worker_spec \
        --worker-id "$worker_id" \
        --worker-type "documentation-worker" \
        --task-id "$task_id" \
        --output "$output_file"
}

# Export functions
export -f build_worker_spec 2>/dev/null || true
export -f create_implementation_worker 2>/dev/null || true
export -f create_test_worker 2>/dev/null || true
export -f create_documentation_worker 2>/dev/null || true

# Log that builder is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[BUILDER] Worker spec builder loaded" >&2
fi
