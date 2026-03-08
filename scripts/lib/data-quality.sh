#!/usr/bin/env bash
#
# Data Quality Monitoring Library
# Part of Phase 3: Observability and Data Features
#
# Provides quality checks at data ingestion boundaries:
#   - JSON schema validation
#   - Required field checks
#   - Anomaly detection for values
#   - Quality scoring per data source
#   - Alerting on quality degradation
#
# Usage:
#   source scripts/lib/data-quality.sh
#
#   # Register a schema for validation
#   register_schema "task-queue" "$SCHEMA_JSON"
#
#   # Validate data
#   validate_data "task-queue" "$DATA_JSON"
#
#   # Get quality score
#   get_quality_score "task-queue"
#

set -euo pipefail

# Configuration
readonly DATA_QUALITY_DIR="${DATA_QUALITY_DIR:-coordination/observability/quality}"
readonly QUALITY_SCHEMAS_DIR="${DATA_QUALITY_DIR}/schemas"
readonly QUALITY_METRICS_FILE="${DATA_QUALITY_DIR}/quality-metrics.jsonl"
readonly QUALITY_ALERTS_FILE="${DATA_QUALITY_DIR}/quality-alerts.jsonl"
readonly QUALITY_SCORES_FILE="${DATA_QUALITY_DIR}/quality-scores.json"
ENABLE_QUALITY_MONITORING="${ENABLE_QUALITY_MONITORING:-true}"

# Quality thresholds
readonly QUALITY_ALERT_THRESHOLD="${QUALITY_ALERT_THRESHOLD:-0.8}"  # Alert below 80%
readonly QUALITY_CRITICAL_THRESHOLD="${QUALITY_CRITICAL_THRESHOLD:-0.6}"  # Critical below 60%
readonly ANOMALY_ZSCORE_THRESHOLD="${ANOMALY_ZSCORE_THRESHOLD:-3}"  # 3 standard deviations

# Initialize directories
mkdir -p "$DATA_QUALITY_DIR" "$QUALITY_SCHEMAS_DIR" 2>/dev/null || true

# Quality metrics tracking (file-based for portability)
QUALITY_COUNTERS_DIR="${DATA_QUALITY_DIR}/counters"
mkdir -p "$QUALITY_COUNTERS_DIR" 2>/dev/null || true

#
# Internal: Get counter value
#
_get_counter() {
    local counter_name="$1"
    local counter_file="$QUALITY_COUNTERS_DIR/${counter_name}"
    if [[ -f "$counter_file" ]]; then
        cat "$counter_file"
    else
        echo "0"
    fi
}

#
# Internal: Set counter value
#
_set_counter() {
    local counter_name="$1"
    local value="$2"
    echo "$value" > "$QUALITY_COUNTERS_DIR/${counter_name}"
}

#
# Get current timestamp in ISO format
#
_get_iso_timestamp() {
    date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"
}

#
# Register a JSON schema for validation
#
# Args:
#   $1 - source_id: Identifier for the data source
#   $2 - schema_json: JSON Schema for validation
#   $3 - description: Optional description
#
register_schema() {
    local source_id="$1"
    local schema_json="$2"
    local description="${3:-}"

    if [[ "$ENABLE_QUALITY_MONITORING" != "true" ]]; then
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)
    local schema_file="$QUALITY_SCHEMAS_DIR/${source_id}.schema.json"

    # Validate schema is valid JSON
    if ! echo "$schema_json" | jq empty 2>/dev/null; then
        echo "Error: Invalid JSON schema for source '$source_id'" >&2
        return 1
    fi

    # Wrap schema with metadata
    local schema_wrapper
    schema_wrapper=$(jq -n \
        --arg source_id "$source_id" \
        --arg description "$description" \
        --arg registered_at "$timestamp" \
        --argjson schema "$schema_json" \
        '{
            source_id: $source_id,
            description: $description,
            registered_at: $registered_at,
            schema: $schema
        }')

    echo "$schema_wrapper" > "$schema_file"

    # Initialize quality score for this source
    _update_quality_score "$source_id" 1.0
}

