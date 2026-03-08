#!/bin/bash
# scripts/lib/zombie-cleanup.sh
# Zombie Worker Cleanup Library - Phase 4.2
# Automatic detection and cleanup of unresponsive workers
#
# Features:
#   - Safe worker termination (SIGTERM → SIGKILL)
#   - Resource cleanup (token recovery, log archival)
#   - State management (move to zombie directory)
#   - Observability integration
#   - Rate limiting and safety mechanisms

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load dependencies
source "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh"

# Configuration
ZOMBIE_THRESHOLD_SECONDS="${ZOMBIE_THRESHOLD_SECONDS:-300}"
GRACEFUL_SHUTDOWN_TIMEOUT="${GRACEFUL_SHUTDOWN_TIMEOUT:-30}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-5}"
MAX_CLEANUPS_PER_MINUTE="${MAX_CLEANUPS_PER_MINUTE:-5}"

# Directories
ZOMBIE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie"
ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"
CLEANUP_LOG="$COMMIT_RELAY_HOME/agents/logs/system/zombie-cleanup.log"

# Ensure directories exist
mkdir -p "$ZOMBIE_SPECS_DIR"
mkdir -p "$(dirname "$CLEANUP_LOG")"

# Rate limiting state
CLEANUP_COUNT_FILE="/tmp/zombie-cleanup-count-$(date +%Y%m%d%H%M)"
CLEANUP_COUNT=0

log_cleanup() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1" | tee -a "$CLEANUP_LOG"
}

##############################################################################
# is_worker_zombie: Check if worker meets zombie criteria
# Args:
#   $1: worker_id
# Returns: 0 if zombie, 1 if not
##############################################################################
is_worker_zombie() {
    local worker_id="$1"
    local spec_file="$ACTIVE_SPECS_DIR/${worker_id}.json"

    if [ ! -f "$spec_file" ]; then
        return 1
    fi

    # Check worker status
    local status=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "")
    if [[ ! "$status" =~ ^(pending|active|running)$ ]]; then
        return 1  # Not an active worker
    fi

    # Check time since last heartbeat
    local time_since=$(get_time_since_heartbeat "$worker_id")

    if [ "$time_since" -ge "$ZOMBIE_THRESHOLD_SECONDS" ]; then
        return 0  # Is zombie
    else
        return 1  # Not zombie yet
    fi
}

##############################################################################
# verify_zombie_status: Double-check zombie status before cleanup
# Args:
#   $1: worker_id
# Returns: 0 if confirmed zombie, 1 if false positive
##############################################################################
verify_zombie_status() {
    local worker_id="$1"

    log_cleanup "INFO: Verifying zombie status for $worker_id"

    # Wait brief period and check again (prevent race conditions)
    sleep 2

    # Check if heartbeat resumed
    if ! is_worker_zombie "$worker_id"; then
        log_cleanup "INFO: $worker_id is no longer a zombie (heartbeat resumed)"
        return 1
    fi

    # Check process status
    local worker_dir="$COMMIT_RELAY_HOME/agents/workers/$worker_id"
    if [ -f "$worker_dir/worker.pid" ]; then
        local worker_pid=$(cat "$worker_dir/worker.pid")

        # If process exists, check if it's truly hung
        if ps -p "$worker_pid" > /dev/null 2>&1; then
            # Process exists but no heartbeat - likely hung
            log_cleanup "INFO: $worker_id process $worker_pid exists but not responding"
        else
            # Process dead - definitely zombie
            log_cleanup "INFO: $worker_id process $worker_pid is dead"
        fi
    else
        log_cleanup "INFO: $worker_id has no PID file (orphaned)"
    fi

    log_cleanup "SUCCESS: $worker_id confirmed as zombie"
    return 0
}

