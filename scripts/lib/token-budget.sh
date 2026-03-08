#!/bin/bash
# scripts/lib/token-budget.sh
# Token Budget Management Library
# Provides atomic operations for token allocation, release, and tracking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

TOKEN_BUDGET_FILE="$COMMIT_RELAY_HOME/coordination/token-budget.json"
TOKEN_LOCK_FILE="/tmp/commit-relay-token-budget.lock"

# Acquire lock for atomic operations
acquire_lock() {
    local max_wait=30
    local wait_count=0

    while [ -f "$TOKEN_LOCK_FILE" ]; do
        sleep 0.1
        wait_count=$((wait_count + 1))
        if [ $wait_count -gt $((max_wait * 10)) ]; then
            echo "ERROR: Could not acquire token budget lock" >&2
            return 1
        fi
    done

    echo $$ > "$TOKEN_LOCK_FILE"
}

release_lock() {
    rm -f "$TOKEN_LOCK_FILE"
}

# Get current budget state
get_budget_state() {
    cat "$TOKEN_BUDGET_FILE"
}

# Get available tokens
get_available_tokens() {
    jq -r '.available' "$TOKEN_BUDGET_FILE"
}

# Allocate tokens for a worker
# Args: $1 = worker_id, $2 = tokens_requested
# Returns: 0 on success, 1 on insufficient funds
allocate_tokens() {
    local worker_id="$1"
    local tokens="$2"

    acquire_lock || return 1
    trap release_lock EXIT

    local available=$(jq -r '.available' "$TOKEN_BUDGET_FILE")

    if [ "$tokens" -gt "$available" ]; then
        echo "ERROR: Insufficient tokens. Requested: $tokens, Available: $available" >&2
        release_lock
        return 1
    fi

    # Update budget atomically
    local temp_file=$(mktemp)
    jq --arg worker_id "$worker_id" \
       --argjson tokens "$tokens" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.allocated += $tokens |
        .available -= $tokens |
        .allocations[$worker_id] = {
          tokens: $tokens,
          allocated_at: $timestamp,
          status: "allocated"
        } |
        .updated_at = $timestamp' \
       "$TOKEN_BUDGET_FILE" > "$temp_file"

    mv "$temp_file" "$TOKEN_BUDGET_FILE"
    release_lock

    echo "Allocated $tokens tokens to $worker_id"
}

# Mark tokens as in-use (worker started executing)
# Args: $1 = worker_id
start_using_tokens() {
    local worker_id="$1"

    acquire_lock || return 1
    trap release_lock EXIT

    local allocation=$(jq -r --arg w "$worker_id" '.allocations[$w].tokens // 0' "$TOKEN_BUDGET_FILE")

    if [ "$allocation" -eq 0 ]; then
        echo "ERROR: No allocation found for $worker_id" >&2
        release_lock
        return 1
    fi

    local temp_file=$(mktemp)
    jq --arg worker_id "$worker_id" \
       --argjson tokens "$allocation" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.allocated -= $tokens |
        .in_use += $tokens |
        .allocations[$worker_id].status = "in_use" |
        .allocations[$worker_id].started_at = $timestamp |
        .updated_at = $timestamp' \
       "$TOKEN_BUDGET_FILE" > "$temp_file"

    mv "$temp_file" "$TOKEN_BUDGET_FILE"
    release_lock

    echo "Worker $worker_id now using $allocation tokens"
}

# Release tokens when worker completes
# Args: $1 = worker_id, $2 = actual_tokens_used (optional)
release_tokens() {
    local worker_id="$1"
    local actual_used="${2:-0}"

    acquire_lock || return 1
    trap release_lock EXIT

    local allocation=$(jq -r --arg w "$worker_id" '.allocations[$w].tokens // 0' "$TOKEN_BUDGET_FILE")
    local status=$(jq -r --arg w "$worker_id" '.allocations[$w].status // "unknown"' "$TOKEN_BUDGET_FILE")

    if [ "$allocation" -eq 0 ]; then
        release_lock
        return 0  # Already released
    fi

    local temp_file=$(mktemp)

    if [ "$status" = "in_use" ]; then
        # Release from in_use
        jq --arg worker_id "$worker_id" \
           --argjson tokens "$allocation" \
           --argjson actual "$actual_used" \
           --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           '.in_use -= $tokens |
            .available += $tokens |
            .allocations[$worker_id].status = "released" |
            .allocations[$worker_id].released_at = $timestamp |
            .allocations[$worker_id].actual_used = $actual |
            .updated_at = $timestamp' \
           "$TOKEN_BUDGET_FILE" > "$temp_file"
    else
        # Release from allocated (never started)
        jq --arg worker_id "$worker_id" \
           --argjson tokens "$allocation" \
           --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           '.allocated -= $tokens |
            .available += $tokens |
            .allocations[$worker_id].status = "released" |
            .allocations[$worker_id].released_at = $timestamp |
            .updated_at = $timestamp' \
           "$TOKEN_BUDGET_FILE" > "$temp_file"
    fi

    mv "$temp_file" "$TOKEN_BUDGET_FILE"
    release_lock

    echo "Released $allocation tokens from $worker_id"
}

