#!/bin/bash
# scripts/lib/heartbeat.sh
# Worker Heartbeat Library - Phase 4.1 Self-Healing Implementation
# Provides heartbeat emission and health monitoring capabilities for workers
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/heartbeat.sh"
#   init_heartbeat "$WORKER_ID"
#   emit_heartbeat "$WORKER_ID" "Processing task analysis"
#
# Dependencies:
#   - jq (JSON processing)
#   - ps (process monitoring)
#   - date (timestamp generation)

# Heartbeat configuration
HEARTBEAT_INTERVAL_SECONDS=${HEARTBEAT_INTERVAL_SECONDS:-30}
HEARTBEAT_WARNING_THRESHOLD=${HEARTBEAT_WARNING_THRESHOLD:-60}
HEARTBEAT_CRITICAL_THRESHOLD=${HEARTBEAT_CRITICAL_THRESHOLD:-120}
HEARTBEAT_ZOMBIE_THRESHOLD=${HEARTBEAT_ZOMBIE_THRESHOLD:-300}

# ============================================================================
# Heartbeat Initialization
# ============================================================================

# Initialize heartbeat tracking for a worker
# Args:
#   $1: worker_id
# Returns:
#   0 on success, 1 on failure
init_heartbeat() {
    local worker_id="$1"

    if [ -z "$worker_id" ]; then
        echo "[ERROR] init_heartbeat: worker_id required" >&2
        return 1
    fi

    local worker_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "[ERROR] init_heartbeat: Worker spec not found: $worker_spec" >&2
        return 1
    fi

    # Initialize heartbeat object in worker spec
    local current_time=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Use jq to add heartbeat object
    local temp_file="${worker_spec}.tmp"
    jq --arg timestamp "$current_time" '
        .heartbeat = {
            "last_heartbeat": $timestamp,
            "heartbeat_sequence": 0,
            "health": {
                "status": "healthy",
                "cpu_usage_percent": 0,
                "memory_usage_mb": 0,
                "tokens_used": 0,
                "tokens_remaining": (.resources.token_allocation // 0),
                "active_for_seconds": 0,
                "last_activity": "initialized"
            },
            "warnings": [],
            "missed_count": 0
        }
    ' "$worker_spec" > "$temp_file"

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$worker_spec"
        echo "[INFO] Heartbeat initialized for $worker_id" >&2
        return 0
    else
        rm -f "$temp_file"
        echo "[ERROR] init_heartbeat: Failed to update worker spec" >&2
        return 1
    fi
}

# ============================================================================
# Health Metrics Collection
# ============================================================================

# Get CPU usage for current process
# Returns: CPU usage percentage
get_cpu_usage() {
    local pid=$$
    ps -p $pid -o %cpu= 2>/dev/null | awk '{print $1}' || echo "0"
}

# Get memory usage for current process
# Returns: Memory usage in MB
get_memory_usage() {
    local pid=$$
    # Get RSS in KB and convert to MB
    local rss_kb=$(ps -p $pid -o rss= 2>/dev/null | awk '{print $1}')
    if [ -n "$rss_kb" ]; then
        echo "scale=2; $rss_kb / 1024" | bc
    else
        echo "0"
    fi
}

# Calculate health score (0-100) based on metrics
# Args:
#   $1: cpu_usage_percent
#   $2: memory_usage_mb
#   $3: tokens_used
#   $4: tokens_remaining
# Returns: Health score
calculate_health_score() {
    local cpu_usage="$1"
    local memory_usage="$2"
    local tokens_used="$3"
    local tokens_remaining="$4"

    local score=100

    # Deduct points for high CPU (>80% = -30 points)
    if [ $(echo "$cpu_usage > 80" | bc) -eq 1 ]; then
        score=$((score - 30))
    elif [ $(echo "$cpu_usage > 60" | bc) -eq 1 ]; then
        score=$((score - 15))
    fi

    # Deduct points for high memory (>1GB = -30 points)
    if [ $(echo "$memory_usage > 1024" | bc) -eq 1 ]; then
        score=$((score - 30))
    elif [ $(echo "$memory_usage > 512" | bc) -eq 1 ]; then
        score=$((score - 15))
    fi

    # Deduct points for low tokens remaining (<10% = -40 points)
    local total_tokens=$((tokens_used + tokens_remaining))
    if [ $total_tokens -gt 0 ]; then
        local token_pct=$(echo "scale=2; $tokens_remaining * 100 / $total_tokens" | bc)
        if [ $(echo "$token_pct < 10" | bc) -eq 1 ]; then
            score=$((score - 40))
        elif [ $(echo "$token_pct < 25" | bc) -eq 1 ]; then
            score=$((score - 20))
        fi
    fi

    # Ensure score is in 0-100 range
    if [ $score -lt 0 ]; then
        score=0
    fi

    echo "$score"
}

# Determine health status based on health score
# Args:
#   $1: health_score (0-100)
# Returns: "healthy", "degraded", or "unhealthy"
get_health_status_from_score() {
    local score="$1"

    if [ $score -ge 80 ]; then
        echo "healthy"
    elif [ $score -ge 50 ]; then
        echo "degraded"
    else
        echo "unhealthy"
    fi
}

# ============================================================================
# Heartbeat Emission
# ============================================================================

# Check if heartbeat is due (30s since last)
# Args:
#   $1: worker_id
# Returns: 0 if due, 1 if not due
is_heartbeat_due() {
    local worker_id="$1"
    local worker_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        return 0  # No spec means no heartbeat yet, so it's due
    fi

    local last_hb=$(jq -r '.heartbeat.last_heartbeat // empty' "$worker_spec" 2>/dev/null)

    if [ -z "$last_hb" ] || [ "$last_hb" = "null" ]; then
        return 0  # No heartbeat yet, so it's due
    fi

    # Calculate time since last heartbeat
    local current_time=$(date +%s)
    local last_hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$last_hb" +%s 2>/dev/null || echo 0)
    local time_since_hb=$((current_time - last_hb_epoch))

    if [ $time_since_hb -ge $HEARTBEAT_INTERVAL_SECONDS ]; then
        return 0  # Due
    else
        return 1  # Not due
    fi
}

# Emit a heartbeat with current health metrics
# Args:
#   $1: worker_id
#   $2: status_message (optional - describes current activity)
# Returns: 0 on success, 1 on failure
emit_heartbeat() {
    local worker_id="$1"
    local status_message="${2:-processing}"

    if [ -z "$worker_id" ]; then
        echo "[ERROR] emit_heartbeat: worker_id required" >&2
        return 1
    fi

    local worker_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "[WARN] emit_heartbeat: Worker spec not found, initializing: $worker_spec" >&2
        init_heartbeat "$worker_id"
    fi

    # Collect health metrics
    local cpu_usage=$(get_cpu_usage)
    local memory_usage=$(get_memory_usage)
    local current_time=$(date +%Y-%m-%dT%H:%M:%S%z)
    local current_epoch=$(date +%s)

    # Get tokens used from worker spec (or default to 0)
    local tokens_used=$(jq -r '.execution.tokens_used // 0' "$worker_spec" 2>/dev/null)
    local token_allocation=$(jq -r '.resources.token_allocation // 0' "$worker_spec" 2>/dev/null)
    local tokens_remaining=$((token_allocation - tokens_used))

    # Calculate active duration
    local started_at=$(jq -r '.execution.started_at // empty' "$worker_spec" 2>/dev/null)
    local active_for_seconds=0
    if [ -n "$started_at" ] && [ "$started_at" != "null" ]; then
        local started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$started_at" +%s 2>/dev/null || echo $current_epoch)
        active_for_seconds=$((current_epoch - started_epoch))
    fi

    # Get current sequence number
    local sequence=$(jq -r '.heartbeat.heartbeat_sequence // 0' "$worker_spec" 2>/dev/null)
    local next_sequence=$((sequence + 1))

    # Calculate health score
    local health_score=$(calculate_health_score "$cpu_usage" "$memory_usage" "$tokens_used" "$tokens_remaining")
    local health_status=$(get_health_status_from_score "$health_score")

    # Update heartbeat in worker spec
    local temp_file="${worker_spec}.tmp"
    jq --arg timestamp "$current_time" \
       --argjson sequence "$next_sequence" \
       --arg cpu "$cpu_usage" \
       --arg memory "$memory_usage" \
       --argjson tokens_used "$tokens_used" \
       --argjson tokens_remaining "$tokens_remaining" \
       --argjson active "$active_for_seconds" \
       --arg activity "$status_message" \
       --arg status "$health_status" \
       --argjson score "$health_score" '
        .heartbeat.last_heartbeat = $timestamp |
        .heartbeat.heartbeat_sequence = $sequence |
        .heartbeat.health.status = $status |
        .heartbeat.health.health_score = $score |
        .heartbeat.health.cpu_usage_percent = ($cpu | tonumber) |
        .heartbeat.health.memory_usage_mb = ($memory | tonumber) |
        .heartbeat.health.tokens_used = $tokens_used |
        .heartbeat.health.tokens_remaining = $tokens_remaining |
        .heartbeat.health.active_for_seconds = $active |
        .heartbeat.health.last_activity = $activity |
        .heartbeat.missed_count = 0
    ' "$worker_spec" > "$temp_file"

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$worker_spec"
        echo "[DEBUG] Heartbeat #$next_sequence emitted for $worker_id (health: $health_status, score: $health_score)" >&2
        return 0
    else
        rm -f "$temp_file"
        echo "[ERROR] emit_heartbeat: Failed to update worker spec" >&2
        return 1
    fi
}

# ============================================================================
# Heartbeat Monitoring Utilities
# ============================================================================

# Calculate time since last heartbeat (in seconds)
# Args:
#   $1: worker_id
# Returns: Seconds since last heartbeat
get_time_since_heartbeat() {
    local worker_id="$1"
    local worker_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${worker_id}.json"

    if [ ! -f "$worker_spec" ]; then
        echo "9999"  # Return high value if spec doesn't exist
        return
    fi

    local last_hb=$(jq -r '.heartbeat.last_heartbeat // empty' "$worker_spec" 2>/dev/null)

    if [ -z "$last_hb" ] || [ "$last_hb" = "null" ]; then
        echo "9999"  # Return high value if no heartbeat yet
        return
    fi

    local current_time=$(date +%s)
    local last_hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$last_hb" +%s 2>/dev/null || echo 0)

    if [ $last_hb_epoch -eq 0 ]; then
        echo "9999"
        return
    fi

    echo $((current_time - last_hb_epoch))
}

# Check if worker heartbeat is in warning state
# Args:
#   $1: worker_id
# Returns: 0 if warning, 1 if not
is_heartbeat_warning() {
    local worker_id="$1"
    local time_since=$(get_time_since_heartbeat "$worker_id")

    if [ $time_since -ge $HEARTBEAT_WARNING_THRESHOLD ] && [ $time_since -lt $HEARTBEAT_CRITICAL_THRESHOLD ]; then
        return 0
    else
        return 1
    fi
}

# Check if worker heartbeat is in critical state
# Args:
#   $1: worker_id
# Returns: 0 if critical, 1 if not
is_heartbeat_critical() {
    local worker_id="$1"
    local time_since=$(get_time_since_heartbeat "$worker_id")

    if [ $time_since -ge $HEARTBEAT_CRITICAL_THRESHOLD ] && [ $time_since -lt $HEARTBEAT_ZOMBIE_THRESHOLD ]; then
        return 0
    else
        return 1
    fi
}

# Check if worker should be marked as zombie
# Args:
#   $1: worker_id
# Returns: 0 if zombie, 1 if not
is_heartbeat_zombie() {
    local worker_id="$1"
    local time_since=$(get_time_since_heartbeat "$worker_id")

    if [ $time_since -ge $HEARTBEAT_ZOMBIE_THRESHOLD ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Export Functions (for testing)
# ============================================================================

# Export functions for external use
export -f init_heartbeat
export -f emit_heartbeat
export -f is_heartbeat_due
export -f get_cpu_usage
export -f get_memory_usage
export -f calculate_health_score
export -f get_health_status_from_score
export -f get_time_since_heartbeat
export -f is_heartbeat_warning
export -f is_heartbeat_critical
export -f is_heartbeat_zombie

echo "[INFO] Heartbeat library loaded (interval: ${HEARTBEAT_INTERVAL_SECONDS}s, warning: ${HEARTBEAT_WARNING_THRESHOLD}s, critical: ${HEARTBEAT_CRITICAL_THRESHOLD}s)" >&2
