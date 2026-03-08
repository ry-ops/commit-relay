#!/bin/bash
# scripts/lib/step-verifier.sh
# Step Verifier Library - Phase 3 Item 37
# Verification criteria per step in task specifications
#
# Features:
#   - Define success criteria per step
#   - Validate before proceeding to next step
#   - Rollback on verification failure
#   - Progress tracking
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/step-verifier.sh"
#   verify_step "$spec_file" "step-1"
#   progress=$(get_verification_progress "$spec_file")

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Verification configuration
VERIFIER_CONFIG="${COMMIT_RELAY_HOME}/coordination/config/step-verifier.json"
VERIFICATION_HISTORY="${COMMIT_RELAY_HOME}/coordination/metrics/verification-history.jsonl"
VERIFICATION_EVENTS="${COMMIT_RELAY_HOME}/coordination/events/verification-events.jsonl"

# Create directories
mkdir -p "$(dirname "$VERIFIER_CONFIG")"
mkdir -p "$(dirname "$VERIFICATION_HISTORY")"
mkdir -p "$(dirname "$VERIFICATION_EVENTS")"

# ============================================================================
# Logging
# ============================================================================

log_verifier() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [VERIFIER] [$level] $*" >&2
}

# ============================================================================
# Initialize Configuration
# ============================================================================

initialize_verifier_config() {
    if [ ! -f "$VERIFIER_CONFIG" ]; then
        cat > "$VERIFIER_CONFIG" <<'EOF'
{
  "version": "1.0.0",
  "verification_types": {
    "file_exists": {
      "description": "Check if a file exists",
      "params": ["path"]
    },
    "file_contains": {
      "description": "Check if file contains text",
      "params": ["path", "pattern"]
    },
    "command_succeeds": {
      "description": "Run command and check exit code",
      "params": ["command"]
    },
    "command_output": {
      "description": "Run command and check output",
      "params": ["command", "expected_pattern"]
    },
    "json_field": {
      "description": "Check JSON field value",
      "params": ["path", "field", "expected"]
    },
    "http_status": {
      "description": "Check HTTP endpoint status",
      "params": ["url", "expected_status"]
    },
    "tests_pass": {
      "description": "Run test suite and check results",
      "params": ["test_command"]
    },
    "custom_script": {
      "description": "Run custom verification script",
      "params": ["script_path"]
    }
  },
  "defaults": {
    "timeout_seconds": 60,
    "retry_count": 3,
    "retry_delay_seconds": 5,
    "fail_fast": false,
    "continue_on_optional_failure": true
  },
  "rollback": {
    "enabled": true,
    "on_failure": "previous_step",
    "preserve_logs": true
  }
}
EOF
        log_verifier "INFO" "Created default verifier config"
    fi
}

initialize_verifier_config

# ============================================================================
# Verification Functions by Type
# ============================================================================

# Verify file exists
verify_file_exists() {
    local path="$1"

    if [ -f "$path" ]; then
        echo "pass|File exists: $path"
        return 0
    else
        echo "fail|File not found: $path"
        return 1
    fi
}

# Verify file contains pattern
verify_file_contains() {
    local path="$1"
    local pattern="$2"

    if [ ! -f "$path" ]; then
        echo "fail|File not found: $path"
        return 1
    fi

    if grep -q "$pattern" "$path"; then
        echo "pass|Pattern found in file"
        return 0
    else
        echo "fail|Pattern not found: $pattern"
        return 1
    fi
}

# Verify command succeeds
verify_command_succeeds() {
    local command="$1"
    local timeout=$(jq -r '.defaults.timeout_seconds' "$VERIFIER_CONFIG")

    if timeout "$timeout" bash -c "$command" >/dev/null 2>&1; then
        echo "pass|Command succeeded"
        return 0
    else
        echo "fail|Command failed: $command"
        return 1
    fi
}

