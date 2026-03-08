#!/usr/bin/env bash
#
# Anomaly Detector Library
# Part of Q2 Week 19: Anomaly Detection
#
# Implements statistical anomaly detection methods:
# - Three-sigma rule (standard deviation)
# - Moving averages (exponential)
# - Rate of change analysis
# - Pattern matching
#

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

readonly ANOMALIES_ACTIVE_DIR="${ANOMALIES_ACTIVE_DIR:-coordination/observability/anomalies/active}"
readonly ANOMALIES_RESOLVED_DIR="${ANOMALIES_RESOLVED_DIR:-coordination/observability/anomalies/resolved}"
readonly ANOMALIES_BASELINES_DIR="${ANOMALIES_BASELINES_DIR:-coordination/observability/anomalies/baselines}"
readonly ANOMALIES_INDEX_DIR="${ANOMALIES_INDEX_DIR:-coordination/observability/anomalies/indices}"
readonly ENABLE_ANOMALY_DETECTION="${ENABLE_ANOMALY_DETECTION:-true}"

# Default thresholds
readonly DEFAULT_SIGMA_THRESHOLD=3
readonly DEFAULT_RATE_OF_CHANGE_THRESHOLD=0.5  # 50% change
readonly DEFAULT_BASELINE_WINDOW_DAYS=7

# Initialize directories
mkdir -p "$ANOMALIES_ACTIVE_DIR" "$ANOMALIES_RESOLVED_DIR" "$ANOMALIES_BASELINES_DIR" "$ANOMALIES_INDEX_DIR"

# Source metrics collector for data access
if [[ -f "$SCRIPT_DIR/metrics-collector.sh" ]]; then
    source "$SCRIPT_DIR/metrics-collector.sh" 2>/dev/null || true
fi

#
# Generate anomaly ID
#
generate_anomaly_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 4)
    echo "anomaly-${timestamp}-${random}"
}

