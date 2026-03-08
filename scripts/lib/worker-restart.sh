#!/bin/bash
# scripts/lib/worker-restart.sh
# Worker Automatic Restart Library - Phase 4.3
# Intelligent restart logic for failed workers with retry policies
#
# Features:
#   - Smart restart decision making
#   - Exponential backoff retry strategy
#   - Circuit breaker pattern for systemic failures
#   - Rate limiting to prevent restart storms
#   - Token budget awareness
#   - Complete observability integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load dependencies
source "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh" 2>/dev/null || true

# Load configuration
RESTART_POLICY_FILE="$COMMIT_RELAY_HOME/coordination/config/worker-restart-policy.json"
if [ ! -f "$RESTART_POLICY_FILE" ]; then
    echo "ERROR: Restart policy file not found: $RESTART_POLICY_FILE" >&2
    exit 1
fi

# Configuration values
RESTART_ENABLED=$(jq -r '.enabled' "$RESTART_POLICY_FILE")
BASE_DELAY=$(jq -r '.backoff.base_delay_seconds' "$RESTART_POLICY_FILE")
MAX_DELAY=$(jq -r '.backoff.max_delay_seconds' "$RESTART_POLICY_FILE")
CIRCUIT_BREAKER_ENABLED=$(jq -r '.circuit_breaker.enabled' "$RESTART_POLICY_FILE")
FAILURE_THRESHOLD=$(jq -r '.circuit_breaker.failure_threshold' "$RESTART_POLICY_FILE")
FAILURE_WINDOW=$(jq -r '.circuit_breaker.failure_window_seconds' "$RESTART_POLICY_FILE")
GLOBAL_RATE_LIMIT=$(jq -r '.rate_limits.global_max_per_minute' "$RESTART_POLICY_FILE")
PER_TYPE_RATE_LIMIT=$(jq -r '.rate_limits.per_type_max_per_minute' "$RESTART_POLICY_FILE")

# Directories
ZOMBIE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie"
ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"
RESTART_QUEUE_DIR="$COMMIT_RELAY_HOME/coordination/restart/queue"
CIRCUIT_BREAKER_FILE="$COMMIT_RELAY_HOME/coordination/restart/circuit-breakers.json"
RESTART_LOG="$COMMIT_RELAY_HOME/agents/logs/system/worker-restart.log"

# Ensure directories exist
mkdir -p "$RESTART_QUEUE_DIR"
mkdir -p "$(dirname "$CIRCUIT_BREAKER_FILE")"
mkdir -p "$(dirname "$RESTART_LOG")"

# Initialize circuit breaker file if not exists
if [ ! -f "$CIRCUIT_BREAKER_FILE" ]; then
    echo '{}' > "$CIRCUIT_BREAKER_FILE"
fi

log_restart() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1" | tee -a "$RESTART_LOG"
}

##############################################################################
# get_max_retries: Get max retry count for worker type
# Args:
#   $1: worker_type
# Returns: max retry count
##############################################################################
get_max_retries() {
    local worker_type="$1"

    # Try to get type-specific retry count
    local max_retries=$(jq -r --arg type "$worker_type" '.max_retries_by_type[$type] // .max_retries_by_type.default' "$RESTART_POLICY_FILE")

    echo "$max_retries"
}

##############################################################################
# calculate_restart_delay: Calculate backoff delay for restart attempt
# Args:
#   $1: attempt number (1-based)
# Returns: delay in seconds
##############################################################################
calculate_restart_delay() {
    local attempt="$1"
    local base_delay="$BASE_DELAY"
    local max_delay="$MAX_DELAY"

    # Exponential backoff: base * 2^(attempt-1)
    local exponent=$((attempt - 1))
    local delay=$((base_delay * (2 ** exponent)))

    # Cap at max delay
    if [ "$delay" -gt "$max_delay" ]; then
        delay="$max_delay"
    fi

    echo "$delay"
}