# Verify command output matches pattern
verify_command_output() {
    local command="$1"
    local expected_pattern="$2"
    local timeout=$(jq -r '.defaults.timeout_seconds' "$VERIFIER_CONFIG")

    local output
    output=$(timeout "$timeout" bash -c "$command" 2>&1) || true

    if echo "$output" | grep -q "$expected_pattern"; then
        echo "pass|Output matches expected pattern"
        return 0
    else
        echo "fail|Output does not match pattern: $expected_pattern"
        return 1
    fi
}

# Verify JSON field value
verify_json_field() {
    local json_path="$1"
    local field="$2"
    local expected="$3"

    if [ ! -f "$json_path" ]; then
        echo "fail|JSON file not found: $json_path"
        return 1
    fi

    local actual
    actual=$(jq -r "$field" "$json_path" 2>/dev/null)

    if [ "$actual" = "$expected" ]; then
        echo "pass|Field $field = $expected"
        return 0
    else
        echo "fail|Field $field: expected '$expected', got '$actual'"
        return 1
    fi
}

# Verify HTTP status
verify_http_status() {
    local url="$1"
    local expected_status="$2"
    local timeout=$(jq -r '.defaults.timeout_seconds' "$VERIFIER_CONFIG")

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" "$url" 2>/dev/null) || status="000"

    if [ "$status" = "$expected_status" ]; then
        echo "pass|HTTP status $status"
        return 0
    else
        echo "fail|HTTP status: expected $expected_status, got $status"
        return 1
    fi
}

# Verify tests pass
verify_tests_pass() {
    local test_command="$1"
    local timeout=$(jq -r '.defaults.timeout_seconds' "$VERIFIER_CONFIG")

    local output
    local exit_code=0
    output=$(timeout "$timeout" bash -c "$test_command" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "pass|Tests passed"
        return 0
    else
        echo "fail|Tests failed with exit code $exit_code"
        return 1
    fi
}

# Verify custom script
verify_custom_script() {
    local script_path="$1"

    if [ ! -x "$script_path" ]; then
        echo "fail|Script not found or not executable: $script_path"
        return 1
    fi

    local output
    local exit_code=0
    output=$("$script_path" 2>&1) || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        echo "pass|Custom verification passed"
        return 0
    else
        echo "fail|Custom verification failed: $output"
        return 1
    fi
}

# ============================================================================
# Core Verification Logic
# ============================================================================

# Execute a single verification criterion
execute_verification() {
    local verification_type="$1"
    shift
    local params=("$@")

    local result
    local exit_code=0

    case "$verification_type" in
        "file_exists")
            result=$(verify_file_exists "${params[0]}") || exit_code=$?
            ;;
        "file_contains")
            result=$(verify_file_contains "${params[0]}" "${params[1]}") || exit_code=$?
            ;;
        "command_succeeds")
            result=$(verify_command_succeeds "${params[0]}") || exit_code=$?
            ;;
        "command_output")
            result=$(verify_command_output "${params[0]}" "${params[1]}") || exit_code=$?
            ;;
        "json_field")
            result=$(verify_json_field "${params[0]}" "${params[1]}" "${params[2]}") || exit_code=$?
            ;;
        "http_status")
            result=$(verify_http_status "${params[0]}" "${params[1]}") || exit_code=$?
            ;;
        "tests_pass")
            result=$(verify_tests_pass "${params[0]}") || exit_code=$?
            ;;
        "custom_script")
            result=$(verify_custom_script "${params[0]}") || exit_code=$?
            ;;
        *)
            result="fail|Unknown verification type: $verification_type"
            exit_code=1
            ;;
    esac

    local status=$(echo "$result" | cut -d'|' -f1)
    local message=$(echo "$result" | cut -d'|' -f2-)

    jq -nc \
        --arg type "$verification_type" \
        --arg status "$status" \
        --arg message "$message" \
        --argjson exit_code "$exit_code" \
        '{
            type: $type,
            status: $status,
            message: $message,
            exit_code: $exit_code
        }'
}

