#!/bin/bash
# init-common.sh - Mandatory initialization for all commit-relay scripts
# This file provides a single entry point for loading all core services
# and enforcing core principles (observability, validation, governance, etc.)
#
# Usage in any script:
#   source "$(dirname "$0")/lib/init-common.sh" || exit 99
#
# This will automatically:
# - Load all core libraries in the correct order
# - Set up environment variables
# - Create required directories
# - Register the script with governance
# - Initialize observability tracing
# - Validate core services are available

# Note: Using -eo pipefail instead of -euo pipefail for compatibility with existing libraries
set -eo pipefail

# ==============================================================================
# SECTION 1: Environment Setup
# ==============================================================================

# Determine script directory and project root
if [ -z "${SCRIPT_DIR:-}" ]; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  fi
fi

# Set project root (go up from scripts/ to project root)
export COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export PROJECT_ROOT="$COMMIT_RELAY_HOME"

# Determine the calling script name
if [ -n "${BASH_SOURCE[1]:-}" ]; then
  CALLING_SCRIPT="$(basename "${BASH_SOURCE[1]}")"
else
  CALLING_SCRIPT="$(basename "$0")"
fi
export CALLING_SCRIPT

# ==============================================================================
# SECTION 2: Configuration Loading
# ==============================================================================

# Load system configuration
SYSTEM_CONFIG_FILE="$COMMIT_RELAY_HOME/coordination/config/system.json"

if [ ! -f "$SYSTEM_CONFIG_FILE" ]; then
  echo "ERROR: System configuration not found: $SYSTEM_CONFIG_FILE"
  echo "Please ensure commit-relay is properly initialized"
  exit 99
fi

# Function to get configuration values
get_config() {
  local key="$1"
  local default="${2:-}"

  if ! command -v jq &> /dev/null; then
    echo "$default"
    return
  fi

  local value
  value=$(jq -r ".$key // empty" "$SYSTEM_CONFIG_FILE" 2>/dev/null || echo "")

  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

# Export common configuration as environment variables
# Note: LOG_LEVEL is a string ('info', 'debug', etc.) - logging.sh converts to number
export LOG_LEVEL="${COMMIT_RELAY_LOG_LEVEL:-$(get_config 'logging.level' 'info')}"
export LOG_DIR="$(get_config 'logging.directory' 'agents/logs/system')"
export GOVERNANCE_ENABLED="$(get_config 'governance.enabled' 'true')"
export OBSERVABILITY_ENABLED="$(get_config 'observability.enabled' 'true')"
export VALIDATION_ENABLED="$(get_config 'validation.enabled' 'true')"

# Set COMMIT_RELAY_LOG_LEVEL to LOG_LEVEL for logging.sh compatibility
export COMMIT_RELAY_LOG_LEVEL="$LOG_LEVEL"

# Set up principal (who is running this script)
export COMMIT_RELAY_PRINCIPAL="${COMMIT_RELAY_PRINCIPAL:-system}"

# ==============================================================================
# SECTION 3: Core Libraries Loading (Order Matters!)
# ==============================================================================

LIB_DIR="$SCRIPT_DIR/lib"

# Track loading status
INIT_ERRORS=0

# Function to safely source a library
source_library() {
  local lib_name="$1"
  local lib_path="$LIB_DIR/$lib_name"
  local required="${2:-true}"

  if [ ! -f "$lib_path" ]; then
    if [ "$required" = "true" ]; then
      echo "ERROR: Required library not found: $lib_name" >&2
      echo "  Expected path: $lib_path" >&2
      ((INIT_ERRORS++))
      return 1
    else
      return 0
    fi
  fi

  # Source the library
  # shellcheck source=/dev/null
  if ! source "$lib_path"; then
    echo "ERROR: Failed to load library: $lib_name" >&2
    ((INIT_ERRORS++))
    return 1
  fi

  return 0
}

# 1. Load logging first (required for all error output)
source_library "logging.sh" true

# Now we can use log_* functions
log_debug "Initializing commit-relay core services for: $CALLING_SCRIPT"

# 2. Load coordination library (task/worker/token management)
source_library "coordination.sh" true

# 3. Load governance/access control
source_library "access-check.sh" true

# 4. Load validation service (critical for preventing malformed data)
source_library "validation-service.sh" true

# 5. Load optional libraries
source_library "git-automation.sh" false
source_library "worker-heartbeat.sh" false
source_library "json-validator.sh" false

# Check if we had any initialization errors
if [ $INIT_ERRORS -gt 0 ]; then
  echo "FATAL: Failed to initialize core libraries ($INIT_ERRORS errors)" >&2
  exit 99
fi

log_debug "Core libraries loaded successfully"

# ==============================================================================
# SECTION 4: Directory Structure Validation
# ==============================================================================

# Ensure required directories exist
ensure_directory() {
  local dir="$1"
  local full_path="$COMMIT_RELAY_HOME/$dir"

  if [ ! -d "$full_path" ]; then
    log_debug "Creating required directory: $dir"
    mkdir -p "$full_path" || {
      log_error "Failed to create directory: $dir"
      return 1
    }
  fi
}

# Create core directories
ensure_directory "coordination"
ensure_directory "coordination/config"
ensure_directory "coordination/schemas"
ensure_directory "coordination/worker-specs/active"
ensure_directory "coordination/worker-specs/completed"
ensure_directory "coordination/worker-specs/failed"
ensure_directory "coordination/governance"
ensure_directory "coordination/observability/events"
ensure_directory "coordination/observability/stream"
ensure_directory "coordination/observability/indices"
ensure_directory "agents/logs/system"
ensure_directory "logs/daemons"

# ==============================================================================
# SECTION 5: Core Coordination Files
# ==============================================================================

# Ensure core coordination files exist
ensure_coordination_file() {
  local file="$1"
  local default_content="$2"
  local full_path="$COMMIT_RELAY_HOME/coordination/$file"

  if [ ! -f "$full_path" ]; then
    log_debug "Creating coordination file: $file"
    echo "$default_content" > "$full_path" || {
      log_error "Failed to create coordination file: $file"
      return 1
    }
  fi
}

# Initialize core files if they don't exist
ensure_coordination_file "task-queue.json" '{"tasks":[],"last_updated":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
ensure_coordination_file "worker-pool.json" '{"active_workers":[],"last_updated":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
ensure_coordination_file "token-budget.json" '{"allocated":0,"consumed":0,"remaining":0,"last_updated":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'

# ==============================================================================
# SECTION 6: Observability Initialization
# ==============================================================================

# Generate trace ID for this script execution
if [ "$OBSERVABILITY_ENABLED" = "true" ]; then
  # If we're part of an existing trace, use parent trace ID
  if [ -z "${TRACE_ID:-}" ]; then
    TRACE_ID="script-$(date +%s)-$(uuidgen 2>/dev/null | cut -d'-' -f1 || echo $RANDOM)"
    export TRACE_ID
    export PARENT_SPAN_ID=""
    SPAN_COUNTER=0
  else
    # We're a child operation - inherit parent trace
    export PARENT_SPAN_ID="${SPAN_ID:-}"
  fi

  # Generate span ID for this script
  SPAN_COUNTER=$((${SPAN_COUNTER:-0} + 1))
  export SPAN_ID="${TRACE_ID}.${SPAN_COUNTER}"
  export SPAN_COUNTER

  log_debug "Trace initialized: trace_id=$TRACE_ID, span_id=$SPAN_ID"
fi

# ==============================================================================
# SECTION 7: Governance Registration
# ==============================================================================

# Register this script execution with governance
if [ "$GOVERNANCE_ENABLED" = "true" ]; then
  # Check if we're running in bypass mode (and audit it)
  if [ "${GOVERNANCE_BYPASS:-false}" = "true" ]; then
    log_critical "GOVERNANCE BYPASS ENABLED for $CALLING_SCRIPT"
    log_critical "Principal: $COMMIT_RELAY_PRINCIPAL, Reason: ${BYPASS_REASON:-not specified}"

    # Log bypass to audit trail
    if [ -f "$LIB_DIR/access-check.sh" ]; then
      log_access_decision "$COMMIT_RELAY_PRINCIPAL" "governance-system" "bypass" "allowed" "Bypass mode: ${BYPASS_REASON:-not specified}" 2>/dev/null || true
    fi
  fi

  log_debug "Governance enabled: principal=$COMMIT_RELAY_PRINCIPAL"
fi

# ==============================================================================
# SECTION 8: Utility Functions for Scripts
# ==============================================================================

# Function to emit observability events
trace_event() {
  local event_type="$1"
  local status="$2"
  local metadata="${3:-{}}"

  if [ "$OBSERVABILITY_ENABLED" != "true" ]; then
    return 0
  fi

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local event_file="$COMMIT_RELAY_HOME/coordination/observability/events/all-events.jsonl"

  # Build event JSON
  local event
  event=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "trace_id": "${TRACE_ID:-unknown}",
  "span_id": "${SPAN_ID:-unknown}",
  "parent_span_id": "${PARENT_SPAN_ID:-}",
  "event_type": "$event_type",
  "status": "$status",
  "component": "${COMPONENT:-script}",
  "component_id": "$CALLING_SCRIPT",
  "principal": "$COMMIT_RELAY_PRINCIPAL",
  "metadata": $metadata,
  "context": {
    "hostname": "$(hostname)",
    "pid": $$
  }
}
EOF
)

  # Write event to file
  echo "$event" >> "$event_file" 2>/dev/null || true
}