#
# Get current timestamp in milliseconds
#
get_timestamp_ms() {
    # Try GNU date first, fallback to seconds * 1000 for macOS
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        # macOS date doesn't support %N, use fallback
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

#
# Calculate baseline statistics for a metric
#
calculate_baseline() {
    local metric_name="$1"
    local window_days="${2:-$DEFAULT_BASELINE_WINDOW_DAYS}"

    if [[ "$ENABLE_ANOMALY_DETECTION" != "true" ]]; then
        return 0
    fi

    local window_start=$(($(date +%s) - (window_days * 86400)))
    local window_end=$(date +%s)

    # Query metrics for the window
    local metrics_data=$(query_metrics_timerange "$metric_name" "$window_start" "$window_end")

    if [[ -z "$metrics_data" || "$metrics_data" == "[]" ]]; then
        echo "{\"error\": \"No data available for baseline\"}" >&2
        return 1
    fi

    # Calculate statistics using jq
    local stats=$(echo "$metrics_data" | jq -s '
        {
            samples: .,
            sample_count: length,
            values: [.[].value]
        } |
        {
            sample_count: .sample_count,
            mean: ((.values | add) / .sample_count),
            min: (.values | min),
            max: (.values | max),
            p50: (.values | sort | .[length * 50 / 100 | floor]),
            p95: (.values | sort | .[length * 95 / 100 | floor]),
            p99: (.values | sort | .[length * 99 / 100 | floor])
        } |
        . + {
            variance: (
                .mean as $mean |
                [.values[] | (. - $mean) | . * .] |
                add / length
            )
        } |
        . + {
            stddev: (.variance | sqrt)
        }
    ' 2>/dev/null)

    if [[ $? -ne 0 || -z "$stats" ]]; then
        # Fallback to simpler calculation
        local values=$(echo "$metrics_data" | jq -r '.[].value')
        local count=$(echo "$values" | wc -l | tr -d ' ')

        if [[ $count -eq 0 ]]; then
            echo "{\"error\": \"No values for baseline\"}" >&2
            return 1
        fi

        local sum=$(echo "$values" | awk '{sum+=$1} END {print sum}')
        local mean=$(echo "scale=4; $sum / $count" | bc)

        # Calculate standard deviation
        local variance=$(echo "$values" | awk -v mean="$mean" '{sum+=($1-mean)^2} END {print sum/NR}')
        local stddev=$(echo "scale=4; sqrt($variance)" | bc)

        stats=$(jq -n \
            --arg count "$count" \
            --arg mean "$mean" \
            --arg stddev "$stddev" \
            '{
                sample_count: ($count | tonumber),
                mean: ($mean | tonumber),
                stddev: ($stddev | tonumber),
                min: 0,
                max: 0,
                p50: 0,
                p95: 0,
                p99: 0
            }')
    fi

    # Create baseline record
    local baseline_file="$ANOMALIES_BASELINES_DIR/${metric_name//\//_}.baseline"

    jq -n \
        --arg metric_name "$metric_name" \
        --arg window_start "$window_start" \
        --arg window_end "$window_end" \
        --argjson stats "$stats" \
        '{
            metric_name: $metric_name,
            window_start: ($window_start | tonumber * 1000),
            window_end: ($window_end | tonumber * 1000),
            updated_at: (now * 1000 | floor),
            sample_count: $stats.sample_count,
            mean: $stats.mean,
            stddev: $stats.stddev,
            min: $stats.min,
            max: $stats.max,
            p50: $stats.p50,
            p95: $stats.p95,
            p99: $stats.p99
        }' > "$baseline_file"

    echo "$baseline_file"
}

#
# Get baseline for a metric (calculate if not exists or stale)
#
get_baseline() {
    local metric_name="$1"
    local max_age_hours="${2:-24}"

    local baseline_file="$ANOMALIES_BASELINES_DIR/${metric_name//\//_}.baseline"

    # Check if baseline exists and is fresh
    if [[ -f "$baseline_file" ]]; then
        local updated_at=$(jq -r '.updated_at' "$baseline_file")
        local now_ms=$(get_timestamp_ms)
        local age_ms=$((now_ms - updated_at))
        local max_age_ms=$((max_age_hours * 3600 * 1000))

        if [[ $age_ms -lt $max_age_ms ]]; then
            cat "$baseline_file"
            return 0
        fi
    fi

    # Calculate new baseline
    calculate_baseline "$metric_name" >/dev/null 2>&1

    if [[ -f "$baseline_file" ]]; then
        cat "$baseline_file"
    else
        echo "{}"
        return 1
    fi
}

#
# Detect anomaly using three-sigma rule
#
detect_three_sigma() {
    local metric_name="$1"
    local current_value="$2"
    local sigma_threshold="${3:-$DEFAULT_SIGMA_THRESHOLD}"

    local baseline=$(get_baseline "$metric_name")

    if [[ "$baseline" == "{}" ]]; then
        return 1
    fi

    local mean=$(echo "$baseline" | jq -r '.mean')
    local stddev=$(echo "$baseline" | jq -r '.stddev')

    # Avoid division by zero
    if [[ $(echo "$stddev == 0" | bc -l) -eq 1 ]]; then
        return 1
    fi

    # Calculate deviation
    local deviation=$(echo "scale=4; ($current_value - $mean) / $stddev" | bc)
    local abs_deviation=$(echo "$deviation" | tr -d '-')

    # Check if exceeds threshold
    if [[ $(echo "$abs_deviation >= $sigma_threshold" | bc -l) -eq 1 ]]; then
        local deviation_pct=$(echo "scale=2; (($current_value - $mean) / $mean) * 100" | bc)

        echo "true"
        echo "$deviation"
        echo "$deviation_pct"
        return 0
    fi

    echo "false"
    return 1
}

#
# Detect anomaly using rate of change
#
detect_rate_of_change() {
    local metric_name="$1"
    local current_value="$2"
    local lookback_minutes="${3:-5}"
    local threshold="${4:-$DEFAULT_RATE_OF_CHANGE_THRESHOLD}"

    # Get previous value from lookback_minutes ago
    local lookback_seconds=$((lookback_minutes * 60))
    local previous_value=$(query_metrics_recent "$metric_name" "$lookback_seconds" | jq -r '.[0].value // 0')

    if [[ "$previous_value" == "0" || -z "$previous_value" ]]; then
        return 1
    fi

    # Calculate rate of change
    local change=$(echo "scale=4; $current_value - $previous_value" | bc)
    local rate_of_change=$(echo "scale=4; $change / $previous_value" | bc)
    local abs_rate=$(echo "$rate_of_change" | tr -d '-')

    # Check if exceeds threshold
    if [[ $(echo "$abs_rate >= $threshold" | bc -l) -eq 1 ]]; then
        local change_pct=$(echo "scale=2; $rate_of_change * 100" | bc)

        echo "true"
        echo "$rate_of_change"
        echo "$change_pct"
        return 0
    fi

    echo "false"
    return 1
}

#
# Detect anomaly using exponential moving average
#
detect_ema_deviation() {
    local metric_name="$1"
    local current_value="$2"
    local alpha="${3:-0.3}"  # Smoothing factor
    local threshold="${4:-0.5}"

    # Get recent values (last 10)
    local recent_values=$(query_metrics_recent "$metric_name" 600 | jq -r '.[].value')

    if [[ -z "$recent_values" ]]; then
        return 1
    fi

    # Calculate EMA
    local ema=$(echo "$recent_values" | awk -v alpha="$alpha" '
        BEGIN { ema = 0; first = 1 }
        {
            if (first) {
                ema = $1
                first = 0
            } else {
                ema = alpha * $1 + (1 - alpha) * ema
            }
        }
        END { print ema }
    ')

    # Calculate deviation from EMA
    local deviation=$(echo "scale=4; ($current_value - $ema) / $ema" | bc)
    local abs_deviation=$(echo "$deviation" | tr -d '-')

    # Check if exceeds threshold
    if [[ $(echo "$abs_deviation >= $threshold" | bc -l) -eq 1 ]]; then
        local deviation_pct=$(echo "scale=2; $deviation * 100" | bc)

        echo "true"
        echo "$deviation"
        echo "$deviation_pct"
        return 0
    fi

    echo "false"
    return 1
}

#
# Classify anomaly type based on metric name and deviation
#
classify_anomaly_type() {
    local metric_name="$1"
    local deviation="$2"

    case "$metric_name" in
        *success_rate*|*success_ratio*)
            if [[ $(echo "$deviation < 0" | bc -l) -eq 1 ]]; then
                echo "success_rate_drop"
            else
                echo "success_rate_spike"
            fi
            ;;
        *token*|*usage*)
            if [[ $(echo "$deviation > 0" | bc -l) -eq 1 ]]; then
                echo "token_usage_spike"
            else
                echo "token_usage_drop"
            fi
            ;;
        *queue*|*depth*)
            if [[ $(echo "$deviation > 0" | bc -l) -eq 1 ]]; then
                echo "queue_depth_explosion"
            else
                echo "queue_depth_collapse"
            fi
            ;;
        *confidence*)
            if [[ $(echo "$deviation < 0" | bc -l) -eq 1 ]]; then
                echo "routing_confidence_degradation"
            else
                echo "routing_confidence_improvement"
            fi
            ;;
        *failure*|*error*)
            if [[ $(echo "$deviation > 0" | bc -l) -eq 1 ]]; then
                echo "worker_failure_clustering"
            else
                echo "error_rate_drop"
            fi
            ;;
        *execution_time*|*latency*|*duration*)
            if [[ $(echo "$deviation > 0" | bc -l) -eq 1 ]]; then
                echo "latency_spike"
            else
                echo "latency_improvement"
            fi
            ;;
        *throughput*)
            if [[ $(echo "$deviation < 0" | bc -l) -eq 1 ]]; then
                echo "throughput_degradation"
            else
                echo "throughput_improvement"
            fi
            ;;
        *)
            echo "unknown_anomaly"
            ;;
    esac
}

