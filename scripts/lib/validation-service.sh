#!/bin/bash
# validation-service.sh - Systematic validation for all commit-relay operations
# Prevents the 2025-11-11 incident (malformed JSON paralysis) from ever happening again
#
# Core Functions:
# - safe_write_json: Validates JSON before writing (prevents malformed data)
# - validate_json_schema: Validates against JSON schemas
# - validate_template_vars: Ensures no uninitialized variables
# - validate_worker_spec: Comprehensive worker spec validation
# - validate_required_fields: Ensures critical fields are present
#
# Usage:
#   source scripts/lib/validation-service.sh
#   safe_write_json "$json_data" "$output_path" "$schema_name"

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SCHEMAS_DIR="${SCHEMAS_DIR:-$COMMIT_RELAY_HOME/coordination/schemas}"
VALIDATION_ENABLED="${VALIDATION_ENABLED:-true}"

# ==============================================================================
# Core Validation Functions
# ==============================================================================

# Validate JSON syntax
validate_json_syntax() {
  local json_data="$1"

  if [ -z "$json_data" ]; then
    log_error "validate_json_syntax: Empty JSON data provided"
    return 1
  fi

  # Check if jq is available
  if ! command -v jq &> /dev/null; then
    log_error "validate_json_syntax: jq not found, cannot validate JSON"
    return 1
  fi

  # Validate with jq
  if ! echo "$json_data" | jq empty 2>/dev/null; then
    log_error "validate_json_syntax: Invalid JSON syntax"
    log_error "JSON data: ${json_data:0:200}..."  # First 200 chars for debugging
    return 1
  fi

  return 0
}

# Validate JSON against a schema
validate_json_schema() {
  local json_data="$1"
  local schema_name="$2"

  # If schema is "none" or empty, skip schema validation
  if [ -z "$schema_name" ] || [ "$schema_name" = "none" ]; then
    log_debug "validate_json_schema: No schema specified, skipping schema validation"
    return 0
  fi

  local schema_file="$SCHEMAS_DIR/${schema_name}.json"

  # Check if schema file exists
  if [ ! -f "$schema_file" ]; then
    log_warn "validate_json_schema: Schema file not found: $schema_file"
    log_warn "Skipping schema validation for: $schema_name"
    return 0  # Don't fail if schema doesn't exist yet (graceful degradation)
  fi

  # TODO: Implement proper JSON schema validation
  # For now, we'll do basic structure validation
  log_debug "validate_json_schema: Schema validation for $schema_name (basic check)"

  # Basic validation: ensure it's valid JSON
  if ! validate_json_syntax "$json_data"; then
    return 1
  fi

  return 0
}

# Validate that template variables are initialized (no ", ," patterns)
validate_template_vars() {
  local content="$1"

  # Check for uninitialized variable patterns
  # Pattern 1: ", ," (comma-space-comma indicates missing value)
  if echo "$content" | grep -q ', ,'; then
    log_error "validate_template_vars: Uninitialized variable detected (pattern: ', ,')"
    log_error "This indicates a variable was not set before JSON generation"

    # Show the problematic lines
    local problematic_lines
    problematic_lines=$(echo "$content" | grep -n ', ,' || echo "")
    if [ -n "$problematic_lines" ]; then
      log_error "Problematic lines:"
      echo "$problematic_lines" | head -5 >&2
    fi

    return 1
  fi

  # Pattern 2: ": ," (colon-space-comma indicates missing value)
  if echo "$content" | grep -q ': ,'; then
    log_error "validate_template_vars: Uninitialized variable detected (pattern: ': ,')"
    return 1
  fi

  # Pattern 3: ":," (colon-comma indicates missing value)
  if echo "$content" | grep -q ':,'; then
    log_error "validate_template_vars: Uninitialized variable detected (pattern: ':,')"
    return 1
  fi

  return 0
}

# Validate required fields are present and non-null
validate_required_fields() {
  local json_data="$1"
  shift
  local required_fields=("$@")

  local errors=0

  for field in "${required_fields[@]}"; do
    # Check if field exists and is not null
    local value
    value=$(echo "$json_data" | jq -r ".$field // empty" 2>/dev/null)

    if [ -z "$value" ] || [ "$value" = "null" ]; then
      log_error "validate_required_fields: Required field missing or null: $field"
      ((errors++))
    fi
  done

  if [ $errors -gt 0 ]; then
    log_error "validate_required_fields: $errors required fields missing or null"
    return 1
  fi

  return 0
}