# Function to start a traced operation
trace_start() {
  local operation="$1"
  local operation_id="${2:-}"

  trace_event "operation.start" "info" "{\"operation\":\"$operation\",\"operation_id\":\"$operation_id\"}"
}

# Function to end a traced operation
trace_end() {
  local operation="$1"
  local final_status="${2:-success}"

  trace_event "operation.end" "$final_status" "{\"operation\":\"$operation\"}"
}

# Export trace functions
export -f trace_event 2>/dev/null || true
export -f trace_start 2>/dev/null || true
export -f trace_end 2>/dev/null || true

# ==============================================================================
# SECTION 9: Health Check
# ==============================================================================

# Quick validation that core services are accessible
validate_core_services() {
  local errors=0

  # Check if critical files exist
  if [ ! -f "$COMMIT_RELAY_HOME/coordination/task-queue.json" ]; then
    log_warn "Task queue not found (will be created)"
  fi

  if [ ! -f "$COMMIT_RELAY_HOME/agents/configs/agent-registry.json" ]; then
    log_warn "Agent registry not found - some features may not work"
  fi

  # Check if jq is available (required for JSON operations)
  if ! command -v jq &> /dev/null; then
    log_error "jq not found - JSON operations will fail"
    ((errors++))
  fi

  return $errors
}

# Run validation
validate_core_services || {
  log_warn "Core services validation had warnings, but continuing..."
}

# ==============================================================================
# SECTION 10: Initialization Complete
# ==============================================================================

log_debug "Core services initialization complete for $CALLING_SCRIPT"

# Emit initialization event
trace_event "init.complete" "success" "{\"script\":\"$CALLING_SCRIPT\",\"principal\":\"$COMMIT_RELAY_PRINCIPAL\"}"

# Set flag to indicate initialization is complete
export COMMIT_RELAY_INITIALIZED=true

# Return success
return 0
