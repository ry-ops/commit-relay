#!/usr/bin/env bash
#
# Trace Sampler Library for High-Volume Observability
# Part of Phase 3: Observability and Data Features
#
# Provides configurable trace sampling to reduce overhead while
# maintaining visibility into errors and slow operations.
#
# Sampling Strategies:
#   - Head-based: Decision made at trace start
#   - Tail-based: Decision made after trace complete (based on characteristics)
#
# Usage:
#   source scripts/lib/observability/trace-sampler.sh
#
#   # Configure sampling
#   export TRACE_SAMPLING_RATE="0.1"  # 10% sampling
#   export TRACE_SAMPLING_STRATEGY="head"
#
#   # Check if trace should be sampled
#   if should_sample_trace "my-trace-id"; then
#       start_span "operation"
#       # ... do work ...
#       end_span "ok"
#   fi
#

# Note: set -e disabled to allow graceful handling of jq failures and optional logging
set -uo pipefail

# Configuration via environment variables (mutable for dynamic adjustment)
TRACE_SAMPLING_RATE="${TRACE_SAMPLING_RATE:-1.0}"  # 0.0-1.0 (default: 100%)
TRACE_SAMPLING_STRATEGY="${TRACE_SAMPLING_STRATEGY:-head}"  # head, tail
TRACE_ALWAYS_SAMPLE_ERRORS="${TRACE_ALWAYS_SAMPLE_ERRORS:-true}"
TRACE_ALWAYS_SAMPLE_SLOW="${TRACE_ALWAYS_SAMPLE_SLOW:-true}"
TRACE_SLOW_THRESHOLD_MS="${TRACE_SLOW_THRESHOLD_MS:-5000}"  # 5 seconds
TRACE_SAMPLER_STATE_DIR="${TRACE_SAMPLER_STATE_DIR:-coordination/observability/sampler}"
TRACE_SAMPLING_DEBUG="${TRACE_SAMPLING_DEBUG:-false}"

# Sampling rate presets
readonly SAMPLING_RATE_1_PERCENT="0.01"
readonly SAMPLING_RATE_10_PERCENT="0.10"
readonly SAMPLING_RATE_50_PERCENT="0.50"
readonly SAMPLING_RATE_100_PERCENT="1.0"

# Initialize state directory
mkdir -p "$TRACE_SAMPLER_STATE_DIR" 2>/dev/null || true

# Sampling decision cache file (for consistent sampling within a trace)
# Using file-based cache to avoid associative array issues in older bash
SAMPLING_CACHE_FILE="${TRACE_SAMPLER_STATE_DIR}/sampling-cache-$$.tmp"

#
# Internal: Get cached sampling decision
#
_get_sampling_decision() {
    local trace_id="$1"
    if [[ -f "$SAMPLING_CACHE_FILE" ]]; then
        grep "^${trace_id}:" "$SAMPLING_CACHE_FILE" 2>/dev/null | cut -d: -f2 || echo ""
    else
        echo ""
    fi
}

#
# Internal: Set cached sampling decision
#
_set_sampling_decision() {
    local trace_id="$1"
    local decision="$2"
    echo "${trace_id}:${decision}" >> "$SAMPLING_CACHE_FILE"
}

# Cleanup cache on exit
trap "rm -f $SAMPLING_CACHE_FILE" EXIT

#
# Generate a random float between 0 and 1
#
_generate_random_float() {
    # Use /dev/urandom for high-quality randomness
    local random_value
    if [[ -r /dev/urandom ]]; then
        random_value=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        echo "scale=6; $random_value / 65535" | bc
    else
        # Fallback to RANDOM
        echo "scale=6; $RANDOM / 32767" | bc
    fi
}