# Reclaim tokens from stale allocations (timeout)
# Args: $1 = timeout_minutes (default: 60)
reclaim_stale_tokens() {
    local timeout_minutes="${1:-60}"
    local timeout_seconds=$((timeout_minutes * 60))
    local current_time=$(date +%s)
    local reclaimed=0
    local workers_cleaned=0

    acquire_lock || return 1
    trap release_lock EXIT

    # Get all allocations
    local allocations=$(jq -r '.allocations | keys[]' "$TOKEN_BUDGET_FILE" 2>/dev/null || echo "")

    for worker_id in $allocations; do
        local status=$(jq -r --arg w "$worker_id" '.allocations[$w].status' "$TOKEN_BUDGET_FILE")
        local allocated_at=$(jq -r --arg w "$worker_id" '.allocations[$w].allocated_at' "$TOKEN_BUDGET_FILE")

        if [ "$status" = "released" ]; then
            continue
        fi

        # Calculate age
        local alloc_time=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$allocated_at" +%s 2>/dev/null || echo "0")
        local age=$((current_time - alloc_time))

        if [ "$age" -gt "$timeout_seconds" ]; then
            local tokens=$(jq -r --arg w "$worker_id" '.allocations[$w].tokens' "$TOKEN_BUDGET_FILE")
            reclaimed=$((reclaimed + tokens))
            workers_cleaned=$((workers_cleaned + 1))

            # Mark as reclaimed
            local temp_file=$(mktemp)
            if [ "$status" = "in_use" ]; then
                jq --arg worker_id "$worker_id" \
                   --argjson tokens "$tokens" \
                   '.in_use -= $tokens | .available += $tokens | .allocations[$worker_id].status = "reclaimed"' \
                   "$TOKEN_BUDGET_FILE" > "$temp_file"
            else
                jq --arg worker_id "$worker_id" \
                   --argjson tokens "$tokens" \
                   '.allocated -= $tokens | .available += $tokens | .allocations[$worker_id].status = "reclaimed"' \
                   "$TOKEN_BUDGET_FILE" > "$temp_file"
            fi
            mv "$temp_file" "$TOKEN_BUDGET_FILE"
        fi
    done

    # Log reclamation
    if [ "$reclaimed" -gt 0 ]; then
        local temp_file=$(mktemp)
        jq --argjson tokens "$reclaimed" \
           --argjson count "$workers_cleaned" \
           --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --argjson timeout "$timeout_minutes" \
           '.reclamation_log += [{
              timestamp: $timestamp,
              tokens_reclaimed: $tokens,
              reason: "timeout",
              worker_count: $count,
              timeout_minutes: $timeout
            }] |
            .updated_at = $timestamp' \
           "$TOKEN_BUDGET_FILE" > "$temp_file"
        mv "$temp_file" "$TOKEN_BUDGET_FILE"
    fi

    release_lock
    echo "Reclaimed $reclaimed tokens from $workers_cleaned stale workers"
}

# Clean up old released allocations (keep last 100)
cleanup_allocation_history() {
    acquire_lock || return 1
    trap release_lock EXIT

    local temp_file=$(mktemp)
    jq '.allocations = (.allocations | to_entries |
        map(select(.value.status != "released")) |
        from_entries)' \
       "$TOKEN_BUDGET_FILE" > "$temp_file"

    mv "$temp_file" "$TOKEN_BUDGET_FILE"
    release_lock

    echo "Cleaned up released allocations"
}

# Get budget summary
get_budget_summary() {
    jq '{
      total_budget: .total_budget,
      allocated: .allocated,
      in_use: .in_use,
      available: .available,
      utilization_percent: ((.allocated + .in_use) / .total_budget * 100 | floor),
      active_allocations: (.allocations | to_entries | map(select(.value.status != "released" and .value.status != "reclaimed")) | length)
    }' "$TOKEN_BUDGET_FILE"
}

# Export functions
export -f acquire_lock release_lock get_budget_state get_available_tokens
export -f allocate_tokens start_using_tokens release_tokens
export -f reclaim_stale_tokens cleanup_allocation_history get_budget_summary