##############################################################################
# check_circuit_breaker: Check if circuit breaker is active for worker type
# Args:
#   $1: worker_type
# Returns: 0 if OK to proceed, 1 if circuit breaker active
##############################################################################
check_circuit_breaker() {
    local worker_type="$1"

    if [ "$CIRCUIT_BREAKER_ENABLED" != "true" ]; then
        return 0  # Circuit breaker disabled
    fi

    # Check if circuit breaker exists and is active for this type
    local is_active=$(jq -r --arg type "$worker_type" '.[$type].active // false' "$CIRCUIT_BREAKER_FILE" 2>/dev/null || echo "false")

    if [ "$is_active" = "true" ]; then
        # Check if it should be reset (timeout expired)
        local tripped_at=$(jq -r --arg type "$worker_type" '.[$type].tripped_at' "$CIRCUIT_BREAKER_FILE" 2>/dev/null || echo "")

        if [ -n "$tripped_at" ]; then
            local reset_timeout=$(jq -r '.circuit_breaker.reset_timeout_seconds' "$RESTART_POLICY_FILE")
            local tripped_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$tripped_at" +%s 2>/dev/null || date -d "$tripped_at" +%s 2>/dev/null || echo "0")
            local now_epoch=$(date +%s)
            local elapsed=$((now_epoch - tripped_epoch))

            if [ "$elapsed" -ge "$reset_timeout" ]; then
                log_restart "INFO: Circuit breaker timeout expired for $worker_type, resetting"
                reset_circuit_breaker "$worker_type" "timeout_expired"
                return 0
            fi
        fi

        log_restart "WARN: Circuit breaker active for $worker_type"
        return 1  # Circuit breaker active
    fi

    return 0  # OK to proceed
}

##############################################################################
# trip_circuit_breaker: Activate circuit breaker for worker type
# Args:
#   $1: worker_type
#   $2: reason
##############################################################################
trip_circuit_breaker() {
    local worker_type="$1"
    local reason="$2"

    log_restart "CRITICAL: Tripping circuit breaker for $worker_type - $reason"

    local tripped_at=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Get current failure count
    local current_count=$(jq -r --arg type "$worker_type" '.[$type].failure_count // 0' "$CIRCUIT_BREAKER_FILE")
    local new_count=$((current_count + 1))

    # Update circuit breaker file
    jq --arg type "$worker_type" \
       --arg reason "$reason" \
       --arg tripped_at "$tripped_at" \
       --argjson failure_count "$new_count" \
       '.[$type] = {
           active: true,
           reason: $reason,
           tripped_at: $tripped_at,
           failure_count: $failure_count
       }' \
       "$CIRCUIT_BREAKER_FILE" > "${CIRCUIT_BREAKER_FILE}.tmp" && \
       mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE"

    # Emit event
    emit_restart_event "circuit_breaker_tripped" "$worker_type" "{\"reason\": \"$reason\"}"
}

##############################################################################
# reset_circuit_breaker: Reset circuit breaker for worker type
# Args:
#   $1: worker_type
#   $2: reason
##############################################################################
reset_circuit_breaker() {
    local worker_type="$1"
    local reason="$2"

    log_restart "INFO: Resetting circuit breaker for $worker_type - $reason"

    # Update circuit breaker file
    jq --arg type "$worker_type" \
       '.[$type].active = false' \
       "$CIRCUIT_BREAKER_FILE" > "${CIRCUIT_BREAKER_FILE}.tmp" && \
       mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE"

    # Emit event
    emit_restart_event "circuit_breaker_reset" "$worker_type" "{\"reason\": \"$reason\"}"
}

##############################################################################
# check_restart_rate_limit: Check if restart rate limit allows proceeding
# Args:
#   $1: worker_type
# Returns: 0 if OK to proceed, 1 if rate limited
##############################################################################
check_restart_rate_limit() {
    local worker_type="$1"
    local current_minute=$(date +%Y%m%d%H%M)
    local rate_limit_file="/tmp/restart-rate-limit-${current_minute}"

    # Count restarts in current minute
    local global_count=0
    local type_count=0

    if [ -f "$rate_limit_file" ]; then
        global_count=$(wc -l < "$rate_limit_file" | tr -d ' ')
        type_count=$(grep -c "^${worker_type}$" "$rate_limit_file" 2>/dev/null || echo "0")
    fi

    # Check global rate limit
    if [ "$global_count" -ge "$GLOBAL_RATE_LIMIT" ]; then
        log_restart "WARN: Global restart rate limit exceeded ($global_count >= $GLOBAL_RATE_LIMIT)"
        return 1
    fi

    # Check per-type rate limit
    if [ "$type_count" -ge "$PER_TYPE_RATE_LIMIT" ]; then
        log_restart "WARN: Per-type restart rate limit exceeded for $worker_type ($type_count >= $PER_TYPE_RATE_LIMIT)"
        return 1
    fi

    # Record this restart
    echo "$worker_type" >> "$rate_limit_file"

    return 0
}

##############################################################################
# check_token_budget: Verify sufficient token budget for restart
# Args:
#   $1: required_tokens
# Returns: 0 if sufficient budget, 1 if insufficient
##############################################################################
check_token_budget() {
    local required_tokens="$1"
    local token_budget_file="$COMMIT_RELAY_HOME/coordination/token-budget.json"

    if [ ! -f "$token_budget_file" ]; then
        log_restart "WARN: Token budget file not found, allowing restart"
        return 0
    fi

    local total_budget=$(jq -r '.total_budget' "$token_budget_file")
    local total_used=$(jq -r '.total_used' "$token_budget_file")
    local available=$((total_budget - total_used))

    if [ "$available" -lt "$required_tokens" ]; then
        log_restart "WARN: Insufficient token budget (need: $required_tokens, available: $available)"
        return 1
    fi

    return 0
}