#
# Hash a string to a deterministic value between 0 and 1
# Used for consistent sampling based on trace ID
#
_hash_to_float() {
    local input="$1"

    # Use md5 or shasum for hashing
    local hash
    if command -v md5sum >/dev/null 2>&1; then
        hash=$(echo -n "$input" | md5sum | cut -d' ' -f1)
    elif command -v md5 >/dev/null 2>&1; then
        hash=$(echo -n "$input" | md5)
    else
        # Fallback: use simple string hash
        local sum=0
        for (( i=0; i<${#input}; i++ )); do
            sum=$(( (sum * 31 + $(printf '%d' "'${input:$i:1}")) % 65536 ))
        done
        echo "scale=6; $sum / 65536" | bc
        return
    fi

    # Convert first 4 hex chars to decimal and normalize
    local hex_value="${hash:0:4}"
    local decimal_value=$((16#$hex_value))
    echo "scale=6; $decimal_value / 65535" | bc
}

#
# Check if a trace should be sampled (head-based decision)
#
# Args:
#   $1 - trace_id: Trace identifier for consistent sampling
#   $2 - attributes: Optional JSON attributes for priority-based sampling
#
# Returns:
#   0 (true) if trace should be sampled
#   1 (false) if trace should be dropped
#
should_sample_trace() {
    local trace_id="${1:-$(date +%s%N)}"
    local attributes="${2:-{}}"

    # Check if we've already made a decision for this trace
    local cached_decision
    cached_decision=$(_get_sampling_decision "$trace_id")
    if [[ -n "$cached_decision" ]]; then
        [[ "$cached_decision" == "true" ]] && return 0 || return 1
    fi

    # Parse priority from attributes (high priority always sampled)
    local priority
    priority=$(echo "$attributes" | jq -r '.priority // "normal"' 2>/dev/null || echo "normal")
    if [[ "$priority" == "critical" || "$priority" == "high" ]]; then
        _set_sampling_decision "$trace_id" "true"
        _log_sampling_decision "$trace_id" "sampled" "high_priority"
        return 0
    fi

    # Check for explicit sampling flag in attributes
    local force_sample
    force_sample=$(echo "$attributes" | jq -r '.force_sample // false' 2>/dev/null || echo "false")
    if [[ "$force_sample" == "true" ]]; then
        _set_sampling_decision "$trace_id" "true"
        _log_sampling_decision "$trace_id" "sampled" "force_sample"
        return 0
    fi

    # Calculate sampling decision based on rate
    local random_value
    random_value=$(_hash_to_float "$trace_id")

    # Compare with sampling rate
    local should_sample
    should_sample=$(echo "$random_value < $TRACE_SAMPLING_RATE" | bc)

    if [[ "$should_sample" == "1" ]]; then
        _set_sampling_decision "$trace_id" "true"
        _log_sampling_decision "$trace_id" "sampled" "random"
        return 0
    else
        _set_sampling_decision "$trace_id" "false"
        _log_sampling_decision "$trace_id" "dropped" "random"
        return 1
    fi
}

#
# Tail-based sampling decision (after trace completion)
#
# Args:
#   $1 - trace_id: Trace identifier
#   $2 - status: Trace status (ok, error)
#   $3 - duration_ms: Trace duration in milliseconds
#   $4 - attributes: Optional JSON attributes
#
# Returns:
#   0 (true) if trace should be kept
#   1 (false) if trace should be dropped
#
should_keep_trace() {
    local trace_id="$1"
    local status="${2:-ok}"
    local duration_ms="${3:-0}"
    local attributes="${4:-{}}"

    # Always keep errors if configured
    if [[ "$TRACE_ALWAYS_SAMPLE_ERRORS" == "true" && "$status" == "error" ]]; then
        _log_sampling_decision "$trace_id" "kept" "error"
        return 0
    fi

    # Always keep slow traces if configured
    if [[ "$TRACE_ALWAYS_SAMPLE_SLOW" == "true" ]]; then
        if [[ $duration_ms -ge $TRACE_SLOW_THRESHOLD_MS ]]; then
            _log_sampling_decision "$trace_id" "kept" "slow_trace"
            return 0
        fi
    fi

    # Check for important attributes
    local has_exception
    has_exception=$(echo "$attributes" | jq -r 'has("exception") or has("error_message")' 2>/dev/null || echo "false")
    if [[ "$has_exception" == "true" ]]; then
        _log_sampling_decision "$trace_id" "kept" "exception"
        return 0
    fi

    # Apply base sampling rate for normal traces
    local random_value
    random_value=$(_hash_to_float "$trace_id")

    local should_keep
    should_keep=$(echo "$random_value < $TRACE_SAMPLING_RATE" | bc)

    if [[ "$should_keep" == "1" ]]; then
        _log_sampling_decision "$trace_id" "kept" "random"
        return 0
    else
        _log_sampling_decision "$trace_id" "dropped" "random"
        return 1
    fi
}

#
# Create a sampled trace context
# Wraps trace creation with sampling decision
#
# Args:
#   $1 - operation_name: Name of the operation
#   $2 - attributes: JSON attributes
#
# Returns:
#   trace_id if sampled, empty string if not
#
create_sampled_trace() {
    local operation_name="${1:-root_operation}"
    local attributes="${2:-{}}"

    # Generate trace ID first
    local trace_id
    trace_id="trace-$(date +%s%N | cut -b1-13)-$(openssl rand -hex 6)"

    # Check sampling decision
    if should_sample_trace "$trace_id" "$attributes"; then
        export TRACE_ID="$trace_id"
        export TRACE_SAMPLED="true"

        # Record sampling decision in trace attributes
        local enhanced_attrs
        enhanced_attrs=$(echo "$attributes" | jq \
            --arg rate "$TRACE_SAMPLING_RATE" \
            --arg strategy "$TRACE_SAMPLING_STRATEGY" \
            '. + {
                "sampling.rate": ($rate | tonumber),
                "sampling.strategy": $strategy,
                "sampling.sampled": true
            }')

        echo "$trace_id"
    else
        export TRACE_ID=""
        export TRACE_SAMPLED="false"
        echo ""
    fi
}

#
# Get current sampling rate configuration
#
get_sampling_config() {
    jq -n \
        --arg rate "$TRACE_SAMPLING_RATE" \
        --arg strategy "$TRACE_SAMPLING_STRATEGY" \
        --arg always_errors "$TRACE_ALWAYS_SAMPLE_ERRORS" \
        --arg always_slow "$TRACE_ALWAYS_SAMPLE_SLOW" \
        --arg slow_threshold "$TRACE_SLOW_THRESHOLD_MS" \
        '{
            sampling_rate: ($rate | tonumber),
            strategy: $strategy,
            always_sample_errors: ($always_errors == "true"),
            always_sample_slow: ($always_slow == "true"),
            slow_threshold_ms: ($slow_threshold | tonumber)
        }'
}

#
# Set sampling rate dynamically
#
# Args:
#   $1 - rate: Sampling rate (0.0 to 1.0 or preset name)
#
set_sampling_rate() {
    local rate="$1"

    # Handle presets
    case "$rate" in
        "1%"|"1_percent")
            rate="$SAMPLING_RATE_1_PERCENT"
            ;;
        "10%"|"10_percent")
            rate="$SAMPLING_RATE_10_PERCENT"
            ;;
        "50%"|"50_percent")
            rate="$SAMPLING_RATE_50_PERCENT"
            ;;
        "100%"|"100_percent"|"all")
            rate="$SAMPLING_RATE_100_PERCENT"
            ;;
    esac

    # Validate rate
    local is_valid
    is_valid=$(echo "$rate >= 0 && $rate <= 1" | bc)
    if [[ "$is_valid" != "1" ]]; then
        echo "Error: Invalid sampling rate '$rate'. Must be between 0.0 and 1.0" >&2
        return 1
    fi

    export TRACE_SAMPLING_RATE="$rate"

    # Log configuration change
    _log_sampling_event "config_change" "{\"new_rate\": $rate}"
}