# Validate value constraints (type, range, format)
validate_value_constraints() {
  local json_data="$1"
  local field="$2"
  local constraint_type="$3"
  local constraint_value="$4"

  local value
  value=$(echo "$json_data" | jq -r ".$field // empty" 2>/dev/null)

  case "$constraint_type" in
    "type")
      # Validate type (string, number, boolean, array, object)
      local actual_type
      actual_type=$(echo "$json_data" | jq -r ".$field | type" 2>/dev/null)

      if [ "$actual_type" != "$constraint_value" ]; then
        log_error "validate_value_constraints: Field '$field' has wrong type (expected: $constraint_value, got: $actual_type)"
        return 1
      fi
      ;;

    "min")
      # Validate minimum value for numbers
      if [ -z "$value" ] || [ "$value" = "null" ]; then
        return 0  # Skip if value is not present
      fi

      if [ "$(echo "$value < $constraint_value" | bc 2>/dev/null)" -eq 1 ]; then
        log_error "validate_value_constraints: Field '$field' below minimum (min: $constraint_value, got: $value)"
        return 1
      fi
      ;;

    "max")
      # Validate maximum value for numbers
      if [ -z "$value" ] || [ "$value" = "null" ]; then
        return 0  # Skip if value is not present
      fi

      if [ "$(echo "$value > $constraint_value" | bc 2>/dev/null)" -eq 1 ]; then
        log_error "validate_value_constraints: Field '$field' exceeds maximum (max: $constraint_value, got: $value)"
        return 1
      fi
      ;;

    "pattern")
      # Validate string pattern (regex)
      if [ -z "$value" ] || [ "$value" = "null" ]; then
        return 0  # Skip if value is not present
      fi

      if ! echo "$value" | grep -qE "$constraint_value"; then
        log_error "validate_value_constraints: Field '$field' doesn't match pattern: $constraint_value"
        return 1
      fi
      ;;

    *)
      log_warn "validate_value_constraints: Unknown constraint type: $constraint_type"
      ;;
  esac

  return 0
}

# ==============================================================================
# High-Level Validation Functions
# ==============================================================================

# Safe JSON write - validates before writing
safe_write_json() {
  local json_data="$1"
  local output_path="$2"
  local schema_name="${3:-none}"

  if [ "$VALIDATION_ENABLED" != "true" ]; then
    log_warn "safe_write_json: Validation disabled, writing without checks"
    echo "$json_data" > "$output_path"
    return 0
  fi

  log_debug "safe_write_json: Validating JSON for $output_path (schema: $schema_name)"

  # Step 1: Validate JSON syntax
  if ! validate_json_syntax "$json_data"; then
    log_error "safe_write_json: JSON syntax validation failed for $output_path"
    trace_event "validation.failed" "error" "{\"file\":\"$output_path\",\"reason\":\"invalid_syntax\"}"
    return 1
  fi

  # Step 2: Validate template variables (no uninitialized)
  if ! validate_template_vars "$json_data"; then
    log_error "safe_write_json: Template variable validation failed for $output_path"
    trace_event "validation.failed" "error" "{\"file\":\"$output_path\",\"reason\":\"uninitialized_variables\"}"
    return 1
  fi

  # Step 3: Validate against schema (if provided)
  if ! validate_json_schema "$json_data" "$schema_name"; then
    log_error "safe_write_json: Schema validation failed for $output_path"
    trace_event "validation.failed" "error" "{\"file\":\"$output_path\",\"reason\":\"schema_mismatch\",\"schema\":\"$schema_name\"}"
    return 1
  fi

  # Step 4: Atomic write (write to temp file, then move)
  local temp_file
  temp_file=$(mktemp) || {
    log_error "safe_write_json: Failed to create temp file"
    return 1
  }

  echo "$json_data" > "$temp_file" || {
    log_error "safe_write_json: Failed to write to temp file"
    rm -f "$temp_file"
    return 1
  }

  # Move temp file to final location
  mv "$temp_file" "$output_path" || {
    log_error "safe_write_json: Failed to move temp file to $output_path"
    rm -f "$temp_file"
    return 1
  }

  log_info "✅ Validated JSON written: $output_path"
  trace_event "validation.success" "success" "{\"file\":\"$output_path\",\"schema\":\"$schema_name\"}"

  return 0
}