##############################################################################
# should_restart_worker: Decide if a cleaned-up worker should be restarted
# Args:
#   $1: worker_id
# Returns: 0 if should restart, 1 if should not
##############################################################################
should_restart_worker() {
    local worker_id="$1"

    # Check if restart system is enabled
    if [ "$RESTART_ENABLED" != "true" ]; then
        log_restart "INFO: Restart system disabled, not restarting $worker_id"
        return 1
    fi

    # Find zombie spec (check today and yesterday in case of date boundary)
    local zombie_spec=""
    local today=$(date +%Y-%m-%d)
    local yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)

    if [ -f "$ZOMBIE_SPECS_DIR/$today/${worker_id}.json" ]; then
        zombie_spec="$ZOMBIE_SPECS_DIR/$today/${worker_id}.json"
    elif [ -f "$ZOMBIE_SPECS_DIR/$yesterday/${worker_id}.json" ]; then
        zombie_spec="$ZOMBIE_SPECS_DIR/$yesterday/${worker_id}.json"
    else
        log_restart "ERROR: Zombie spec not found for $worker_id"
        return 1
    fi

    # Extract worker metadata
    local task_id=$(jq -r '.task_id' "$zombie_spec")
    local worker_type=$(jq -r '.worker_type' "$zombie_spec")
    local status=$(jq -r '.status' "$zombie_spec")
    local restart_attempt=$(jq -r '.restart.restart_attempt // 0' "$zombie_spec")

    # Check 1: Worker must have been running (not pending)
    if [ "$status" != "zombie" ]; then
        log_restart "INFO: Worker $worker_id status is $status, expected zombie"
        return 1
    fi

    # Check 2: Check retry count
    local max_retries=$(get_max_retries "$worker_type")
    if [ "$restart_attempt" -ge "$max_retries" ]; then
        log_restart "INFO: Max retries exceeded for $worker_id ($restart_attempt >= $max_retries)"
        emit_restart_event "worker_restart_abandoned" "$worker_id" "{\"reason\": \"max_retries_exceeded\", \"attempts\": $restart_attempt}"
        return 1
    fi

    # Check 3: Circuit breaker
    if ! check_circuit_breaker "$worker_type"; then
        log_restart "INFO: Circuit breaker active for $worker_type, not restarting $worker_id"
        emit_restart_event "worker_restart_blocked" "$worker_id" "{\"reason\": \"circuit_breaker_active\"}"
        return 1
    fi

    # Check 4: Rate limit
    if ! check_restart_rate_limit "$worker_type"; then
        log_restart "INFO: Rate limit exceeded for $worker_type, deferring restart of $worker_id"
        emit_restart_event "worker_restart_rate_limited" "$worker_id" "{\"reason\": \"rate_limit_exceeded\"}"
        return 1
    fi

    # Check 5: Token budget
    local token_allocation=$(jq -r '.resources.token_allocation // 10000' "$zombie_spec")
    if ! check_token_budget "$token_allocation"; then
        log_restart "INFO: Insufficient token budget for $worker_id"
        emit_restart_event "worker_restart_deferred" "$worker_id" "{\"reason\": \"insufficient_budget\"}"
        return 1
    fi

    # All checks passed
    log_restart "INFO: Worker $worker_id is eligible for restart"
    return 0
}

##############################################################################
# queue_restart: Add worker to restart queue with scheduled time
# Args:
#   $1: new_worker_id
#   $2: task_id
#   $3: worker_type
#   $4: master
#   $5: scheduled_at (ISO-8601 timestamp)
#   $6: original_worker_id
#   $7: attempt
##############################################################################
queue_restart() {
    local new_worker_id="$1"
    local task_id="$2"
    local worker_type="$3"
    local master="$4"
    local scheduled_at="$5"
    local original_worker_id="$6"
    local attempt="$7"

    local queue_entry=$(jq -nc \
        --arg new_worker_id "$new_worker_id" \
        --arg task_id "$task_id" \
        --arg worker_type "$worker_type" \
        --arg master "$master" \
        --arg scheduled_at "$scheduled_at" \
        --arg original_worker_id "$original_worker_id" \
        --argjson attempt "$attempt" \
        --arg queued_at "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            new_worker_id: $new_worker_id,
            task_id: $task_id,
            worker_type: $worker_type,
            master: $master,
            scheduled_at: $scheduled_at,
            original_worker_id: $original_worker_id,
            attempt: $attempt,
            queued_at: $queued_at,
            status: "pending"
        }')

    # Write to queue
    local queue_file="$RESTART_QUEUE_DIR/${new_worker_id}.json"
    echo "$queue_entry" > "$queue_file"

    log_restart "INFO: Queued restart: $new_worker_id (scheduled for $scheduled_at)"
}