#
# Get sampling statistics
#
get_sampling_stats() {
    local stats_file="$TRACE_SAMPLER_STATE_DIR/sampling-stats.json"

    if [[ -f "$stats_file" ]]; then
        cat "$stats_file"
    else
        jq -n '{
            total_decisions: 0,
            sampled: 0,
            dropped: 0,
            kept_for_errors: 0,
            kept_for_slow: 0,
            sampling_rate: 0
        }'
    fi
}

#
# Update sampling statistics
#
_update_sampling_stats() {
    local decision="$1"
    local reason="$2"

    # Ensure directory exists
    mkdir -p "$TRACE_SAMPLER_STATE_DIR" 2>/dev/null || true

    local stats_file="$TRACE_SAMPLER_STATE_DIR/sampling-stats.json"
    local timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    # Initialize stats if needed
    if [[ ! -f "$stats_file" ]]; then
        jq -n \
            --arg rate "$TRACE_SAMPLING_RATE" \
            '{
                total_decisions: 0,
                sampled: 0,
                dropped: 0,
                kept_for_errors: 0,
                kept_for_slow: 0,
                sampling_rate: ($rate | tonumber),
                last_updated: ""
            }' > "$stats_file"
    fi

    # Update stats atomically
    local temp_file="${stats_file}.tmp"

    case "$decision" in
        "sampled"|"kept")
            jq \
                --arg timestamp "$timestamp" \
                --arg reason "$reason" \
                '.total_decisions += 1 |
                 .sampled += 1 |
                 (if $reason == "error" then .kept_for_errors += 1 else . end) |
                 (if $reason == "slow_trace" then .kept_for_slow += 1 else . end) |
                 .last_updated = $timestamp' \
                "$stats_file" > "$temp_file" && mv "$temp_file" "$stats_file"
            ;;
        "dropped")
            jq \
                --arg timestamp "$timestamp" \
                '.total_decisions += 1 |
                 .dropped += 1 |
                 .last_updated = $timestamp' \
                "$stats_file" > "$temp_file" && mv "$temp_file" "$stats_file"
            ;;
    esac
}

