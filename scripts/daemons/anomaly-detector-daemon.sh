#!/usr/bin/env bash
#
# Anomaly Detector Daemon
# Part of Q2 Week 19: Anomaly Detection
#
# Continuously monitors metrics for anomalies using statistical methods
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source required libraries
source "$PROJECT_ROOT/scripts/lib/observability/anomaly-detector.sh"
source "$PROJECT_ROOT/scripts/lib/observability/metrics-collector.sh" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/observability/alerting.sh" 2>/dev/null || true

# Configuration
readonly DAEMON_NAME="anomaly-detector"
readonly PID_FILE="${PID_FILE:-/tmp/commit-relay-anomaly-detector.pid}"
readonly LOG_FILE="${LOG_FILE:-coordination/observability/anomalies/anomaly-detector.log}"
readonly CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # Check every 60 seconds
readonly BASELINE_UPDATE_INTERVAL="${BASELINE_UPDATE_INTERVAL:-3600}"  # Update baselines hourly

# Metrics to monitor
readonly MONITORED_METRICS=(
    "task_success_rate"
    "task_queue_depth"
    "worker_failure_rate"
    "token_usage_total"
    "routing_confidence_avg"
    "task_execution_time_p95"
    "worker_spawn_time_p95"
    "error_rate"
    "task_throughput"
    "worker_utilization"
)

# Behavioral monitoring configuration
readonly BEHAVIORAL_BASELINE_DIR="${BEHAVIORAL_BASELINE_DIR:-coordination/security/behavioral-baselines}"
readonly BEHAVIORAL_ALERTS_DIR="${BEHAVIORAL_ALERTS_DIR:-coordination/security/behavioral-alerts}"
readonly BEHAVIORAL_HISTORY_FILE="${BEHAVIORAL_HISTORY_FILE:-coordination/security/behavioral-history.jsonl}"

# Behavioral metrics to track
readonly BEHAVIORAL_METRICS=(
    "command_patterns"
    "file_access_patterns"
    "api_call_frequency"
    "resource_usage_patterns"
    "authentication_attempts"
    "data_transfer_volume"
)

#
# Log message
#
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

#
# Check if daemon is already running
#
check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    return 1
}

#
# Initialize daemon
#
initialize() {
    log "INFO" "Initializing anomaly detector daemon..."

    # Create log directory
    mkdir -p "$(dirname "$LOG_FILE")"

    # Create behavioral monitoring directories
    mkdir -p "$BEHAVIORAL_BASELINE_DIR" "$BEHAVIORAL_ALERTS_DIR"

    # Check if already running
    if check_running; then
        log "ERROR" "Daemon already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    # Write PID file
    echo $$ > "$PID_FILE"

    # Initialize baselines for all monitored metrics
    log "INFO" "Calculating initial baselines for ${#MONITORED_METRICS[@]} metrics..."
    for metric in "${MONITORED_METRICS[@]}"; do
        log "INFO" "  Calculating baseline for: $metric"
        calculate_baseline "$metric" 7 2>&1 | grep -v "^{" || true
    done

    # Initialize behavioral baselines
    log "INFO" "Initializing behavioral baselines..."
    initialize_behavioral_baselines

    log "INFO" "Initialization complete"
}

#
# Initialize behavioral baselines for threat detection
#
initialize_behavioral_baselines() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    for metric in "${BEHAVIORAL_METRICS[@]}"; do
        local baseline_file="$BEHAVIORAL_BASELINE_DIR/${metric}.json"

        if [[ ! -f "$baseline_file" ]]; then
            # Create initial baseline
            jq -n \
                --arg metric "$metric" \
                --arg timestamp "$timestamp" \
                '{
                    metric: $metric,
                    created_at: $timestamp,
                    updated_at: $timestamp,
                    sample_count: 0,
                    mean: 0,
                    stddev: 0,
                    min: 0,
                    max: 0,
                    p95: 0,
                    pattern_histogram: {},
                    time_series: []
                }' > "$baseline_file"

            log "INFO" "  Created behavioral baseline for: $metric"
        fi
    done
}