#
# Calculate severity based on deviation magnitude
#
calculate_severity() {
    local deviation="$1"
    local abs_deviation=$(echo "$deviation" | tr -d '-')

    # Critical: >5 sigma or >100% change
    if [[ $(echo "$abs_deviation >= 5" | bc -l) -eq 1 ]]; then
        echo "critical"
    # High: 4-5 sigma or 75-100% change
    elif [[ $(echo "$abs_deviation >= 4" | bc -l) -eq 1 ]]; then
        echo "high"
    # Medium: 3-4 sigma or 50-75% change
    elif [[ $(echo "$abs_deviation >= 3" | bc -l) -eq 1 ]]; then
        echo "medium"
    # Low: <3 sigma or <50% change
    else
        echo "low"
    fi
}

#
# Generate suggested actions based on anomaly type
#
generate_suggested_actions() {
    local anomaly_type="$1"

    case "$anomaly_type" in
        success_rate_drop)
            echo '["Check recent task failures", "Review error logs", "Inspect worker health", "Verify routing decisions"]'
            ;;
        token_usage_spike)
            echo '["Review recent tasks for complexity", "Check for token leaks", "Analyze prompt patterns", "Scale down non-critical tasks"]'
            ;;
        queue_depth_explosion)
            echo '["Scale up workers", "Check worker availability", "Review task prioritization", "Investigate task routing"]'
            ;;
        routing_confidence_degradation)
            echo '["Review MoE routing patterns", "Check master performance", "Analyze recent task assignments", "Retrain routing model"]'
            ;;
        worker_failure_clustering)
            echo '["Investigate worker logs", "Check system resources", "Review recent deployments", "Analyze failure patterns"]'
            ;;
        latency_spike)
            echo '["Check system resources", "Review recent code changes", "Analyze slow traces", "Scale infrastructure"]'
            ;;
        throughput_degradation)
            echo '["Scale workers", "Optimize task routing", "Check for bottlenecks", "Review resource allocation"]'
            ;;
        *)
            echo '["Investigate metric history", "Check related metrics", "Review recent changes"]'
            ;;
    esac
}