#
# Log sampling decision for debugging
#
_log_sampling_decision() {
    local trace_id="$1"
    local decision="$2"
    local reason="$3"

    # Update statistics
    _update_sampling_stats "$decision" "$reason"

    # Debug logging
    if [[ "$TRACE_SAMPLING_DEBUG" == "true" ]]; then
        local timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
        local log_entry
        log_entry=$(jq -nc \
            --arg timestamp "$timestamp" \
            --arg trace_id "$trace_id" \
            --arg decision "$decision" \
            --arg reason "$reason" \
            --arg rate "$TRACE_SAMPLING_RATE" \
            '{
                timestamp: $timestamp,
                trace_id: $trace_id,
                decision: $decision,
                reason: $reason,
                sampling_rate: ($rate | tonumber)
            }')

        echo "$log_entry" >> "$TRACE_SAMPLER_STATE_DIR/sampling-decisions.jsonl"
    fi
}

#
# Log sampling events (config changes, etc.)
#
_log_sampling_event() {
    local event_type="$1"
    local event_data="$2"

    # Ensure directory exists
    mkdir -p "$TRACE_SAMPLER_STATE_DIR" 2>/dev/null || true

    local timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
    local log_entry
    log_entry=$(jq -nc \
        --arg timestamp "$timestamp" \
        --arg event_type "$event_type" \
        --argjson event_data "$event_data" \
        '{
            timestamp: $timestamp,
            event_type: $event_type,
            data: $event_data
        }')

    echo "$log_entry" >> "$TRACE_SAMPLER_STATE_DIR/sampling-events.jsonl"
}

#
# Reset sampling statistics
#
reset_sampling_stats() {
    local stats_file="$TRACE_SAMPLER_STATE_DIR/sampling-stats.json"

    jq -n \
        --arg rate "$TRACE_SAMPLING_RATE" \
        --arg timestamp "$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")" \
        '{
            total_decisions: 0,
            sampled: 0,
            dropped: 0,
            kept_for_errors: 0,
            kept_for_slow: 0,
            sampling_rate: ($rate | tonumber),
            last_updated: $timestamp
        }' > "$stats_file"
}