#
# Collect behavioral metrics from system activity
#
collect_behavioral_metrics() {
    local timestamp=$(date +%s)
    local timestamp_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Command patterns - analyze recent bash history from worker logs
    local cmd_count=0
    local unique_cmds=0
    if [[ -d "agents/logs" ]]; then
        cmd_count=$(find agents/logs -name "*.log" -mmin -5 -exec grep -h "Executing:" {} \; 2>/dev/null | wc -l | tr -d ' ')
        unique_cmds=$(find agents/logs -name "*.log" -mmin -5 -exec grep -h "Executing:" {} \; 2>/dev/null | sort -u | wc -l | tr -d ' ')
    fi

    # File access patterns - count recent file operations
    local file_reads=0
    local file_writes=0
    if [[ -d "coordination" ]]; then
        file_reads=$(find coordination -name "*.json" -mmin -5 2>/dev/null | wc -l | tr -d ' ')
        file_writes=$(find coordination -name "*.json" -mmin -1 2>/dev/null | wc -l | tr -d ' ')
    fi

    # API call frequency - estimate from event logs
    local api_calls=0
    if [[ -f "coordination/dashboard-events.jsonl" ]]; then
        api_calls=$(tail -100 coordination/dashboard-events.jsonl 2>/dev/null | wc -l | tr -d ' ')
    fi

    # Resource usage patterns
    local cpu_usage=0
    local mem_usage=0
    if command -v top >/dev/null 2>&1; then
        cpu_usage=$(ps -A -o %cpu | awk '{s+=$1} END {print s}' 2>/dev/null || echo "0")
        mem_usage=$(ps -A -o %mem | awk '{s+=$1} END {print s}' 2>/dev/null || echo "0")
    fi

    # Store metrics
    local metrics_json=$(jq -n \
        --arg ts "$timestamp_iso" \
        --arg cmd_count "$cmd_count" \
        --arg unique_cmds "$unique_cmds" \
        --arg file_reads "$file_reads" \
        --arg file_writes "$file_writes" \
        --arg api_calls "$api_calls" \
        --arg cpu_usage "$cpu_usage" \
        --arg mem_usage "$mem_usage" \
        '{
            timestamp: $ts,
            command_patterns: {
                total_commands: ($cmd_count | tonumber),
                unique_commands: ($unique_cmds | tonumber)
            },
            file_access_patterns: {
                reads: ($file_reads | tonumber),
                writes: ($file_writes | tonumber)
            },
            api_call_frequency: ($api_calls | tonumber),
            resource_usage_patterns: {
                cpu_percent: ($cpu_usage | tonumber),
                memory_percent: ($mem_usage | tonumber)
            }
        }')

    echo "$metrics_json" >> "$BEHAVIORAL_HISTORY_FILE"
    echo "$metrics_json"
}