##############################################################################
# check_cleanup_rate_limit: Prevent cleanup storms
# Returns: 0 if ok to cleanup, 1 if rate limit exceeded
##############################################################################
check_cleanup_rate_limit() {
    # Read current count
    if [ -f "$CLEANUP_COUNT_FILE" ]; then
        CLEANUP_COUNT=$(cat "$CLEANUP_COUNT_FILE")
    else
        CLEANUP_COUNT=0
    fi

    if [ "$CLEANUP_COUNT" -ge "$MAX_CLEANUPS_PER_MINUTE" ]; then
        log_cleanup "WARN: Cleanup rate limit exceeded ($CLEANUP_COUNT/$MAX_CLEANUPS_PER_MINUTE)"
        return 1
    fi

    # Increment count
    CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
    echo "$CLEANUP_COUNT" > "$CLEANUP_COUNT_FILE"

    return 0
}

##############################################################################
# terminate_worker_process: Kill worker process (graceful → forced)
# Args:
#   $1: worker_id
# Returns: 0 if terminated, 1 if failed
##############################################################################
terminate_worker_process() {
    local worker_id="$1"
    local worker_dir="$COMMIT_RELAY_HOME/agents/workers/$worker_id"

    log_cleanup "INFO: Terminating worker $worker_id process..."

    # Get worker PID
    if [ ! -f "$worker_dir/worker.pid" ]; then
        log_cleanup "WARN: No PID file found for $worker_id, skipping process termination"
        return 0
    fi

    local worker_pid=$(cat "$worker_dir/worker.pid")

    # Check if process exists
    if ! ps -p "$worker_pid" > /dev/null 2>&1; then
        log_cleanup "INFO: Process $worker_pid already terminated"
        return 0
    fi

    # Phase 1: Graceful shutdown (SIGTERM)
    log_cleanup "INFO: Sending SIGTERM to process $worker_pid..."
    kill -TERM "$worker_pid" 2>/dev/null || true

    # Wait for graceful shutdown
    local waited=0
    while [ $waited -lt "$GRACEFUL_SHUTDOWN_TIMEOUT" ]; do
        if ! ps -p "$worker_pid" > /dev/null 2>&1; then
            log_cleanup "SUCCESS: Process $worker_pid terminated gracefully"

            # Also kill heartbeat emitter
            if [ -f "$worker_dir/heartbeat.pid" ]; then
                local heartbeat_pid=$(cat "$worker_dir/heartbeat.pid")
                kill -TERM "$heartbeat_pid" 2>/dev/null || true
            fi

            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Phase 2: Forced termination (SIGKILL)
    log_cleanup "WARN: Graceful shutdown timed out, forcing termination..."

    if ps -p "$worker_pid" > /dev/null 2>&1; then
        kill -KILL "$worker_pid" 2>/dev/null || true
        sleep 1

        if ! ps -p "$worker_pid" > /dev/null 2>&1; then
            log_cleanup "SUCCESS: Process $worker_pid force-killed"
        else
            log_cleanup "ERROR: Failed to kill process $worker_pid"
            return 1
        fi
    fi

    # Kill heartbeat emitter
    if [ -f "$worker_dir/heartbeat.pid" ]; then
        local heartbeat_pid=$(cat "$worker_dir/heartbeat.pid")
        kill -KILL "$heartbeat_pid" 2>/dev/null || true
    fi

    return 0
}