#
# Validate data against registered schema
#
# Args:
#   $1 - source_id: Data source identifier
#   $2 - data_json: JSON data to validate
#
# Returns:
#   0 if valid, 1 if invalid
#   Outputs validation result JSON
#
validate_data() {
    local source_id="$1"
    local data_json="$2"

    if [[ "$ENABLE_QUALITY_MONITORING" != "true" ]]; then
        echo '{"valid": true}'
        return 0
    fi

    local timestamp=$(_get_iso_timestamp)
    local schema_file="$QUALITY_SCHEMAS_DIR/${source_id}.schema.json"
    local validation_id="val-$(date +%s%N | cut -b1-13)-$(openssl rand -hex 3)"

    local errors=()
    local warnings=()
    local is_valid=true

    # Check if schema exists
    if [[ ! -f "$schema_file" ]]; then
        # No schema, only do basic validation
        if ! echo "$data_json" | jq empty 2>/dev/null; then
            errors+=("Invalid JSON structure")
            is_valid=false
        fi
    else
        # Get schema
        local schema
        schema=$(jq -r '.schema' "$schema_file")

        # Validate JSON structure
        if ! echo "$data_json" | jq empty 2>/dev/null; then
            errors+=("Invalid JSON structure")
            is_valid=false
        else
            # Perform schema validation checks
            local validation_errors
            validation_errors=$(_validate_against_schema "$data_json" "$schema")

            if [[ -n "$validation_errors" ]]; then
                while IFS= read -r error; do
                    errors+=("$error")
                done <<< "$validation_errors"
                is_valid=false
            fi
        fi
    fi

    # Record validation result
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]:-}" | jq -R . | jq -s .)

    local warnings_json
    warnings_json=$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s .)

    local result
    result=$(jq -n \
        --arg validation_id "$validation_id" \
        --arg source_id "$source_id" \
        --arg timestamp "$timestamp" \
        --argjson valid "$([[ "$is_valid" == "true" ]] && echo "true" || echo "false")" \
        --argjson errors "$errors_json" \
        --argjson warnings "$warnings_json" \
        '{
            validation_id: $validation_id,
            source_id: $source_id,
            timestamp: $timestamp,
            valid: $valid,
            errors: $errors,
            warnings: $warnings,
            error_count: ($errors | length),
            warning_count: ($warnings | length)
        }')

    # Log to metrics
    echo "$result" >> "$QUALITY_METRICS_FILE"

    # Update quality score
    _update_source_metrics "$source_id" "$is_valid"

    # Output result
    echo "$result"

    [[ "$is_valid" == "true" ]] && return 0 || return 1
}

#
# Internal: Validate data against JSON schema
#
_validate_against_schema() {
    local data="$1"
    local schema="$2"

    local errors=""

    # Check required fields
    local required_fields
    required_fields=$(echo "$schema" | jq -r '.required[]? // empty' 2>/dev/null)

    if [[ -n "$required_fields" ]]; then
        while IFS= read -r field; do
            if [[ -n "$field" ]]; then
                local has_field
                has_field=$(echo "$data" | jq "has(\"$field\")" 2>/dev/null || echo "false")
                if [[ "$has_field" != "true" ]]; then
                    errors+="Missing required field: $field"$'\n'
                fi
            fi
        done <<< "$required_fields"
    fi

    # Check field types
    local properties
    properties=$(echo "$schema" | jq -r '.properties // {} | keys[]' 2>/dev/null)

    if [[ -n "$properties" ]]; then
        while IFS= read -r prop; do
            if [[ -n "$prop" ]]; then
                local expected_type
                expected_type=$(echo "$schema" | jq -r ".properties.\"$prop\".type // empty" 2>/dev/null)

                if [[ -n "$expected_type" ]]; then
                    local actual_type
                    actual_type=$(echo "$data" | jq -r ".\"$prop\" | type" 2>/dev/null || echo "null")

                    if [[ "$actual_type" != "null" && "$actual_type" != "$expected_type" ]]; then
                        # Handle type coercion (number vs integer)
                        if [[ "$expected_type" == "integer" && "$actual_type" == "number" ]]; then
                            continue
                        fi
                        errors+="Field '$prop' expected type '$expected_type', got '$actual_type'"$'\n'
                    fi
                fi
            fi
        done <<< "$properties"
    fi

    # Check enum values
    if [[ -n "$properties" ]]; then
        while IFS= read -r prop; do
            if [[ -n "$prop" ]]; then
                local enum_values
                enum_values=$(echo "$schema" | jq -r ".properties.\"$prop\".enum // empty" 2>/dev/null)

                if [[ -n "$enum_values" && "$enum_values" != "null" ]]; then
                    local actual_value
                    actual_value=$(echo "$data" | jq -r ".\"$prop\" // null" 2>/dev/null)

                    if [[ "$actual_value" != "null" ]]; then
                        local is_valid_enum
                        is_valid_enum=$(echo "$schema" | jq \
                            --arg val "$actual_value" \
                            '.properties."'"$prop"'".enum | index($val) != null' 2>/dev/null || echo "false")

                        if [[ "$is_valid_enum" != "true" ]]; then
                            errors+="Field '$prop' value '$actual_value' not in allowed values"$'\n'
                        fi
                    fi
                fi
            fi
        done <<< "$properties"
    fi

    echo -n "$errors"
}