#
# Update behavioral baselines with new data
#
update_behavioral_baselines() {
    log "INFO" "Updating behavioral baselines..."

    # Read recent history (last 24 hours)
    if [[ ! -f "$BEHAVIORAL_HISTORY_FILE" ]]; then
        return 0
    fi

    local history=$(tail -1440 "$BEHAVIORAL_HISTORY_FILE" 2>/dev/null)

    if [[ -z "$history" ]]; then
        return 0
    fi

    # Update command patterns baseline
    local cmd_stats=$(echo "$history" | jq -s '
        {
            sample_count: length,
            mean: (map(.command_patterns.total_commands) | add / length),
            stddev: (
                (map(.command_patterns.total_commands) | add / length) as $mean |
                map(.command_patterns.total_commands | . - $mean | . * .) | add / length | sqrt
            ),
            min: (map(.command_patterns.total_commands) | min),
            max: (map(.command_patterns.total_commands) | max),
            p95: (map(.command_patterns.total_commands) | sort | .[length * 95 / 100 | floor] // 0)
        }')

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local baseline_file="$BEHAVIORAL_BASELINE_DIR/command_patterns.json"

    if [[ -f "$baseline_file" ]]; then
        jq --argjson stats "$cmd_stats" \
           --arg updated "$timestamp" \
           '. + $stats + {updated_at: $updated}' \
           "$baseline_file" > "${baseline_file}.tmp" && \
        mv "${baseline_file}.tmp" "$baseline_file"
    fi

    log "INFO" "Behavioral baselines updated"
}

#
# Detect behavioral anomalies using statistical methods
#
detect_behavioral_anomalies() {
    local current_metrics="$1"
    local anomalies_detected=0

    # Check command patterns
    local cmd_count=$(echo "$current_metrics" | jq -r '.command_patterns.total_commands')
    local baseline_file="$BEHAVIORAL_BASELINE_DIR/command_patterns.json"

    if [[ -f "$baseline_file" ]]; then
        local mean=$(jq -r '.mean // 0' "$baseline_file")
        local stddev=$(jq -r '.stddev // 1' "$baseline_file")

        if [[ "$stddev" != "0" && -n "$stddev" ]]; then
            local deviation=$(echo "scale=4; ($cmd_count - $mean) / $stddev" | bc 2>/dev/null || echo "0")
            local abs_deviation=$(echo "$deviation" | tr -d '-')

            # Check for >3 sigma deviation
            if [[ $(echo "$abs_deviation > 3" | bc -l 2>/dev/null) -eq 1 ]]; then
                record_behavioral_anomaly "command_pattern_deviation" "$cmd_count" "$mean" "$deviation" "Command frequency deviated significantly from baseline"
                anomalies_detected=$((anomalies_detected + 1))
            fi
        fi
    fi

    # Check file access patterns
    local file_writes=$(echo "$current_metrics" | jq -r '.file_access_patterns.writes')
    local file_reads=$(echo "$current_metrics" | jq -r '.file_access_patterns.reads')

    # Detect unusual write-to-read ratio (potential data exfiltration indicator)
    if [[ "$file_reads" -gt 0 ]]; then
        local write_ratio=$(echo "scale=4; $file_writes / $file_reads" | bc 2>/dev/null || echo "0")

        # Alert if write ratio > 0.5 (unusual amount of writing)
        if [[ $(echo "$write_ratio > 0.5" | bc -l 2>/dev/null) -eq 1 ]]; then
            record_behavioral_anomaly "unusual_write_pattern" "$write_ratio" "0.1" "0" "Unusually high write-to-read ratio detected"
            anomalies_detected=$((anomalies_detected + 1))
        fi
    fi

    # Check resource usage patterns
    local cpu_usage=$(echo "$current_metrics" | jq -r '.resource_usage_patterns.cpu_percent')

    # Alert on high CPU usage (>90%)
    if [[ $(echo "$cpu_usage > 90" | bc -l 2>/dev/null) -eq 1 ]]; then
        record_behavioral_anomaly "high_cpu_usage" "$cpu_usage" "50" "0" "CPU usage exceeds 90%"
        anomalies_detected=$((anomalies_detected + 1))
    fi

    echo "$anomalies_detected"
}

#
# Record a behavioral anomaly
#
record_behavioral_anomaly() {
    local anomaly_type="$1"
    local current_value="$2"
    local baseline_value="$3"
    local deviation="$4"
    local description="$5"

    local anomaly_id="behavioral-$(date +%s%N | cut -b1-13)-$(openssl rand -hex 4)"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine severity based on deviation
    local severity="medium"
    local abs_dev=$(echo "$deviation" | tr -d '-')
    if [[ $(echo "$abs_dev > 5" | bc -l 2>/dev/null) -eq 1 ]]; then
        severity="critical"
    elif [[ $(echo "$abs_dev > 4" | bc -l 2>/dev/null) -eq 1 ]]; then
        severity="high"
    fi

    local alert_file="$BEHAVIORAL_ALERTS_DIR/${anomaly_id}.json"

    jq -n \
        --arg id "$anomaly_id" \
        --arg ts "$timestamp" \
        --arg type "$anomaly_type" \
        --arg severity "$severity" \
        --arg current "$current_value" \
        --arg baseline "$baseline_value" \
        --arg deviation "$deviation" \
        --arg desc "$description" \
        '{
            anomaly_id: $id,
            timestamp: $ts,
            type: "behavioral_anomaly",
            subtype: $type,
            severity: $severity,
            status: "active",
            current_value: ($current | tonumber),
            baseline_value: ($baseline | tonumber),
            deviation: ($deviation | tonumber),
            description: $desc,
            suggested_actions: [
                "Review recent worker activity logs",
                "Check for unauthorized access attempts",
                "Verify system resource allocation",
                "Investigate potential security incidents"
            ]
        }' > "$alert_file"

    log "WARN" "BEHAVIORAL ANOMALY: [$severity] $anomaly_type - $description"

    # Emit system event for high/critical severity
    if [[ "$severity" == "critical" || "$severity" == "high" ]]; then
        emit_system_event "behavioral_anomaly_detected" \
            "{\"anomaly_id\":\"$anomaly_id\",\"type\":\"$anomaly_type\",\"severity\":\"$severity\"}" \
            "error" 2>/dev/null || true
    fi
}

#
# Monitor behavioral patterns
#
monitor_behavioral_patterns() {
    # Collect current behavioral metrics
    local current_metrics=$(collect_behavioral_metrics)

    # Detect anomalies
    local anomalies=$(detect_behavioral_anomalies "$current_metrics")

    if [[ "$anomalies" -gt 0 ]]; then
        log "WARN" "Detected $anomalies behavioral anomalies"
    fi
}

#
# Update baselines
#
update_baselines() {
    log "INFO" "Updating baselines..."

    for metric in "${MONITORED_METRICS[@]}"; do
        calculate_baseline "$metric" 7 >/dev/null 2>&1 || true
    done

    # Also update behavioral baselines
    update_behavioral_baselines || true

    log "INFO" "Baselines updated"
}

#
# Monitor a single metric
#
monitor_metric() {
    local metric_name="$1"

    # Get current value (from most recent metric)
    local current_value=$(query_metrics_recent "$metric_name" 60 | jq -r '.[0].value // empty' 2>/dev/null)

    if [[ -z "$current_value" || "$current_value" == "null" ]]; then
        return 0
    fi

    # Check for anomaly
    local anomaly_id=$(check_metric_for_anomaly "$metric_name" "$current_value" "{}")

    if [[ -n "$anomaly_id" ]]; then
        local anomaly_file="$ANOMALIES_ACTIVE_DIR/${anomaly_id}.json"

        if [[ -f "$anomaly_file" ]]; then
            local anomaly_type=$(jq -r '.type' "$anomaly_file")
            local severity=$(jq -r '.severity' "$anomaly_file")
            local description=$(jq -r '.description' "$anomaly_file")

            log "WARN" "ANOMALY DETECTED: [$severity] $anomaly_type"
            log "WARN" "  Metric: $metric_name"
            log "WARN" "  Description: $description"
            log "WARN" "  Anomaly ID: $anomaly_id"

            # Emit event for critical/high severity anomalies
            if [[ "$severity" == "critical" || "$severity" == "high" ]]; then
                emit_system_event "anomaly_detected" \
                    "{\"anomaly_id\":\"$anomaly_id\",\"type\":\"$anomaly_type\",\"severity\":\"$severity\",\"metric\":\"$metric_name\"}" \
                    "error" 2>/dev/null || true
            fi

            # Process alerts based on anomaly
            if declare -f process_anomaly_for_alerts >/dev/null 2>&1; then
                local anomaly_data=$(cat "$anomaly_file")
                local alerts_created=$(process_anomaly_for_alerts "$anomaly_data" 2>/dev/null || echo "0")
                if [[ "$alerts_created" -gt 0 ]]; then
                    log "INFO" "Created $alerts_created alert(s) for anomaly $anomaly_id"
                fi
            fi
        fi
    fi
}

#
# Monitor all metrics
#
monitor_all_metrics() {
    for metric in "${MONITORED_METRICS[@]}"; do
        monitor_metric "$metric" || true
    done

    # Also monitor behavioral patterns
    monitor_behavioral_patterns || true
}

#
# Auto-resolve anomalies
#
auto_resolve_anomalies() {
    # Find active anomalies older than 1 hour with normal current values
    local one_hour_ago=$(($(date +%s) * 1000 - 3600000))

    for anomaly_file in "$ANOMALIES_ACTIVE_DIR"/*.json; do
        if [[ ! -f "$anomaly_file" ]]; then
            continue
        fi

        local anomaly_id=$(basename "$anomaly_file" .json)
        local timestamp=$(jq -r '.timestamp' "$anomaly_file")
        local metric_name=$(jq -r '.metric_name' "$anomaly_file")

        # Check if old enough
        if [[ $timestamp -lt $one_hour_ago ]]; then
            # Check if metric is back to normal
            local current_value=$(query_metrics_recent "$metric_name" 60 | jq -r '.[0].value // empty' 2>/dev/null)

            if [[ -n "$current_value" ]]; then
                # Quick check: is it within 2 sigma?
                local baseline=$(get_baseline "$metric_name" 2>/dev/null || echo "{}")

                if [[ "$baseline" != "{}" ]]; then
                    local mean=$(echo "$baseline" | jq -r '.mean')
                    local stddev=$(echo "$baseline" | jq -r '.stddev')

                    if [[ "$stddev" != "0" && -n "$stddev" ]]; then
                        local deviation=$(echo "scale=4; ($current_value - $mean) / $stddev" | bc 2>/dev/null || echo "0")
                        local abs_deviation=$(echo "$deviation" | tr -d '-')

                        # If within 2 sigma, auto-resolve
                        if [[ $(echo "$abs_deviation < 2" | bc -l 2>/dev/null) -eq 1 ]]; then
                            resolve_anomaly "$anomaly_id" "Auto-resolved: metric returned to normal range"
                            log "INFO" "Auto-resolved anomaly: $anomaly_id (metric: $metric_name)"
                        fi
                    fi
                fi
            fi
        fi
    done
}

#
# Print statistics
#
print_stats() {
    local stats=$(get_anomaly_stats "today")

    log "INFO" "=== Anomaly Detection Statistics ==="
    log "INFO" "Total Anomalies: $(echo "$stats" | jq -r '.total_anomalies')"
    log "INFO" "Active: $(echo "$stats" | jq -r '.active_anomalies')"
    log "INFO" "Resolved: $(echo "$stats" | jq -r '.resolved_anomalies')"
    log "INFO" "False Positives: $(echo "$stats" | jq -r '.false_positives')"
    log "INFO" "Detection Accuracy: $(echo "$stats" | jq -r '.detection_accuracy')%"
    log "INFO" "False Positive Rate: $(echo "$stats" | jq -r '.false_positive_rate')%"
    log "INFO" "==================================="
}

#
# Cleanup on exit
#
cleanup() {
    log "INFO" "Shutting down anomaly detector daemon..."
    rm -f "$PID_FILE"
    print_stats
    log "INFO" "Daemon stopped"
}

#
# Main daemon loop
#
main() {
    trap cleanup EXIT INT TERM

    initialize

    local last_baseline_update=$(date +%s)
    local check_count=0

    log "INFO" "Starting monitoring loop (interval: ${CHECK_INTERVAL}s)"

    while true; do
        check_count=$((check_count + 1))

        # Monitor all metrics
        monitor_all_metrics

        # Auto-resolve old anomalies
        if [[ $((check_count % 10)) -eq 0 ]]; then
            auto_resolve_anomalies
        fi

        # Update baselines hourly
        local now=$(date +%s)
        if [[ $((now - last_baseline_update)) -ge $BASELINE_UPDATE_INTERVAL ]]; then
            update_baselines
            last_baseline_update=$now
        fi

        # Print stats every 30 minutes
        if [[ $((check_count % 30)) -eq 0 ]]; then
            print_stats
        fi

        # Sleep until next check
        sleep "$CHECK_INTERVAL"
    done
}

#
# CLI commands
#
case "${1:-start}" in
    start)
        main
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            local pid=$(cat "$PID_FILE")
            log "INFO" "Stopping daemon (PID: $pid)"
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
        else
            log "INFO" "Daemon not running"
        fi
        ;;
    status)
        if check_running; then
            log "INFO" "Daemon is running (PID: $(cat "$PID_FILE"))"
            print_stats
        else
            log "INFO" "Daemon is not running"
        fi
        ;;
    stats)
        print_stats
        ;;
    baseline)
        metric_name="${2:-}"
        if [[ -z "$metric_name" ]]; then
            log "ERROR" "Usage: $0 baseline <metric_name>"
            exit 1
        fi
        calculate_baseline "$metric_name" 7
        ;;
    check)
        metric_name="${2:-}"
        value="${3:-}"
        if [[ -z "$metric_name" || -z "$value" ]]; then
            log "ERROR" "Usage: $0 check <metric_name> <value>"
            exit 1
        fi
        check_metric_for_anomaly "$metric_name" "$value" "{}"
        ;;
    resolve)
        anomaly_id="${2:-}"
        notes="${3:-Manually resolved}"
        if [[ -z "$anomaly_id" ]]; then
            log "ERROR" "Usage: $0 resolve <anomaly_id> [notes]"
            exit 1
        fi
        resolve_anomaly "$anomaly_id" "$notes"
        ;;
    false-positive)
        anomaly_id="${2:-}"
        notes="${3:-}"
        if [[ -z "$anomaly_id" ]]; then
            log "ERROR" "Usage: $0 false-positive <anomaly_id> [notes]"
            exit 1
        fi
        mark_false_positive "$anomaly_id" "$notes"
        ;;
    *)
        echo "Usage: $0 {start|stop|status|stats|baseline|check|resolve|false-positive}"
        echo ""
        echo "Commands:"
        echo "  start                          Start the daemon"
        echo "  stop                           Stop the daemon"
        echo "  status                         Check daemon status"
        echo "  stats                          Show statistics"
        echo "  baseline <metric>              Calculate baseline for metric"
        echo "  check <metric> <value>         Check value for anomalies"
        echo "  resolve <anomaly_id> [notes]   Resolve an anomaly"
        echo "  false-positive <id> [notes]    Mark as false positive"
        exit 1
        ;;
esac