# Validate worker spec (comprehensive check)
validate_worker_spec() {
  local spec_path="$1"

  log_debug "validate_worker_spec: Validating $spec_path"

  # Check file exists
  if [ ! -f "$spec_path" ]; then
    log_error "validate_worker_spec: Worker spec not found: $spec_path"
    return 1
  fi

  # Read spec
  local spec_content
  spec_content=$(cat "$spec_path")

  # Validate JSON syntax
  if ! validate_json_syntax "$spec_content"; then
    log_error "validate_worker_spec: Invalid JSON in worker spec: $spec_path"
    return 1
  fi

  # Validate required fields
  local required_fields=(
    "worker_id"
    "worker_type"
    "task_id"
    "status"
  )

  if ! validate_required_fields "$spec_content" "${required_fields[@]}"; then
    log_error "validate_worker_spec: Required fields missing in: $spec_path"
    return 1
  fi

  # Validate worker_id format (should be worker-{type}-{id})
  local worker_id
  worker_id=$(echo "$spec_content" | jq -r '.worker_id')

  if ! echo "$worker_id" | grep -qE '^worker-[a-z]+-[0-9A-Za-z]+$'; then
    log_error "validate_worker_spec: Invalid worker_id format: $worker_id"
    log_error "Expected format: worker-{type}-{id}"
    return 1
  fi

  # Validate status is a valid value
  local status
  status=$(echo "$spec_content" | jq -r '.status')

  case "$status" in
    pending|running|completed|failed)
      # Valid status
      ;;
    *)
      log_error "validate_worker_spec: Invalid status: $status"
      log_error "Valid statuses: pending, running, completed, failed"
      return 1
      ;;
  esac

  # Validate token budget (if present)
  local token_budget
  token_budget=$(echo "$spec_content" | jq -r '.resources.token_budget // empty' 2>/dev/null)

  if [ -n "$token_budget" ] && [ "$token_budget" != "null" ]; then
    if [ "$token_budget" -lt 0 ]; then
      log_error "validate_worker_spec: Invalid token_budget: $token_budget (must be >= 0)"
      return 1
    fi

    if [ "$token_budget" -gt 200000 ]; then
      log_warn "validate_worker_spec: Very high token_budget: $token_budget (>200k)"
    fi
  fi

  log_info "✅ Worker spec validation passed: $spec_path"
  return 0
}

# Validate task spec
validate_task_spec() {
  local spec_path="$1"

  log_debug "validate_task_spec: Validating $spec_path"

  # Check file exists
  if [ ! -f "$spec_path" ]; then
    log_error "validate_task_spec: Task spec not found: $spec_path"
    return 1
  fi

  # Read spec
  local spec_content
  spec_content=$(cat "$spec_path")

  # Validate JSON syntax
  if ! validate_json_syntax "$spec_content"; then
    log_error "validate_task_spec: Invalid JSON in task spec: $spec_path"
    return 1
  fi

  # Validate required fields
  local required_fields=(
    "id"
    "title"
    "type"
    "priority"
    "status"
  )

  if ! validate_required_fields "$spec_content" "${required_fields[@]}"; then
    log_error "validate_task_spec: Required fields missing in: $spec_path"
    return 1
  fi

  log_info "✅ Task spec validation passed: $spec_path"
  return 0
}

# ==============================================================================
# Compliance Validation
# ==============================================================================

# Governance rules file
GOVERNANCE_RULES_FILE="${GOVERNANCE_RULES_FILE:-$COMMIT_RELAY_HOME/coordination/policies/governance-rules.json}"