#
# Check for required fields in data
#
# Args:
#   $1 - data_json: JSON data to check
#   $2 - required_fields: Comma-separated list of required fields
#
# Returns:
#   JSON with missing fields
#
check_required_fields() {
    local data_json="$1"
    local required_fields="$2"

    local missing=()

    # Parse required fields
    IFS=',' read -ra fields <<< "$required_fields"

    for field in "${fields[@]}"; do
        field=$(echo "$field" | tr -d ' ')
        local has_field
        has_field=$(echo "$data_json" | jq "has(\"$field\")" 2>/dev/null || echo "false")

        if [[ "$has_field" != "true" ]]; then
            missing+=("$field")
        fi
    done

    # Return result
    local missing_json
    missing_json=$(printf '%s\n' "${missing[@]:-}" | jq -R . | jq -s .)

    jq -n \
        --argjson missing "$missing_json" \
        --argjson count "${#missing[@]}" \
        '{
            complete: ($count == 0),
            missing_fields: $missing,
            missing_count: $count
        }'
}

#
# Detect anomalous values in numeric data
#
# Args:
#   $1 - source_id: Data source identifier
#   $2 - field_name: Name of the numeric field
#   $3 - value: Current value to check
#
# Returns:
#   JSON with anomaly detection result
#
detect_anomaly() {
    local source_id="$1"
    local field_name="$2"
    local value="$3"

    local stats_file="${DATA_QUALITY_DIR}/stats/${source_id}-${field_name}.json"
    mkdir -p "$(dirname "$stats_file")"

    local is_anomaly="false"
    local zscore=0
    local reason=""

    # Initialize or load statistics
    if [[ -f "$stats_file" ]]; then
        local count mean variance
        count=$(jq -r '.count' "$stats_file")
        mean=$(jq -r '.mean' "$stats_file")
        variance=$(jq -r '.variance' "$stats_file")

        # Calculate z-score
        if [[ $count -ge 30 ]]; then
            local stddev
            stddev=$(echo "scale=6; sqrt($variance)" | bc)

            if [[ $(echo "$stddev > 0" | bc) -eq 1 ]]; then
                zscore=$(echo "scale=6; ($value - $mean) / $stddev" | bc)

                # Check if absolute z-score exceeds threshold
                local abs_zscore
                abs_zscore=$(echo "scale=6; if ($zscore < 0) -1 * $zscore else $zscore" | bc)

                if [[ $(echo "$abs_zscore > $ANOMALY_ZSCORE_THRESHOLD" | bc) -eq 1 ]]; then
                    is_anomaly="true"
                    reason="Value $value is ${abs_zscore} standard deviations from mean $mean"
                fi
            fi
        fi

        # Update running statistics (Welford's algorithm)
        local new_count=$((count + 1))
        local delta=$(echo "scale=6; $value - $mean" | bc)
        local new_mean=$(echo "scale=6; $mean + $delta / $new_count" | bc)
        local delta2=$(echo "scale=6; $value - $new_mean" | bc)
        local new_variance=$(echo "scale=6; (($count - 1) * $variance + $delta * $delta2) / $new_count" | bc)

        jq -n \
            --arg count "$new_count" \
            --arg mean "$new_mean" \
            --arg variance "$new_variance" \
            --arg min "$(jq --arg v "$value" -r '[.min, ($v | tonumber)] | min' "$stats_file")" \
            --arg max "$(jq --arg v "$value" -r '[.max, ($v | tonumber)] | max' "$stats_file")" \
            '{
                count: ($count | tonumber),
                mean: ($mean | tonumber),
                variance: ($variance | tonumber),
                min: ($min | tonumber),
                max: ($max | tonumber)
            }' > "$stats_file"
    else
        # Initialize statistics
        jq -n \
            --arg value "$value" \
            '{
                count: 1,
                mean: ($value | tonumber),
                variance: 0,
                min: ($value | tonumber),
                max: ($value | tonumber)
            }' > "$stats_file"
    fi

    # Return anomaly result
    jq -n \
        --arg source_id "$source_id" \
        --arg field_name "$field_name" \
        --arg value "$value" \
        --argjson is_anomaly "$is_anomaly" \
        --arg zscore "$zscore" \
        --arg reason "$reason" \
        '{
            source_id: $source_id,
            field_name: $field_name,
            value: ($value | tonumber),
            is_anomaly: $is_anomaly,
            zscore: ($zscore | tonumber),
            reason: $reason
        }'

    # Log anomaly if detected
    if [[ "$is_anomaly" == "true" ]]; then
        _create_quality_alert "$source_id" "anomaly" "$reason" "warning"
    fi
}

