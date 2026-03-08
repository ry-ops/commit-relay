#!/bin/bash
# scripts/lib/failure-pattern-detection.sh
# Failure Pattern Detection Library - Phase 4.4
# Analyzes worker failures to identify patterns and predict future failures
#
# Features:
#   - Failure event ingestion and normalization
#   - Pattern detection (frequency, temporal, correlation)
#   - Failure categorization
#   - Pattern confidence scoring
#   - Predictive analytics
#   - Observability integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load configuration
PATTERN_POLICY_FILE="$COMMIT_RELAY_HOME/coordination/config/failure-pattern-detection-policy.json"
if [ ! -f "$PATTERN_POLICY_FILE" ]; then
    echo "ERROR: Pattern detection policy file not found: $PATTERN_POLICY_FILE" >&2
    exit 1
fi

# Configuration values
ENABLED=$(jq -r '.enabled' "$PATTERN_POLICY_FILE")
FREQUENCY_THRESHOLD=$(jq -r '.detection.frequency_threshold' "$PATTERN_POLICY_FILE")
TIME_WINDOW_HOURS=$(jq -r '.detection.time_window_hours' "$PATTERN_POLICY_FILE")
SIMILARITY_THRESHOLD=$(jq -r '.detection.similarity_threshold' "$PATTERN_POLICY_FILE")
CORRELATION_WINDOW=$(jq -r '.correlation_analysis.correlation_window_seconds' "$PATTERN_POLICY_FILE")

# Directories
PATTERNS_DIR="$COMMIT_RELAY_HOME/coordination/patterns"
PATTERN_DB="$PATTERNS_DIR/failure-patterns.jsonl"
PATTERN_INDEX="$PATTERNS_DIR/pattern-index.json"
PATTERN_LOG="$COMMIT_RELAY_HOME/agents/logs/system/failure-pattern-detection.log"

# Event sources
ZOMBIE_EVENTS="$COMMIT_RELAY_HOME/coordination/events/zombie-cleanup-events.jsonl"
RESTART_EVENTS="$COMMIT_RELAY_HOME/coordination/events/worker-restart-events.jsonl"
HEARTBEAT_EVENTS="$COMMIT_RELAY_HOME/coordination/events/heartbeat-events.jsonl"

# Ensure directories exist
mkdir -p "$PATTERNS_DIR"
mkdir -p "$(dirname "$PATTERN_LOG")"

# Initialize pattern database if not exists
if [ ! -f "$PATTERN_DB" ]; then
    touch "$PATTERN_DB"
fi

# Initialize pattern index if not exists
if [ ! -f "$PATTERN_INDEX" ]; then
    echo '{"patterns_by_category":{},"patterns_by_worker_type":{},"patterns_by_severity":{},"total_patterns":0,"last_updated":""}' > "$PATTERN_INDEX"
fi

log_pattern() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1" | tee -a "$PATTERN_LOG" >&2
}

##############################################################################
# generate_pattern_id: Create unique pattern ID
# Args: category, type, worker_type
# Returns: pattern ID string
##############################################################################
generate_pattern_id() {
    local category="$1"
    local type="$2"
    local worker_type="${3:-unknown}"

    local timestamp=$(date +%s)
    local hash=$(echo "${category}_${type}_${worker_type}" | md5sum | cut -c1-8 2>/dev/null || echo "${category}_${type}_${worker_type}" | md5 | cut -c1-8)

    echo "pattern_${category}_${hash}"
}

##############################################################################
# classify_failure: Categorize a failure event
# Args: event_json
# Returns: category and type
##############################################################################
classify_failure() {
    local event_json="$1"

    local event_type=$(echo "$event_json" | jq -r '.event_type')
    local worker_id=$(echo "$event_json" | jq -r '.worker_id // "unknown"')

    # Analyze event type and data to classify
    case "$event_type" in
        "zombie_detected"|"worker_presumed_dead")
            # Check if it's resource-related
            if echo "$event_json" | jq -e '.data.final_memory_usage // false' > /dev/null 2>&1; then
                echo "resource:out_of_memory"
            elif echo "$event_json" | jq -e '.data.timeout // false' > /dev/null 2>&1; then
                echo "resource:timeout"
            else
                echo "resource:unresponsive"
            fi
            ;;
        "worker_restart_abandoned")
            echo "systemic:max_retries_exceeded"
            ;;
        "circuit_breaker_tripped")
            echo "systemic:recurring_failure"
            ;;
        "heartbeat_critical")
            echo "resource:degraded_performance"
            ;;
        *)
            echo "unknown:unclassified"
            ;;
    esac
}