#
# Record an anomaly
#
record_anomaly() {
    local metric_name="$1"
    local current_value="$2"
    local baseline_value="$3"
    local baseline_stddev="$4"
    local deviation="$5"
    local deviation_pct="$6"
    local detection_method="$7"
    local context="${8:-{}}"

    if [[ "$ENABLE_ANOMALY_DETECTION" != "true" ]]; then
        return 0
    fi

    local anomaly_id=$(generate_anomaly_id)
    local timestamp=$(get_timestamp_ms)

    # Classify anomaly
    local anomaly_type=$(classify_anomaly_type "$metric_name" "$deviation")
    local severity=$(calculate_severity "$deviation")

    # Determine category
    local category="performance"
    case "$anomaly_type" in
        *failure*|*error*|*success_rate*)
            category="reliability"
            ;;
        *token*|*queue*|*resource*)
            category="resource"
            ;;
        *confidence*|*quality*)
            category="quality"
            ;;
    esac

    # Generate description
    local description="Detected $anomaly_type: $metric_name deviated by ${deviation_pct}% from baseline (${baseline_value} → ${current_value})"

    # Get suggested actions  - returns JSON array string
    local suggested_actions_json=$(generate_suggested_actions "$anomaly_type")

    # Create anomaly record using printf to build JSON safely
    local anomaly_file="$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json"

    # Escape description for JSON
    local desc_escaped=$(echo "$description" | sed 's/"/\\"/g')

    # Build JSON manually to avoid jq --argjson issues
    printf '{
  "anomaly_id": "%s",
  "timestamp": %s,
  "detection_time": %s,
  "type": "%s",
  "category": "%s",
  "severity": "%s",
  "metric_name": "%s",
  "baseline_value": %s,
  "baseline_stddev": %s,
  "current_value": %s,
  "deviation": %s,
  "deviation_percentage": %s,
  "detection_method": "%s",
  "status": "active",
  "description": "%s",
  "context": %s,
  "suggested_actions": %s,
  "related_events": [],
  "related_anomalies": []
}\n' \
        "$anomaly_id" \
        "$timestamp" \
        "$timestamp" \
        "$anomaly_type" \
        "$category" \
        "$severity" \
        "$metric_name" \
        "$baseline_value" \
        "$baseline_stddev" \
        "$current_value" \
        "$deviation" \
        "$deviation_pct" \
        "$detection_method" \
        "$desc_escaped" \
        "$context" \
        "$suggested_actions_json" > "$anomaly_file"

    # Index by type and severity
    echo "$timestamp:$anomaly_id" >> "$ANOMALIES_INDEX_DIR/by-type-${anomaly_type}.index"
    echo "$timestamp:$anomaly_id" >> "$ANOMALIES_INDEX_DIR/by-severity-${severity}.index"

    # Index by day
    local day=$(date +%Y-%m-%d)
    echo "$anomaly_id" >> "$ANOMALIES_INDEX_DIR/by-day-${day}.index"

    echo "$anomaly_id"
}