##############################################################################
# return_worker_tokens: Return allocated tokens to budget
# Args:
#   $1: worker_id
# Returns: 0 on success
##############################################################################
return_worker_tokens() {
    local worker_id="$1"
    local spec_file="$ACTIVE_SPECS_DIR/${worker_id}.json"

    # Get token allocation and usage
    local allocated=$(jq -r '.resources.token_allocation // 0' "$spec_file")
    local used=$(jq -r '.execution.tokens_used // 0' "$spec_file")
    local remaining=$((allocated - used))

    if [ "$remaining" -le 0 ]; then
        log_cleanup "INFO: No tokens to return for $worker_id (used: $used/$allocated)"
        return 0
    fi

    log_cleanup "INFO: Returning $remaining tokens to budget for $worker_id"

    # Update token budget
    local token_budget="$COMMIT_RELAY_HOME/coordination/token-budget.json"
    if [ -f "$token_budget" ]; then
        # Atomically update budget
        jq --argjson returned "$remaining" \
           '.total_used = (.total_used - $returned)' \
           "$token_budget" > "${token_budget}.tmp" && \
           mv "${token_budget}.tmp" "$token_budget"

        log_cleanup "SUCCESS: Returned $remaining tokens to budget"
    else
        log_cleanup "WARN: Token budget file not found, cannot return tokens"
    fi

    return 0
}