##############################################################################
# extract_failure_signature: Extract identifying characteristics
# Args: event_json
# Returns: signature JSON
##############################################################################
extract_failure_signature() {
    local event_json="$1"

    local event_type=$(echo "$event_json" | jq -r '.event_type')
    local worker_id=$(echo "$event_json" | jq -r '.worker_id // "unknown"')
    local timestamp=$(echo "$event_json" | jq -r '.timestamp')

    # Try to get worker spec to extract more details
    local worker_type="unknown"
    local task_id="unknown"

    # Optimized: Extract date from timestamp string directly (YYYY-MM-DD format)
    local zombie_date=$(echo "$timestamp" | cut -d'T' -f1)

    # Fallback to current date if extraction failed
    if [ -z "$zombie_date" ] || [ ${#zombie_date} -ne 10 ]; then
        zombie_date=$(date +%Y-%m-%d)
    fi

    local zombie_spec="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/$zombie_date/${worker_id}.json"

    if [ -f "$zombie_spec" ]; then
        worker_type=$(jq -r '.worker_type // "unknown"' "$zombie_spec" 2>/dev/null || echo "unknown")
        task_id=$(jq -r '.task_id // "unknown"' "$zombie_spec" 2>/dev/null || echo "unknown")
    fi

    # Build signature
    jq -nc \
        --arg event_type "$event_type" \
        --arg worker_type "$worker_type" \
        --arg worker_id "$worker_id" \
        --arg task_id "$task_id" \
        --arg timestamp "$timestamp" \
        '{
            event_type: $event_type,
            worker_type: $worker_type,
            worker_id: $worker_id,
            task_id: $task_id,
            timestamp: $timestamp
        }'
}

##############################################################################
# calculate_signature_similarity: Compare two signatures
# Args: signature1_json, signature2_json
# Returns: similarity score (0-1)
##############################################################################
calculate_signature_similarity() {
    local sig1="$1"
    local sig2="$2"

    local matches=0
    local total=0

    # Compare event_type
    ((total++))
    if [ "$(echo "$sig1" | jq -r '.event_type')" = "$(echo "$sig2" | jq -r '.event_type')" ]; then
        ((matches++))
    fi

    # Compare worker_type
    ((total++))
    if [ "$(echo "$sig1" | jq -r '.worker_type')" = "$(echo "$sig2" | jq -r '.worker_type')" ]; then
        ((matches++))
    fi

    # Calculate similarity
    echo "scale=2; $matches / $total" | bc
}

##############################################################################
# collect_recent_events: Get failure events from last N hours
# Args: hours
# Returns: array of event JSONs
##############################################################################
collect_recent_events() {
    local hours="${1:-24}"

    local cutoff_time=$(date -v-${hours}H +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -d "$hours hours ago" +%Y-%m-%dT%H:%M:%S%z)
    local cutoff_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$cutoff_time" +%s 2>/dev/null || date -d "$cutoff_time" +%s)

    local events=()

    # Collect from zombie events
    if [ -f "$ZOMBIE_EVENTS" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local event_time=$(echo "$line" | jq -r '.timestamp')
                local event_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$event_time" +%s 2>/dev/null || date -d "$event_time" +%s 2>/dev/null || echo "0")

                if [ "$event_epoch" -ge "$cutoff_epoch" ]; then
                    events+=("$line")
                fi
            fi
        done < "$ZOMBIE_EVENTS"
    fi

    # Collect from restart events
    if [ -f "$RESTART_EVENTS" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local event_time=$(echo "$line" | jq -r '.timestamp')
                local event_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$event_time" +%s 2>/dev/null || date -d "$event_time" +%s 2>/dev/null || echo "0")

                if [ "$event_epoch" -ge "$cutoff_epoch" ]; then
                    events+=("$line")
                fi
            fi
        done < "$RESTART_EVENTS"
    fi

    # Return as newline-separated
    printf '%s\n' "${events[@]}"
}

##############################################################################
# detect_frequent_patterns: Find patterns occurring >= threshold times
# Args: events (newline-separated)
# Returns: pattern JSONs
##############################################################################
detect_frequent_patterns() {
    local events="$1"

    log_pattern "INFO: Analyzing ${FREQUENCY_THRESHOLD}+ occurrences in ${TIME_WINDOW_HOURS}h window"

    # Simplified: Use temp file for counting
    local tmpfile="/tmp/pattern-count-$$.txt"
    > "$tmpfile"  # Create empty file

    # Extract signatures and count them
    while IFS= read -r event; do
        [ -z "$event" ] && continue

        local classification=$(classify_failure "$event" 2>/dev/null || echo "unknown:unknown")
        local category=$(echo "$classification" | cut -d: -f1)
        local type=$(echo "$classification" | cut -d: -f2)

        # Get worker_type from event directly to avoid expensive lookup
        local worker_id=$(echo "$event" | jq -r '.worker_id // "unknown"')
        local worker_type="unknown"

        # Only do file lookup if we have a valid worker_id
        if [ "$worker_id" != "unknown" ]; then
            local timestamp=$(echo "$event" | jq -r '.timestamp')
            local zombie_date=$(echo "$timestamp" | cut -d'T' -f1)
            local spec_file="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie/${zombie_date}/${worker_id}.json"

            if [ -f "$spec_file" ]; then
                worker_type=$(jq -r '.worker_type // "unknown"' "$spec_file" 2>/dev/null || echo "unknown")
            fi
        fi

        local sig_key="${category}_${type}_${worker_type}"
        echo "$sig_key|$event" >> "$tmpfile"
    done <<< "$events"

    # Count occurrences and find patterns
    local patterns=()

    # Sort and count unique signatures
    if [ -s "$tmpfile" ]; then
        while IFS='|' read -r sig_key first_event; do
            local count=$(grep -c "^${sig_key}|" "$tmpfile")

            if [ "$count" -ge "$FREQUENCY_THRESHOLD" ]; then
                local category=$(echo "$sig_key" | cut -d'_' -f1)
                local type=$(echo "$sig_key" | cut -d'_' -f2)
                local worker_type=$(echo "$sig_key" | cut -d'_' -f3-)

                local pattern_id=$(generate_pattern_id "$category" "$type" "$worker_type")

                # Calculate confidence
                local confidence="0.33"
                if [ "$count" -ge $((FREQUENCY_THRESHOLD * 3)) ]; then
                    confidence="1.00"
                elif [ "$count" -ge $((FREQUENCY_THRESHOLD * 2)) ]; then
                    confidence="0.67"
                fi

                # Create minimal signature
                local signature="{\"event_type\":\"$(echo "$first_event" | jq -r '.event_type')\",\"worker_type\":\"$worker_type\"}"

                # Create pattern
                local pattern=$(jq -nc \
                    --arg pattern_id "$pattern_id" \
                    --arg category "$category" \
                    --arg type "$type" \
                    --argjson signature "$signature" \
                    --argjson count "$count" \
                    --arg confidence "$confidence" \
                    --arg created_at "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                    '{
                        pattern_id: $pattern_id,
                        category: $category,
                        type: $type,
                        signature: $signature,
                        frequency: {total_occurrences: $count},
                        confidence: ($confidence | tonumber),
                        severity: "medium",
                        created_at: $created_at,
                        updated_at: $created_at
                    }')

                patterns+=("$pattern")
                log_pattern "INFO: Detected pattern $pattern_id (count: $count, confidence: $confidence)"

                # Remove processed signatures to avoid duplicates
                grep -v "^${sig_key}|" "$tmpfile" > "${tmpfile}.tmp" && mv "${tmpfile}.tmp" "$tmpfile"
            fi
        done < "$tmpfile"
    fi

    # Cleanup
    rm -f "$tmpfile" "${tmpfile}.tmp"

    printf '%s\n' "${patterns[@]}"
}

##############################################################################
# find_matching_pattern: Find existing pattern matching event
# Args: event_json
# Returns: pattern_id or empty
##############################################################################
find_matching_pattern() {
    local event_json="$1"

    local event_sig=$(extract_failure_signature "$event_json")
    local event_classification=$(classify_failure "$event_json")

    # Search pattern database
    if [ ! -f "$PATTERN_DB" ]; then
        return 0
    fi

    while IFS= read -r pattern_line; do
        if [ -z "$pattern_line" ]; then
            continue
        fi

        local pattern_category=$(echo "$pattern_line" | jq -r '.category')
        local pattern_type=$(echo "$pattern_line" | jq -r '.type')
        local pattern_sig=$(echo "$pattern_line" | jq -r '.signature')

        local pattern_classification="${pattern_category}:${pattern_type}"

        # Check if classifications match
        if [ "$event_classification" = "$pattern_classification" ]; then
            # Check signature similarity
            local similarity=$(calculate_signature_similarity "$event_sig" "$pattern_sig")

            if (( $(echo "$similarity >= $SIMILARITY_THRESHOLD" | bc -l) )); then
                echo "$pattern_line" | jq -r '.pattern_id'
                return 0
            fi
        fi
    done < "$PATTERN_DB"
}

##############################################################################
# update_pattern: Update existing pattern or create new one
# Args: pattern_json
##############################################################################
update_pattern() {
    local pattern_json="$1"

    local pattern_id=$(echo "$pattern_json" | jq -r '.pattern_id')

    # Check if pattern exists
    if [ -f "$PATTERN_DB" ] && grep -q "\"pattern_id\":\"$pattern_id\"" "$PATTERN_DB"; then
        # Update existing pattern
        local temp_file=$(mktemp)

        while IFS= read -r line; do
            if [ -z "$line" ]; then
                continue
            fi

            if echo "$line" | grep -q "\"pattern_id\":\"$pattern_id\""; then
                # Update this pattern
                local current_count=$(echo "$line" | jq -r '.frequency.total_occurrences')
                local new_count=$((current_count + 1))

                echo "$line" | jq -c \
                    --argjson new_count "$new_count" \
                    --arg updated_at "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                    '.frequency.total_occurrences = $new_count | .frequency.last_seen = $updated_at | .updated_at = $updated_at'
            else
                echo "$line"
            fi
        done < "$PATTERN_DB" > "$temp_file"

        mv "$temp_file" "$PATTERN_DB"
        log_pattern "INFO: Updated pattern $pattern_id"
    else
        # Add new pattern
        echo "$pattern_json" >> "$PATTERN_DB"
        log_pattern "INFO: Created new pattern $pattern_id"
    fi

    # Update index
    update_pattern_index
}

##############################################################################
# update_pattern_index: Rebuild pattern index
##############################################################################
update_pattern_index() {
    if [ ! -f "$PATTERN_DB" ]; then
        return 0
    fi

    local total_patterns=$(grep -c . "$PATTERN_DB" 2>/dev/null || echo "0")

    # Build index structure
    local index=$(jq -nc \
        --argjson total "$total_patterns" \
        --arg updated "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            patterns_by_category: {},
            patterns_by_worker_type: {},
            patterns_by_severity: {},
            total_patterns: $total,
            last_updated: $updated
        }')

    # TODO: Build detailed indices from pattern database
    # For now, just update basic metadata

    echo "$index" > "$PATTERN_INDEX"
}

##############################################################################
# emit_pattern_event: Emit observability event
# Args: event_type, pattern_id, additional_data
##############################################################################
emit_pattern_event() {
    local event_type="$1"
    local pattern_id="$2"
    local additional_data="${3:-{}}"

    local event_json=$(jq -nc \
        --arg event "$event_type" \
        --arg pattern "$pattern_id" \
        --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson data "$additional_data" \
        '{
            event_type: $event,
            pattern_id: $pattern,
            timestamp: $timestamp,
            data: $data
        }')

    # Write to events log
    local events_log="$COMMIT_RELAY_HOME/coordination/events/failure-pattern-events.jsonl"
    mkdir -p "$(dirname "$events_log")"
    echo "$event_json" >> "$events_log"
}

##############################################################################
# analyze_patterns: Main analysis function
# Returns: number of patterns detected
##############################################################################
analyze_patterns() {
    if [ "$ENABLED" != "true" ]; then
        log_pattern "INFO: Pattern detection disabled"
        return 0
    fi

    log_pattern "INFO: Starting pattern analysis (window: ${TIME_WINDOW_HOURS}h)"

    # Collect recent events
    local events=$(collect_recent_events "$TIME_WINDOW_HOURS")
    local event_count=$(echo "$events" | grep -c . || echo "0")

    log_pattern "INFO: Collected $event_count failure events"

    if [ "$event_count" -eq 0 ]; then
        log_pattern "INFO: No events to analyze"
        return 0
    fi

    # Run detection algorithms
    local patterns=$(detect_frequent_patterns "$events")
    local pattern_count=$(echo "$patterns" | grep -c . || echo "0")

    log_pattern "INFO: Detected $pattern_count patterns"

    # Update patterns
    while IFS= read -r pattern; do
        if [ -n "$pattern" ]; then
            update_pattern "$pattern"

            local pattern_id=$(echo "$pattern" | jq -r '.pattern_id')
            emit_pattern_event "pattern_detected" "$pattern_id" "{\"new\": true}"
        fi
    done <<< "$patterns"

    echo "$pattern_count"
}

# Export functions
export -f generate_pattern_id
export -f classify_failure
export -f extract_failure_signature
export -f calculate_signature_similarity
export -f collect_recent_events
export -f detect_frequent_patterns
export -f find_matching_pattern
export -f update_pattern
export -f update_pattern_index
export -f emit_pattern_event
export -f analyze_patterns

log_pattern "INFO: Failure pattern detection library loaded"
log_pattern "INFO: Detection enabled: $ENABLED"
log_pattern "INFO: Frequency threshold: $FREQUENCY_THRESHOLD occurrences in ${TIME_WINDOW_HOURS}h"