#
# Check metric for anomalies
#
check_metric_for_anomaly() {
    local metric_name="$1"
    local current_value="$2"
    local context="${3:-{}}"

    if [[ "$ENABLE_ANOMALY_DETECTION" != "true" ]]; then
        return 0
    fi

    # Try three-sigma detection
    local result=$(detect_three_sigma "$metric_name" "$current_value")
    local is_anomaly=$(echo "$result" | head -1)

    if [[ "$is_anomaly" == "true" ]]; then
        local deviation=$(echo "$result" | sed -n '2p')
        local deviation_pct=$(echo "$result" | sed -n '3p')

        local baseline=$(get_baseline "$metric_name")
        local baseline_value=$(echo "$baseline" | jq -r '.mean')
        local baseline_stddev=$(echo "$baseline" | jq -r '.stddev')

        record_anomaly "$metric_name" "$current_value" "$baseline_value" "$baseline_stddev" \
            "$deviation" "$deviation_pct" "three_sigma" "$context"
        return 0
    fi

    # Try rate of change detection
    result=$(detect_rate_of_change "$metric_name" "$current_value")
    is_anomaly=$(echo "$result" | head -1)

    if [[ "$is_anomaly" == "true" ]]; then
        local rate=$(echo "$result" | sed -n '2p')
        local change_pct=$(echo "$result" | sed -n '3p')

        record_anomaly "$metric_name" "$current_value" "0" "0" \
            "$rate" "$change_pct" "rate_of_change" "$context"
        return 0
    fi

    return 1
}

#
# Resolve an anomaly
#
resolve_anomaly() {
    local anomaly_id="$1"
    local resolution_notes="${2:-Resolved}"

    local anomaly_file="$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json"

    if [[ ! -f "$anomaly_file" ]]; then
        echo "Error: Anomaly $anomaly_id not found" >&2
        return 1
    fi

    local resolution_time=$(get_timestamp_ms)

    # Update status
    jq \
        --arg status "resolved" \
        --arg resolution_time "$resolution_time" \
        --arg resolution_notes "$resolution_notes" \
        '.status = $status |
         .resolution_time = ($resolution_time | tonumber) |
         .resolution_notes = $resolution_notes' \
        "$anomaly_file" > "${anomaly_file}.tmp" && mv "${anomaly_file}.tmp" "$anomaly_file"

    # Move to resolved
    mv "$anomaly_file" "$ANOMALIES_RESOLVED_DIR/"

    echo "Resolved anomaly $anomaly_id"
}