# Validate compliance with governance rules
validate_compliance() {
  local worker_spec_path="$1"

  if [ "$VALIDATION_ENABLED" != "true" ]; then
    return 0
  fi

  log_debug "validate_compliance: Checking governance rules for $worker_spec_path"

  local errors=0
  local warnings=0

  # Read worker spec
  local spec_content
  spec_content=$(cat "$worker_spec_path" 2>/dev/null)

  if [ -z "$spec_content" ]; then
    log_error "validate_compliance: Cannot read worker spec"
    return 1
  fi

  local worker_type=$(echo "$spec_content" | jq -r '.worker_type // "unknown"')
  local worker_id=$(echo "$spec_content" | jq -r '.worker_id // "unknown"')
  local task_type=$(echo "$spec_content" | jq -r '.task.type // "unknown"')

  # Rule 1: Check resource limits
  local token_budget=$(echo "$spec_content" | jq -r '.resources.token_budget // 0')
  local max_tokens=200000  # Default max

  if [ -f "$GOVERNANCE_RULES_FILE" ]; then
    max_tokens=$(jq -r ".resource_limits.max_tokens_per_worker // 200000" "$GOVERNANCE_RULES_FILE")
  fi

  if [ "$token_budget" -gt "$max_tokens" ]; then
    log_error "validate_compliance: Token budget ($token_budget) exceeds maximum ($max_tokens)"
    ((errors++))
  fi

  # Rule 2: Check time limits
  local time_limit=$(echo "$spec_content" | jq -r '.resources.time_limit_minutes // 0')
  local max_time=120  # Default 2 hours

  if [ -f "$GOVERNANCE_RULES_FILE" ]; then
    max_time=$(jq -r ".resource_limits.max_time_minutes // 120" "$GOVERNANCE_RULES_FILE")
  fi

  if [ "$time_limit" -gt "$max_time" ]; then
    log_error "validate_compliance: Time limit ($time_limit min) exceeds maximum ($max_time min)"
    ((errors++))
  fi

  # Rule 3: Check restricted operations
  local task_operations=$(echo "$spec_content" | jq -r '.task.operations // [] | .[]' 2>/dev/null)

  if [ -f "$GOVERNANCE_RULES_FILE" ]; then
    local restricted_ops=$(jq -r '.restricted_operations // [] | .[]' "$GOVERNANCE_RULES_FILE")

    for op in $task_operations; do
      if echo "$restricted_ops" | grep -q "^${op}$"; then
        log_error "validate_compliance: Operation '$op' is restricted by governance policy"
        ((errors++))
      fi
    done
  fi

  # Rule 4: Check sensitive data access
  local data_access=$(echo "$spec_content" | jq -r '.permissions.data_access // [] | .[]' 2>/dev/null)

  for data_type in $data_access; do
    case "$data_type" in
      pii|credentials|secrets|financial)
        # Check if worker type is authorized for sensitive data
        local authorized="false"
        if [ -f "$GOVERNANCE_RULES_FILE" ]; then
          authorized=$(jq -r --arg wt "$worker_type" --arg dt "$data_type" \
            '.sensitive_data_access[$dt] // [] | any(. == $wt)' "$GOVERNANCE_RULES_FILE")
        fi

        if [ "$authorized" != "true" ]; then
          log_error "validate_compliance: Worker type '$worker_type' not authorized for '$data_type' access"
          ((errors++))
        fi
        ;;
    esac
  done

  # Rule 5: Check audit requirements
  local requires_audit="false"
  if [ -f "$GOVERNANCE_RULES_FILE" ]; then
    requires_audit=$(jq -r --arg tt "$task_type" \
      '.audit_required_task_types // [] | any(. == $tt)' "$GOVERNANCE_RULES_FILE")
  fi

  if [ "$requires_audit" == "true" ]; then
    local has_audit_trail=$(echo "$spec_content" | jq -r '.audit.enabled // false')
    if [ "$has_audit_trail" != "true" ]; then
      log_warn "validate_compliance: Task type '$task_type' requires audit trail, but not enabled"
      ((warnings++))
    fi
  fi

  # Rule 6: Check approval requirements
  local requires_approval="false"
  if [ -f "$COMMIT_RELAY_HOME/coordination/policies/approval-required.json" ]; then
    requires_approval=$(jq -r --arg wt "$worker_type" --arg tt "$task_type" \
      '.operations[] | select(.worker_types | any(. == $wt) or .task_types | any(. == $tt)) | .name' \
      "$COMMIT_RELAY_HOME/coordination/policies/approval-required.json" 2>/dev/null | head -1)
  fi

  if [ -n "$requires_approval" ]; then
    local approval_id=$(echo "$spec_content" | jq -r '.approval.approval_id // empty')
    if [ -z "$approval_id" ]; then
      log_error "validate_compliance: Operation requires approval but no approval_id provided"
      ((errors++))
    else
      # Verify approval exists and is valid
      local approval_file="$COMMIT_RELAY_HOME/coordination/approvals/approved/${approval_id}.json"
      if [ ! -f "$approval_file" ]; then
        log_error "validate_compliance: Approval $approval_id not found or not approved"
        ((errors++))
      fi
    fi
  fi

  # Rule 7: Check concurrent worker limits
  if [ -f "$GOVERNANCE_RULES_FILE" ]; then
    local max_concurrent=$(jq -r --arg wt "$worker_type" \
      '.concurrent_limits[$wt] // .concurrent_limits.default // 10' "$GOVERNANCE_RULES_FILE")

    local current_count=$(find "$COMMIT_RELAY_HOME/coordination/worker-specs/active" \
      -name "worker-${worker_type}-*.json" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$current_count" -ge "$max_concurrent" ]; then
      log_error "validate_compliance: Concurrent worker limit reached for '$worker_type' (max: $max_concurrent)"
      ((errors++))
    fi
  fi

  # Log compliance check result
  if [ $errors -gt 0 ]; then
    log_error "validate_compliance: Failed with $errors errors and $warnings warnings"
    trace_event "compliance.failed" "error" "{\"worker_id\":\"$worker_id\",\"errors\":$errors,\"warnings\":$warnings}"
    return 1
  fi

  if [ $warnings -gt 0 ]; then
    log_warn "validate_compliance: Passed with $warnings warnings"
  fi

  log_info "✅ Compliance validation passed for $worker_id"
  trace_event "compliance.passed" "success" "{\"worker_id\":\"$worker_id\",\"warnings\":$warnings}"
  return 0
}