#
# Calculate quality score for a data source
#
# Args:
#   $1 - source_id: Data source identifier
#   $2 - window: Time window (1h, 24h, 7d)
#
# Returns:
#   Quality score between 0.0 and 1.0
#
get_quality_score() {
    local source_id="$1"
    local window="${2:-24h}"

    if [[ ! -f "$QUALITY_SCORES_FILE" ]]; then
        echo "1.0"
        return
    fi

    local score
    score=$(jq -r ".\"$source_id\".score // 1.0" "$QUALITY_SCORES_FILE")

    echo "$score"
}

#
# Get detailed quality report for a source
#
# Args:
#   $1 - source_id: Data source identifier
#
get_quality_report() {
    local source_id="$1"

    if [[ ! -f "$QUALITY_METRICS_FILE" ]]; then
        jq -n \
            --arg source_id "$source_id" \
            '{
                source_id: $source_id,
                total_validations: 0,
                successful: 0,
                failed: 0,
                quality_score: 1.0,
                common_errors: []
            }'
        return
    fi

    # Aggregate metrics for this source
    grep "\"source_id\":\"$source_id\"" "$QUALITY_METRICS_FILE" 2>/dev/null | jq -s '
        {
            source_id: "'"$source_id"'",
            total_validations: length,
            successful: [.[] | select(.valid == true)] | length,
            failed: [.[] | select(.valid == false)] | length,
            quality_score: (if length > 0 then ([.[] | select(.valid == true)] | length) / length else 1 end),
            common_errors: [.[] | .errors[]?] | group_by(.) | map({error: .[0], count: length}) | sort_by(-.count) | .[0:5],
            last_validation: (sort_by(.timestamp) | last | .timestamp)
        }
    '
}

#
# Get all quality scores
#
get_all_quality_scores() {
    if [[ ! -f "$QUALITY_SCORES_FILE" ]]; then
        echo '{}'
        return
    fi

    cat "$QUALITY_SCORES_FILE"
}

#
# Internal: Update quality score for a source
#
_update_quality_score() {
    local source_id="$1"
    local score="$2"

    # Initialize scores file if needed
    if [[ ! -f "$QUALITY_SCORES_FILE" ]]; then
        echo '{}' > "$QUALITY_SCORES_FILE"
    fi

    local timestamp=$(_get_iso_timestamp)
    local temp_file="${QUALITY_SCORES_FILE}.tmp"

    jq --arg id "$source_id" \
        --arg score "$score" \
        --arg timestamp "$timestamp" \
        '.[$id] = {
            score: ($score | tonumber),
            updated_at: $timestamp
        }' \
        "$QUALITY_SCORES_FILE" > "$temp_file" && mv "$temp_file" "$QUALITY_SCORES_FILE"
}