##############################################################################
# restart_worker: Schedule worker restart with backoff delay
# Args:
#   $1: original_worker_id
# Returns: 0 if scheduled, 1 if failed
##############################################################################
restart_worker() {
    local original_worker_id="$1"

    # Find zombie spec
    local zombie_spec=""
    local today=$(date +%Y-%m-%d)
    local yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)

    if [ -f "$ZOMBIE_SPECS_DIR/$today/${original_worker_id}.json" ]; then
        zombie_spec="$ZOMBIE_SPECS_DIR/$today/${original_worker_id}.json"
    elif [ -f "$ZOMBIE_SPECS_DIR/$yesterday/${original_worker_id}.json" ]; then
        zombie_spec="$ZOMBIE_SPECS_DIR/$yesterday/${original_worker_id}.json"
    else
        log_restart "ERROR: Zombie spec not found for $original_worker_id"
        return 1
    fi

    # Load original worker config
    local task_id=$(jq -r '.task_id' "$zombie_spec")
    local worker_type=$(jq -r '.worker_type' "$zombie_spec")
    local master=$(jq -r '.parent_master' "$zombie_spec")
    local restart_attempt=$(jq -r '.restart.restart_attempt // 0' "$zombie_spec")

    # Increment attempt counter
    restart_attempt=$((restart_attempt + 1))

    # Calculate delay
    local delay=$(calculate_restart_delay "$restart_attempt")

    log_restart "INFO: Scheduling restart for $original_worker_id (attempt $restart_attempt, delay ${delay}s)"

    # Calculate scheduled time
    local scheduled_at
    if command -v gdate &> /dev/null; then
        # Use GNU date if available (macOS with coreutils)
        scheduled_at=$(gdate -d "+${delay} seconds" +%Y-%m-%dT%H:%M:%S%z)
    elif date -v+1d > /dev/null 2>&1; then
        # BSD date (macOS)
        scheduled_at=$(date -v+${delay}S +%Y-%m-%dT%H:%M:%S%z)
    else
        # GNU date (Linux)
        scheduled_at=$(date -d "+${delay} seconds" +%Y-%m-%dT%H:%M:%S%z)
    fi

    # Generate new worker ID
    local new_worker_id="${original_worker_id}-restart-${restart_attempt}"

    # Queue restart
    queue_restart "$new_worker_id" "$task_id" "$worker_type" "$master" "$scheduled_at" "$original_worker_id" "$restart_attempt"

    # Emit event
    emit_restart_event "worker_restart_scheduled" "$original_worker_id" "{\"new_worker_id\": \"$new_worker_id\", \"attempt\": $restart_attempt, \"delay_seconds\": $delay, \"scheduled_at\": \"$scheduled_at\"}"

    return 0
}

##############################################################################
# emit_restart_event: Emit observability event for restart actions
# Args:
#   $1: event_type
#   $2: worker_id
#   $3: additional_data (JSON string)
##############################################################################
emit_restart_event() {
    local event_type="$1"
    local worker_id="$2"
    local additional_data="${3:-{}}"

    local event_json=$(jq -nc \
        --arg event "$event_type" \
        --arg worker "$worker_id" \
        --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson data "$additional_data" \
        '{
            event_type: $event,
            worker_id: $worker,
            timestamp: $timestamp,
            data: $data
        }')

    # Write to events log
    local events_log="$COMMIT_RELAY_HOME/coordination/events/worker-restart-events.jsonl"
    mkdir -p "$(dirname "$events_log")"
    echo "$event_json" >> "$events_log"

    # Broadcast to dashboard if function available
    if command -v broadcast_dashboard_event &> /dev/null; then
        broadcast_dashboard_event "$event_type" "$event_json" 2>/dev/null || true
    fi
}

# Export functions for external use
export -f get_max_retries
export -f calculate_restart_delay
export -f check_circuit_breaker
export -f trip_circuit_breaker
export -f reset_circuit_breaker
export -f check_restart_rate_limit
export -f check_token_budget
export -f should_restart_worker
export -f queue_restart
export -f restart_worker
export -f emit_restart_event

log_restart "INFO: Worker restart library loaded"
log_restart "INFO: Restart enabled: $RESTART_ENABLED"
log_restart "INFO: Base delay: ${BASE_DELAY}s, Max delay: ${MAX_DELAY}s"
log_restart "INFO: Circuit breaker enabled: $CIRCUIT_BREAKER_ENABLED"