# ==============================================================================
# Pre-Flight Checks
# ==============================================================================

# Pre-flight checks before spawning a worker
pre_flight_checks() {
  local worker_spec_path="$1"

  log_info "Running pre-flight checks for worker spawn..."

  local errors=0

  # Check 1: Worker spec is valid
  if ! validate_worker_spec "$worker_spec_path"; then
    log_error "Pre-flight check failed: Invalid worker spec"
    ((errors++))
  fi

  # Check 2: Task exists in task queue
  local task_id
  task_id=$(jq -r '.task_id' "$worker_spec_path" 2>/dev/null)

  if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
    local task_exists
    task_exists=$(jq --arg tid "$task_id" '.tasks[] | select(.id == $tid) | .id' \
      "$COMMIT_RELAY_HOME/coordination/task-queue.json" 2>/dev/null || echo "")

    if [ -z "$task_exists" ]; then
      log_error "Pre-flight check failed: Task not found in queue: $task_id"
      ((errors++))
    fi
  fi

  # Check 3: Worker type is registered
  local worker_type
  worker_type=$(jq -r '.worker_type' "$worker_spec_path" 2>/dev/null)

  if [ -n "$worker_type" ] && [ "$worker_type" != "null" ]; then
    local type_exists
    type_exists=$(jq --arg wt "$worker_type" '.worker_types[$wt] // empty' \
      "$COMMIT_RELAY_HOME/agents/configs/agent-registry.json" 2>/dev/null || echo "")

    if [ -z "$type_exists" ]; then
      log_warn "Pre-flight check warning: Worker type not in registry: $worker_type"
    fi
  fi

  # Check 4: Token budget is available
  local token_budget
  token_budget=$(jq -r '.resources.token_budget // 0' "$worker_spec_path" 2>/dev/null)

  if [ "$token_budget" -gt 0 ]; then
    local available_tokens
    available_tokens=$(jq -r '.remaining // 0' \
      "$COMMIT_RELAY_HOME/coordination/token-budget.json" 2>/dev/null || echo "0")

    if [ "$available_tokens" -lt "$token_budget" ]; then
      log_warn "Pre-flight check warning: Insufficient token budget (need: $token_budget, available: $available_tokens)"
    fi
  fi

  # Check 5: Compliance validation (NEW)
  if ! validate_compliance "$worker_spec_path"; then
    log_error "Pre-flight check failed: Compliance validation failed"
    ((errors++))
  fi

  if [ $errors -gt 0 ]; then
    log_error "❌ Pre-flight checks failed with $errors errors"
    return 1
  fi

  log_info "✅ Pre-flight checks passed"
  return 0
}

# ==============================================================================
# Export Functions
# ==============================================================================

# Make functions available to scripts
export -f validate_json_syntax 2>/dev/null || true
export -f validate_json_schema 2>/dev/null || true
export -f validate_template_vars 2>/dev/null || true
export -f validate_required_fields 2>/dev/null || true
export -f validate_value_constraints 2>/dev/null || true
export -f safe_write_json 2>/dev/null || true
export -f validate_worker_spec 2>/dev/null || true
export -f validate_task_spec 2>/dev/null || true
export -f validate_compliance 2>/dev/null || true
export -f pre_flight_checks 2>/dev/null || true

log_debug "Validation service loaded successfully"