# Verify a single step
verify_step() {
    local spec_file="$1"
    local step_id="$2"

    if [ ! -f "$spec_file" ]; then
        log_verifier "ERROR" "Spec file not found: $spec_file"
        return 1
    fi

    log_verifier "INFO" "Verifying step: $step_id"

    # Get step verification criteria
    local step_config=$(jq --arg id "$step_id" '.steps[] | select(.step_id == $id)' "$spec_file" 2>/dev/null)

    if [ -z "$step_config" ] || [ "$step_config" = "null" ]; then
        # Try checkpoint_criteria format
        step_config=$(jq --arg id "$step_id" '.checkpoint_criteria[] | select(.step == $id)' "$spec_file" 2>/dev/null)
    fi

    if [ -z "$step_config" ] || [ "$step_config" = "null" ]; then
        log_verifier "ERROR" "Step not found: $step_id"
        return 1
    fi

    local verification_type=$(echo "$step_config" | jq -r '.verification_type // .type')
    local is_required=$(echo "$step_config" | jq -r '.required // true')
    local criteria=$(echo "$step_config" | jq -r '.success_condition // .criteria')

    # Parse criteria into params
    local params=()
    if echo "$criteria" | grep -q '|'; then
        IFS='|' read -ra params <<< "$criteria"
    else
        params=("$criteria")
    fi

    # Execute verification with retries
    local retry_count=$(jq -r '.defaults.retry_count' "$VERIFIER_CONFIG")
    local retry_delay=$(jq -r '.defaults.retry_delay_seconds' "$VERIFIER_CONFIG")

    local attempt=0
    local result
    local final_status="fail"

    while [ "$attempt" -lt "$retry_count" ]; do
        ((attempt++))

        result=$(execute_verification "$verification_type" "${params[@]}")
        final_status=$(echo "$result" | jq -r '.status')

        if [ "$final_status" = "pass" ]; then
            break
        fi

        if [ "$attempt" -lt "$retry_count" ]; then
            log_verifier "WARN" "Verification attempt $attempt failed, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
        fi
    done

    # Update spec file with result
    local temp_file="${spec_file}.tmp"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Try both step formats
    jq --arg id "$step_id" \
       --arg status "$final_status" \
       --arg timestamp "$timestamp" \
       --argjson attempts "$attempt" \
       '
        if .steps then
            .steps = [.steps[] | if .step_id == $id then . + {
                verified_at: $timestamp,
                verification_status: $status,
                attempts: $attempts
            } else . end]
        elif .checkpoint_criteria then
            .checkpoint_criteria = [.checkpoint_criteria[] | if .step == $id then . + {
                validated_at: $timestamp,
                validation_result: ($status == "pass"),
                attempts: $attempts
            } else . end]
        else . end
       ' "$spec_file" > "$temp_file"
    mv "$temp_file" "$spec_file"

    # Record to history
    local history_entry=$(jq -nc \
        --arg spec "$spec_file" \
        --arg step "$step_id" \
        --arg status "$final_status" \
        --argjson attempts "$attempt" \
        --arg timestamp "$timestamp" \
        '{
            spec_file: $spec,
            step_id: $step,
            status: $status,
            attempts: $attempts,
            verified_at: $timestamp
        }')

    echo "$history_entry" >> "$VERIFICATION_HISTORY"

    # Emit event
    emit_verification_event "step_verified" "$step_id" "$result"

    # Determine return code
    if [ "$final_status" = "pass" ]; then
        log_verifier "INFO" "Step $step_id: PASSED"
        echo "$result"
        return 0
    elif [ "$is_required" = "false" ]; then
        log_verifier "WARN" "Step $step_id: FAILED (optional)"
        echo "$result"
        return 0
    else
        log_verifier "ERROR" "Step $step_id: FAILED"
        echo "$result"
        return 1
    fi
}