#
# Internal: Update source validation metrics
#
_update_source_metrics() {
    local source_id="$1"
    local is_valid="$2"

    # Increment counters using file-based storage
    local prev_validation_count
    prev_validation_count=$(_get_counter "validation-${source_id}")
    local validation_count=$((prev_validation_count + 1))
    _set_counter "validation-${source_id}" "$validation_count"

    if [[ "$is_valid" != "true" ]]; then
        local prev_error_count
        prev_error_count=$(_get_counter "error-${source_id}")
        local error_count=$((prev_error_count + 1))
        _set_counter "error-${source_id}" "$error_count"
    fi

    # Calculate score (exponential moving average)
    local errors
    errors=$(_get_counter "error-${source_id}")
    local total=$validation_count
    local score
    score=$(echo "scale=4; 1 - ($errors / $total)" | bc)

    # Update score
    _update_quality_score "$source_id" "$score"

    # Check for quality degradation
    if [[ $(echo "$score < $QUALITY_ALERT_THRESHOLD" | bc) -eq 1 ]]; then
        _create_quality_alert "$source_id" "quality_degradation" \
            "Quality score dropped to $score (threshold: $QUALITY_ALERT_THRESHOLD)" \
            "warning"
    fi

    if [[ $(echo "$score < $QUALITY_CRITICAL_THRESHOLD" | bc) -eq 1 ]]; then
        _create_quality_alert "$source_id" "critical_quality" \
            "Quality score critically low at $score (threshold: $QUALITY_CRITICAL_THRESHOLD)" \
            "critical"
    fi
}

#
# Internal: Create quality alert
#
_create_quality_alert() {
    local source_id="$1"
    local alert_type="$2"
    local message="$3"
    local severity="${4:-warning}"

    local timestamp=$(_get_iso_timestamp)
    local alert_id="alert-$(openssl rand -hex 6)"

    local alert
    alert=$(jq -nc \
        --arg alert_id "$alert_id" \
        --arg source_id "$source_id" \
        --arg alert_type "$alert_type" \
        --arg message "$message" \
        --arg severity "$severity" \
        --arg timestamp "$timestamp" \
        '{
            alert_id: $alert_id,
            source_id: $source_id,
            alert_type: $alert_type,
            message: $message,
            severity: $severity,
            timestamp: $timestamp,
            acknowledged: false
        }')

    echo "$alert" >> "$QUALITY_ALERTS_FILE"

    # Log to metrics directory for integration with alerting system
    local metrics_alert_file="coordination/metrics/quality-alerts.jsonl"
    mkdir -p "$(dirname "$metrics_alert_file")"
    echo "$alert" >> "$metrics_alert_file"
}

#
# Get recent quality alerts
#
# Args:
#   $1 - count: Number of alerts to return
#   $2 - severity: Optional severity filter
#
get_quality_alerts() {
    local count="${1:-10}"
    local severity="${2:-}"

    if [[ ! -f "$QUALITY_ALERTS_FILE" ]]; then
        echo '[]'
        return
    fi

    if [[ -n "$severity" ]]; then
        tail -n 100 "$QUALITY_ALERTS_FILE" | jq -s \
            --arg severity "$severity" \
            --arg count "$count" \
            'map(select(.severity == $severity)) | sort_by(.timestamp) | reverse | .[0:($count | tonumber)]'
    else
        tail -n 100 "$QUALITY_ALERTS_FILE" | jq -s \
            --arg count "$count" \
            'sort_by(.timestamp) | reverse | .[0:($count | tonumber)]'
    fi
}

#
# Acknowledge an alert
#
acknowledge_alert() {
    local alert_id="$1"

    if [[ ! -f "$QUALITY_ALERTS_FILE" ]]; then
        return 1
    fi

    local temp_file="${QUALITY_ALERTS_FILE}.tmp"

    # Update alert status
    while IFS= read -r line; do
        local current_id
        current_id=$(echo "$line" | jq -r '.alert_id')

        if [[ "$current_id" == "$alert_id" ]]; then
            echo "$line" | jq '.acknowledged = true | .acknowledged_at = now | todate'
        else
            echo "$line"
        fi
    done < "$QUALITY_ALERTS_FILE" > "$temp_file"

    mv "$temp_file" "$QUALITY_ALERTS_FILE"
}