#
# Cleanup old sampling decision logs
#
cleanup_sampling_logs() {
    local retention_days="${1:-7}"

    find "$TRACE_SAMPLER_STATE_DIR" -name "*.jsonl" -mtime +$retention_days -delete 2>/dev/null || true
}

#
# Adaptive sampling: Adjust rate based on volume
#
# Args:
#   $1 - current_volume: Current traces per minute
#   $2 - target_volume: Target traces per minute to keep
#
calculate_adaptive_rate() {
    local current_volume="$1"
    local target_volume="${2:-1000}"

    if [[ $current_volume -le $target_volume ]]; then
        echo "1.0"
        return
    fi

    # Calculate rate to achieve target volume
    local rate
    rate=$(echo "scale=4; $target_volume / $current_volume" | bc)

    # Apply minimum rate (never go below 1%)
    local min_rate="0.01"
    local final_rate
    final_rate=$(echo "if ($rate < $min_rate) $min_rate else $rate" | bc)

    echo "$final_rate"
}

#
# Priority-based sampling weight
# Higher priority traces get higher sampling probability
#
# Args:
#   $1 - priority: trace priority (critical, high, normal, low)
#
# Returns:
#   Sampling weight multiplier
#
get_priority_weight() {
    local priority="${1:-normal}"

    case "$priority" in
        "critical")
            echo "1.0"  # Always sample
            ;;
        "high")
            echo "0.8"  # High probability
            ;;
        "normal")
            echo "0.5"  # Normal
            ;;
        "low")
            echo "0.2"  # Low priority
            ;;
        *)
            echo "0.5"
            ;;
    esac
}

#
# Integrate with trace.sh - wrapped span creation
#
# Args:
#   $1 - span_name: Name of the span
#   $2 - attributes: JSON attributes
#   $3 - kind: Span kind
#
# Returns:
#   span_id if sampled, empty if not
#
sampled_start_span() {
    local span_name="${1:-unnamed_span}"
    local attributes="${2:-{}}"
    local kind="${3:-internal}"

    # If we don't have a trace yet, check sampling
    if [[ -z "${TRACE_ID:-}" ]]; then
        local trace_id
        trace_id=$(create_sampled_trace "$span_name" "$attributes")

        if [[ -z "$trace_id" ]]; then
            # Not sampled, return empty
            echo ""
            return 1
        fi
    fi

    # Check if current trace is sampled
    if [[ "${TRACE_SAMPLED:-true}" != "true" ]]; then
        echo ""
        return 1
    fi

    # Delegate to trace.sh start_span if available
    if declare -f start_span >/dev/null 2>&1; then
        start_span "$span_name" "$attributes" "$kind"
    else
        echo "${SPAN_ID:-}"
    fi
}

#
# Wrapped span end with tail-based decision
#
sampled_end_span() {
    local status="${1:-ok}"
    local error_message="${2:-}"

    # Get span duration for tail-based sampling
    local duration_ms="${SPAN_DURATION_MS:-0}"

    # Make tail-based decision if using tail strategy
    if [[ "$TRACE_SAMPLING_STRATEGY" == "tail" ]]; then
        if ! should_keep_trace "${TRACE_ID:-}" "$status" "$duration_ms"; then
            # Mark trace as dropped
            export TRACE_SAMPLED="false"
            return 0
        fi
    fi

    # Delegate to trace.sh end_span if available
    if declare -f end_span >/dev/null 2>&1; then
        end_span "$status" "$error_message"
    fi
}

# Export functions
export -f should_sample_trace
export -f should_keep_trace
export -f create_sampled_trace
export -f get_sampling_config
export -f set_sampling_rate
export -f get_sampling_stats
export -f reset_sampling_stats
export -f cleanup_sampling_logs
export -f calculate_adaptive_rate
export -f get_priority_weight
export -f sampled_start_span
export -f sampled_end_span