##############################################################################
# archive_worker_logs: Archive worker logs before cleanup
# Args:
#   $1: worker_id
# Returns: 0 on success
##############################################################################
archive_worker_logs() {
    local worker_id="$1"
    local worker_dir="$COMMIT_RELAY_HOME/agents/workers/$worker_id"

    if [ ! -d "$worker_dir" ]; then
        log_cleanup "INFO: No worker directory to archive for $worker_id"
        return 0
    fi

    # Create archive directory
    local archive_date=$(date +%Y-%m-%d)
    local archive_dir="$COMMIT_RELAY_HOME/agents/logs/zombie-workers/$archive_date"
    mkdir -p "$archive_dir"

    # Archive logs
    if [ -d "$worker_dir/logs" ]; then
        log_cleanup "INFO: Archiving logs for $worker_id to $archive_dir"
        cp -r "$worker_dir/logs" "$archive_dir/${worker_id}-logs" 2>/dev/null || true
    fi

    # Archive PID files for reference
    if [ -f "$worker_dir/worker.pid" ] || [ -f "$worker_dir/heartbeat.pid" ]; then
        mkdir -p "$archive_dir/${worker_id}-metadata"
        cp "$worker_dir"/*.pid "$archive_dir/${worker_id}-metadata/" 2>/dev/null || true
    fi

    log_cleanup "SUCCESS: Archived logs for $worker_id"
    return 0
}

##############################################################################
# cleanup_worker_state: Move worker spec to zombie directory
# Args:
#   $1: worker_id
# Returns: 0 on success
##############################################################################
cleanup_worker_state() {
    local worker_id="$1"
    local spec_file="$ACTIVE_SPECS_DIR/${worker_id}.json"

    log_cleanup "INFO: Cleaning up worker state for $worker_id"

    # Create dated zombie directory
    local zombie_date=$(date +%Y-%m-%d)
    local zombie_dir="$ZOMBIE_SPECS_DIR/$zombie_date"
    mkdir -p "$zombie_dir"

    # Update worker spec with cleanup metadata
    local cleanup_time=$(date +%Y-%m-%dT%H:%M:%S%z)
    jq --arg cleaned_at "$cleanup_time" \
       --arg reason "No heartbeat for >300s" \
       '.status = "zombie" |
        .cleanup = {
          cleaned_at: $cleaned_at,
          reason: $reason,
          automated: true
        }' \
       "$spec_file" > "${spec_file}.tmp" && \
       mv "${spec_file}.tmp" "$spec_file"

    # Move spec to zombie directory
    mv "$spec_file" "$zombie_dir/${worker_id}.json"

    log_cleanup "SUCCESS: Moved $worker_id to zombie directory ($zombie_dir)"
    return 0
}

##############################################################################
# emit_zombie_event: Emit observability event for zombie cleanup
# Args:
#   $1: event_type
#   $2: worker_id
#   $3: additional_data (optional JSON)
##############################################################################
emit_zombie_event() {
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
    local events_log="$COMMIT_RELAY_HOME/coordination/events/zombie-cleanup-events.jsonl"
    mkdir -p "$(dirname "$events_log")"
    echo "$event_json" >> "$events_log"

    # Broadcast to dashboard if function available
    if command -v broadcast_dashboard_event &> /dev/null; then
        broadcast_dashboard_event "$event_type" "$event_json" 2>/dev/null || true
    fi
}

##############################################################################
# cleanup_zombie_worker: Full zombie worker cleanup process
# Args:
#   $1: worker_id
# Returns: 0 if successful, 1 if failed
##############################################################################
cleanup_zombie_worker() {
    local worker_id="$1"

    log_cleanup "========================================"
    log_cleanup "ZOMBIE CLEANUP: $worker_id"
    log_cleanup "========================================"

    # Check rate limit
    if ! check_cleanup_rate_limit; then
        log_cleanup "ERROR: Rate limit exceeded, skipping cleanup for $worker_id"
        emit_zombie_event "zombie_cleanup_rate_limited" "$worker_id" "{\"reason\": \"Too many cleanups\"}"
        return 1
    fi

    # Verify zombie status
    if ! verify_zombie_status "$worker_id"; then
        log_cleanup "INFO: $worker_id is not a zombie (false positive avoided)"
        return 1
    fi

    # Emit detection event
    emit_zombie_event "zombie_detected" "$worker_id" "{\"threshold\": \"${ZOMBIE_THRESHOLD_SECONDS}s\"}"

    # Phase 1: Terminate process
    log_cleanup "PHASE 1: Terminating worker process..."
    if ! terminate_worker_process "$worker_id"; then
        log_cleanup "ERROR: Failed to terminate process for $worker_id"
        emit_zombie_event "zombie_cleanup_failed" "$worker_id" "{\"phase\": \"termination\"}"
        return 1
    fi

    emit_zombie_event "zombie_process_terminated" "$worker_id"

    # Phase 2: Return tokens
    log_cleanup "PHASE 2: Returning allocated tokens..."
    return_worker_tokens "$worker_id"

    # Phase 3: Archive logs
    log_cleanup "PHASE 3: Archiving worker logs..."
    archive_worker_logs "$worker_id"

    # Phase 4: Cleanup state
    log_cleanup "PHASE 4: Cleaning up worker state..."
    if ! cleanup_worker_state "$worker_id"; then
        log_cleanup "ERROR: Failed to cleanup state for $worker_id"
        emit_zombie_event "zombie_cleanup_failed" "$worker_id" "{\"phase\": \"state_cleanup\"}"
        return 1
    fi

    # Success
    log_cleanup "SUCCESS: Zombie cleanup completed for $worker_id"
    emit_zombie_event "zombie_cleanup_completed" "$worker_id"

    # Phase 4.3: Check if worker should be restarted
    if [ -f "$COMMIT_RELAY_HOME/scripts/lib/worker-restart.sh" ]; then
        source "$COMMIT_RELAY_HOME/scripts/lib/worker-restart.sh" 2>/dev/null || true

        if command -v should_restart_worker &> /dev/null; then
            if should_restart_worker "$worker_id"; then
                log_cleanup "INFO: Worker eligible for restart, triggering restart logic"
                # Run restart in background (non-blocking)
                (restart_worker "$worker_id" &) &
            else
                log_cleanup "INFO: Worker not eligible for restart (criteria not met)"
            fi
        fi
    fi

    log_cleanup "========================================"

    return 0
}

# Export functions for external use
export -f is_worker_zombie
export -f verify_zombie_status
export -f terminate_worker_process
export -f return_worker_tokens
export -f archive_worker_logs
export -f cleanup_worker_state
export -f emit_zombie_event
export -f cleanup_zombie_worker

log_cleanup "INFO: Zombie cleanup library loaded"
log_cleanup "INFO: Zombie threshold: ${ZOMBIE_THRESHOLD_SECONDS}s"
log_cleanup "INFO: Rate limit: $MAX_CLEANUPS_PER_MINUTE cleanups/minute"