#
# Mark anomaly as false positive
#
mark_false_positive() {
    local anomaly_id="$1"
    local notes="${2:-False positive}"

    resolve_anomaly "$anomaly_id" "False positive: $notes"
}

#
# Get anomaly statistics
#
get_anomaly_stats() {
    local timeframe="${1:-today}"

    local day=""
    case "$timeframe" in
        today)
            day=$(date +%Y-%m-%d)
            ;;
        yesterday)
            day=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
            ;;
        *)
            day="$timeframe"
            ;;
    esac

    local index_file="$ANOMALIES_INDEX_DIR/by-day-${day}.index"

    if [[ ! -f "$index_file" ]]; then
        jq -n '{total_anomalies: 0, active: 0, resolved: 0, false_positives: 0}'
        return 0
    fi

    local total=0
    local active=0
    local resolved=0
    local false_positives=0
    local critical=0
    local high=0
    local medium=0
    local low=0

    while read -r anomaly_id; do
        total=$((total + 1))

        # Check active first
        if [[ -f "$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json" ]]; then
            active=$((active + 1))
            local severity=$(jq -r '.severity' "$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json")
        elif [[ -f "$ANOMALIES_RESOLVED_DIR/${anomaly_id}.json" ]]; then
            local status=$(jq -r '.status' "$ANOMALIES_RESOLVED_DIR/${anomaly_id}.json")
            if [[ "$status" == "false_positive" ]]; then
                false_positives=$((false_positives + 1))
            else
                resolved=$((resolved + 1))
            fi
            local severity=$(jq -r '.severity' "$ANOMALIES_RESOLVED_DIR/${anomaly_id}.json")
        fi

        case "$severity" in
            critical) critical=$((critical + 1)) ;;
            high) high=$((high + 1)) ;;
            medium) medium=$((medium + 1)) ;;
            low) low=$((low + 1)) ;;
        esac
    done < "$index_file"

    local accuracy=0
    if [[ $total -gt 0 ]]; then
        accuracy=$(echo "scale=4; (($total - $false_positives) / $total) * 100" | bc)
    fi

    local fp_rate=0
    if [[ $total -gt 0 ]]; then
        fp_rate=$(echo "scale=4; ($false_positives / $total) * 100" | bc)
    fi

    jq -n \
        --arg day "$day" \
        --arg total "$total" \
        --arg active "$active" \
        --arg resolved "$resolved" \
        --arg false_positives "$false_positives" \
        --arg critical "$critical" \
        --arg high "$high" \
        --arg medium "$medium" \
        --arg low "$low" \
        --arg accuracy "$accuracy" \
        --arg fp_rate "$fp_rate" \
        '{
            day: $day,
            total_anomalies: ($total | tonumber),
            active_anomalies: ($active | tonumber),
            resolved_anomalies: ($resolved | tonumber),
            false_positives: ($false_positives | tonumber),
            by_severity: {
                critical: ($critical | tonumber),
                high: ($high | tonumber),
                medium: ($medium | tonumber),
                low: ($low | tonumber)
            },
            detection_accuracy: ($accuracy | tonumber),
            false_positive_rate: ($fp_rate | tonumber)
        }'
}

# Helper function stubs (to be implemented or sourced from metrics-collector)
query_metrics_timerange() {
    local metric_name="$1"
    local start="$2"
    local end="$3"
    # Placeholder - would query actual metrics
    echo "[]"
}

query_metrics_recent() {
    local metric_name="$1"
    local seconds_ago="$2"
    # Placeholder - would query recent metrics
    echo "[]"
}

# Export functions
export -f calculate_baseline
export -f get_baseline
export -f detect_three_sigma
export -f detect_rate_of_change
export -f detect_ema_deviation
export -f classify_anomaly_type
export -f calculate_severity
export -f record_anomaly
export -f check_metric_for_anomaly
export -f resolve_anomaly
export -f mark_false_positive
export -f get_anomaly_stats