#
# Validate multiple fields at once
#
# Args:
#   $1 - data_json: JSON data to validate
#   $2 - validations: JSON array of validation rules
#
# Example validations:
#   [
#     {"field": "status", "type": "enum", "values": ["pending", "active", "completed"]},
#     {"field": "priority", "type": "range", "min": 1, "max": 10},
#     {"field": "name", "type": "string", "min_length": 1, "max_length": 100}
#   ]
#
validate_fields() {
    local data_json="$1"
    local validations="$2"

    local errors=()

    # Parse validations
    local validation_count
    validation_count=$(echo "$validations" | jq 'length')

    for ((i=0; i<validation_count; i++)); do
        local validation
        validation=$(echo "$validations" | jq ".[$i]")

        local field
        field=$(echo "$validation" | jq -r '.field')

        local val_type
        val_type=$(echo "$validation" | jq -r '.type')

        local value
        value=$(echo "$data_json" | jq -r ".\"$field\" // null")

        case "$val_type" in
            "enum")
                local valid_values
                valid_values=$(echo "$validation" | jq -r '.values')
                local is_valid
                is_valid=$(echo "$validation" | jq --arg v "$value" '.values | index($v) != null')
                if [[ "$is_valid" != "true" ]]; then
                    errors+=("Field '$field': value '$value' not in allowed values")
                fi
                ;;
            "range")
                local min max
                min=$(echo "$validation" | jq -r '.min')
                max=$(echo "$validation" | jq -r '.max')
                if [[ $(echo "$value < $min || $value > $max" | bc) -eq 1 ]]; then
                    errors+=("Field '$field': value $value outside range [$min, $max]")
                fi
                ;;
            "string")
                local min_len max_len
                min_len=$(echo "$validation" | jq -r '.min_length // 0')
                max_len=$(echo "$validation" | jq -r '.max_length // 999999')
                local len=${#value}
                if [[ $len -lt $min_len || $len -gt $max_len ]]; then
                    errors+=("Field '$field': length $len outside range [$min_len, $max_len]")
                fi
                ;;
            "regex")
                local pattern
                pattern=$(echo "$validation" | jq -r '.pattern')
                if ! echo "$value" | grep -qE "$pattern"; then
                    errors+=("Field '$field': value does not match pattern")
                fi
                ;;
        esac
    done

    # Return result
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]:-}" | jq -R . | jq -s .)

    jq -n \
        --argjson valid "$([[ ${#errors[@]} -eq 0 ]] && echo "true" || echo "false")" \
        --argjson errors "$errors_json" \
        '{
            valid: $valid,
            errors: $errors,
            error_count: ($errors | length)
        }'
}

#
# Get quality summary across all sources
#
get_quality_summary() {
    if [[ ! -f "$QUALITY_SCORES_FILE" ]]; then
        jq -n '{
            total_sources: 0,
            average_score: 1.0,
            sources_below_threshold: 0,
            critical_sources: []
        }'
        return
    fi

    jq '
        to_entries |
        {
            total_sources: length,
            average_score: (if length > 0 then (map(.value.score) | add / length) else 1 end),
            sources_below_threshold: [.[] | select(.value.score < '"$QUALITY_ALERT_THRESHOLD"')] | length,
            critical_sources: [.[] | select(.value.score < '"$QUALITY_CRITICAL_THRESHOLD"') | .key]
        }
    ' "$QUALITY_SCORES_FILE"
}

#
# Cleanup old quality data
#
cleanup_quality_data() {
    local retention_days="${1:-30}"

    # Archive old metrics
    if [[ -f "$QUALITY_METRICS_FILE" ]]; then
        local archive_dir="${DATA_QUALITY_DIR}/archive"
        mkdir -p "$archive_dir"

        local archive_file="$archive_dir/quality-metrics-$(date +%Y-%m-%d).jsonl"
        mv "$QUALITY_METRICS_FILE" "$archive_file"
        touch "$QUALITY_METRICS_FILE"

        # Compress old archives
        find "$archive_dir" -name "*.jsonl" -mtime +7 -exec gzip {} \; 2>/dev/null || true
    fi

    # Cleanup old stats
    find "${DATA_QUALITY_DIR}/stats" -name "*.json" -mtime +$retention_days -delete 2>/dev/null || true
}

# Export functions
export -f register_schema
export -f validate_data
export -f check_required_fields
export -f detect_anomaly
export -f get_quality_score
export -f get_quality_report
export -f get_all_quality_scores
export -f get_quality_alerts
export -f acknowledge_alert
export -f validate_fields
export -f get_quality_summary
export -f cleanup_quality_data