# Verify all steps in sequence
verify_all_steps() {
    local spec_file="$1"
    local stop_on_failure="${2:-true}"

    if [ ! -f "$spec_file" ]; then
        log_verifier "ERROR" "Spec file not found: $spec_file"
        return 1
    fi

    log_verifier "INFO" "Verifying all steps in: $spec_file"

    # Get all steps
    local steps=$(jq -r '.steps[]?.step_id // .checkpoint_criteria[]?.step' "$spec_file" 2>/dev/null)

    if [ -z "$steps" ]; then
        log_verifier "WARN" "No steps found in spec"
        return 0
    fi

    local passed=0
    local failed=0
    local results="[]"

    while IFS= read -r step_id; do
        [ -z "$step_id" ] && continue

        local result
        local exit_code=0
        result=$(verify_step "$spec_file" "$step_id") || exit_code=$?

        results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')

        if [ "$exit_code" -eq 0 ]; then
            ((passed++))
        else
            ((failed++))
            if [ "$stop_on_failure" = "true" ]; then
                log_verifier "ERROR" "Stopping on failure at step: $step_id"
                break
            fi
        fi
    done <<< "$steps"

    # Build summary
    local summary=$(jq -nc \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson total "$((passed + failed))" \
        --argjson results "$results" \
        '{
            total_steps: $total,
            passed: $passed,
            failed: $failed,
            success_rate: (if $total > 0 then ($passed / $total * 100 | floor) else 0 end),
            results: $results
        }')

    log_verifier "INFO" "Verification complete: $passed passed, $failed failed"

    echo "$summary"

    if [ "$failed" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Progress Tracking
# ============================================================================

# Get verification progress for a spec
get_verification_progress() {
    local spec_file="$1"

    if [ ! -f "$spec_file" ]; then
        echo '{"error":"Spec file not found"}'
        return 1
    fi

    # Count steps and their statuses
    local total=0
    local verified=0
    local passed=0

    local steps=$(jq -r '.steps // .checkpoint_criteria // []' "$spec_file")
    total=$(echo "$steps" | jq 'length')

    if [ "$total" -eq 0 ]; then
        echo '{"total":0,"verified":0,"passed":0,"progress_percent":0}'
        return
    fi

    # Check for verified steps
    verified=$(echo "$steps" | jq '[.[] | select(.verified_at != null or .validated_at != null)] | length')
    passed=$(echo "$steps" | jq '[.[] | select(.verification_status == "pass" or .validation_result == true)] | length')

    local progress=0
    if [ "$total" -gt 0 ]; then
        progress=$(echo "scale=0; $verified * 100 / $total" | bc)
    fi

    jq -nc \
        --argjson total "$total" \
        --argjson verified "$verified" \
        --argjson passed "$passed" \
        --argjson progress "$progress" \
        '{
            total_steps: $total,
            verified_steps: $verified,
            passed_steps: $passed,
            progress_percent: $progress
        }'
}

# ============================================================================
# Event Emission
# ============================================================================

emit_verification_event() {
    local event_type="$1"
    local step_id="$2"
    local data="${3:-{}}"

    local event=$(jq -nc \
        --arg type "$event_type" \
        --arg step "$step_id" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson data "$data" \
        '{
            event_type: $type,
            step_id: $step,
            timestamp: $timestamp,
            data: $data
        }')

    echo "$event" >> "$VERIFICATION_EVENTS"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Add verification criteria to a step
add_step_verification() {
    local spec_file="$1"
    local step_id="$2"
    local verification_type="$3"
    local criteria="$4"
    local required="${5:-true}"

    local temp_file="${spec_file}.tmp"

    jq --arg id "$step_id" \
       --arg type "$verification_type" \
       --arg criteria "$criteria" \
       --arg required "$required" \
       '.steps = (.steps // []) + [{
           step_id: $id,
           verification_type: $type,
           criteria: $criteria,
           required: ($required == "true"),
           verified_at: null,
           verification_status: null
       }]' "$spec_file" > "$temp_file"
    mv "$temp_file" "$spec_file"

    log_verifier "INFO" "Added verification for step: $step_id"
}

# Export functions
export -f verify_step 2>/dev/null || true
export -f verify_all_steps 2>/dev/null || true
export -f get_verification_progress 2>/dev/null || true
export -f add_step_verification 2>/dev/null || true
export -f execute_verification 2>/dev/null || true

log_verifier "INFO" "Step verifier library loaded"
