#!/usr/bin/env bash
#
# Alerting Library
# Part of Phase 2: Observability Enhancements
#
# Implements rule-based alerting on anomaly detection:
# - Rule matching against anomalies
# - Multi-channel alert emission
# - Cooldown and deduplication
# - Alert lifecycle management
#

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

readonly PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
readonly ALERT_RULES_FILE="${ALERT_RULES_FILE:-$PROJECT_ROOT/coordination/observability/alert-rules.json}"
readonly ALERTS_ACTIVE_DIR="${ALERTS_ACTIVE_DIR:-$PROJECT_ROOT/coordination/observability/alerts/active}"
readonly ALERTS_RESOLVED_DIR="${ALERTS_RESOLVED_DIR:-$PROJECT_ROOT/coordination/observability/alerts/resolved}"
readonly ALERTS_LOG_FILE="${ALERTS_LOG_FILE:-$PROJECT_ROOT/coordination/observability/alerts/alert.log}"
readonly ALERTS_HISTORY_FILE="${ALERTS_HISTORY_FILE:-$PROJECT_ROOT/coordination/observability/alerts/history.jsonl}"
readonly ALERTS_COOLDOWN_DIR="${ALERTS_COOLDOWN_DIR:-$PROJECT_ROOT/coordination/observability/alerts/.cooldowns}"
readonly DASHBOARD_EVENTS_FILE="${DASHBOARD_EVENTS_FILE:-$PROJECT_ROOT/coordination/dashboard-events.jsonl}"

readonly ENABLE_ALERTING="${ENABLE_ALERTING:-true}"

# Initialize directories
mkdir -p "$ALERTS_ACTIVE_DIR" "$ALERTS_RESOLVED_DIR" "$ALERTS_COOLDOWN_DIR" "$(dirname "$ALERTS_LOG_FILE")"

#
# Generate alert ID
#
generate_alert_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 4)
    echo "alert-${timestamp}-${random}"
}

#
# Get current timestamp in milliseconds
#
get_timestamp_ms() {
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

#
# Log alert message
#
log_alert() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$ALERTS_LOG_FILE"
}

#
# Load alert rules
#
load_alert_rules() {
    if [[ -f "$ALERT_RULES_FILE" ]]; then
        cat "$ALERT_RULES_FILE"
    else
        echo '{"rules": [], "channels": {}, "global_settings": {}}'
    fi
}

#
# Check if rule matches anomaly
#
rule_matches_anomaly() {
    local rule="$1"
    local anomaly="$2"

    local rule_anomaly_type=$(echo "$rule" | jq -r '.conditions.anomaly_type')
    local rule_severities=$(echo "$rule" | jq -r '.conditions.severity | @json')
    local rule_min_deviation=$(echo "$rule" | jq -r '.conditions.min_deviation // 0')

    local anomaly_type=$(echo "$anomaly" | jq -r '.type')
    local anomaly_severity=$(echo "$anomaly" | jq -r '.severity')
    local anomaly_deviation=$(echo "$anomaly" | jq -r '.deviation | if . < 0 then -. else . end')

    # Check anomaly type match
    if [[ "$rule_anomaly_type" != "$anomaly_type" ]]; then
        return 1
    fi

    # Check severity match
    local severity_match=$(echo "$rule_severities" | jq --arg sev "$anomaly_severity" 'contains([$sev])')
    if [[ "$severity_match" != "true" ]]; then
        return 1
    fi

    # Check minimum deviation
    if [[ $(echo "$anomaly_deviation < $rule_min_deviation" | bc -l 2>/dev/null) -eq 1 ]]; then
        return 1
    fi

    return 0
}

#
# Check if alert is in cooldown
#
is_in_cooldown() {
    local rule_id="$1"
    local anomaly_type="$2"
    local metric_name="$3"

    # Create cooldown key
    local cooldown_key=$(echo "${rule_id}_${anomaly_type}_${metric_name}" | md5sum | cut -d' ' -f1)
    local cooldown_file="$ALERTS_COOLDOWN_DIR/${cooldown_key}.cooldown"

    if [[ -f "$cooldown_file" ]]; then
        local cooldown_until=$(cat "$cooldown_file")
        local now=$(get_timestamp_ms)

        if [[ $now -lt $cooldown_until ]]; then
            return 0  # In cooldown
        else
            rm -f "$cooldown_file"
        fi
    fi

    return 1  # Not in cooldown
}

#
# Set cooldown for rule
#
set_cooldown() {
    local rule_id="$1"
    local anomaly_type="$2"
    local metric_name="$3"
    local cooldown_minutes="$4"

    local cooldown_key=$(echo "${rule_id}_${anomaly_type}_${metric_name}" | md5sum | cut -d' ' -f1)
    local cooldown_file="$ALERTS_COOLDOWN_DIR/${cooldown_key}.cooldown"

    local now=$(get_timestamp_ms)
    local cooldown_until=$((now + cooldown_minutes * 60 * 1000))

    echo "$cooldown_until" > "$cooldown_file"
}

#
# Emit alert to dashboard
#
emit_to_dashboard() {
    local alert="$1"

    local alert_id=$(echo "$alert" | jq -r '.alert_id')
    local rule_name=$(echo "$alert" | jq -r '.rule_name')
    local severity=$(echo "$alert" | jq -r '.severity')
    local metric_name=$(echo "$alert" | jq -r '.metric_name')
    local message=$(echo "$alert" | jq -r '.message')

    # Create dashboard event
    local event=$(jq -n \
        --arg id "alert-event-$(date +%s%N)" \
        --arg type "alert" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg alert_id "$alert_id" \
        --arg rule_name "$rule_name" \
        --arg severity "$severity" \
        --arg metric "$metric_name" \
        --arg message "$message" \
        '{
            id: $id,
            type: $type,
            timestamp: $timestamp,
            data: {
                alert_id: $alert_id,
                rule_name: $rule_name,
                severity: $severity,
                metric: $metric
            },
            message: $message
        }')

    echo "$event" >> "$DASHBOARD_EVENTS_FILE"
    log_alert "INFO" "Emitted alert to dashboard: $alert_id"
}

#
# Emit alert to log
#
emit_to_log() {
    local alert="$1"

    local alert_id=$(echo "$alert" | jq -r '.alert_id')
    local severity=$(echo "$alert" | jq -r '.severity')
    local message=$(echo "$alert" | jq -r '.message')
    local metric_name=$(echo "$alert" | jq -r '.metric_name')
    local rule_name=$(echo "$alert" | jq -r '.rule_name')

    local level="INFO"
    case "$severity" in
        critical) level="CRITICAL" ;;
        high) level="ERROR" ;;
        medium) level="WARN" ;;
        low) level="INFO" ;;
    esac

    log_alert "$level" "ALERT [$alert_id] [$rule_name] $message (metric: $metric_name)"
}

#
# Emit alert to webhook
#
emit_to_webhook() {
    local alert="$1"
    local channel_config="$2"

    local url=$(echo "$channel_config" | jq -r '.url')
    local method=$(echo "$channel_config" | jq -r '.method // "POST"')

    # Skip if URL is not configured
    if [[ "$url" == *'${'* || -z "$url" ]]; then
        log_alert "WARN" "Webhook URL not configured, skipping"
        return 0
    fi

    # Build headers
    local headers=""
    while IFS= read -r header; do
        local key=$(echo "$header" | jq -r '.key')
        local value=$(echo "$header" | jq -r '.value')
        headers="$headers -H \"$key: $value\""
    done < <(echo "$channel_config" | jq -c '.headers | to_entries[] | {key: .key, value: .value}')

    # Send webhook (async, don't block)
    (
        curl -s -X "$method" "$url" \
            -H "Content-Type: application/json" \
            -d "$alert" \
            --max-time 10 \
            >/dev/null 2>&1
    ) &

    log_alert "INFO" "Sent alert to webhook: $(echo "$alert" | jq -r '.alert_id')"
}

#
# Create and emit alert
#
create_alert() {
    local rule="$1"
    local anomaly="$2"

    if [[ "$ENABLE_ALERTING" != "true" ]]; then
        return 0
    fi

    local rule_id=$(echo "$rule" | jq -r '.rule_id')
    local rule_name=$(echo "$rule" | jq -r '.name')
    local channels=$(echo "$rule" | jq -r '.channels')
    local cooldown_minutes=$(echo "$rule" | jq -r '.cooldown_minutes // 30')
    local priority=$(echo "$rule" | jq -r '.metadata.priority // "P3"')

    local anomaly_id=$(echo "$anomaly" | jq -r '.anomaly_id')
    local anomaly_type=$(echo "$anomaly" | jq -r '.type')
    local severity=$(echo "$anomaly" | jq -r '.severity')
    local metric_name=$(echo "$anomaly" | jq -r '.metric_name')
    local description=$(echo "$anomaly" | jq -r '.description')
    local suggested_actions=$(echo "$anomaly" | jq '.suggested_actions')

    # Check cooldown
    if is_in_cooldown "$rule_id" "$anomaly_type" "$metric_name"; then
        log_alert "DEBUG" "Alert in cooldown for rule $rule_id, skipping"
        return 0
    fi

    # Generate alert
    local alert_id=$(generate_alert_id)
    local timestamp=$(get_timestamp_ms)
    local message="[$severity] $rule_name: $description"

    local alert=$(jq -n \
        --arg alert_id "$alert_id" \
        --arg rule_id "$rule_id" \
        --arg rule_name "$rule_name" \
        --arg anomaly_id "$anomaly_id" \
        --arg timestamp "$timestamp" \
        --arg severity "$severity" \
        --arg priority "$priority" \
        --arg metric_name "$metric_name" \
        --arg message "$message" \
        --arg description "$description" \
        --argjson suggested_actions "$suggested_actions" \
        --argjson channels "$channels" \
        '{
            alert_id: $alert_id,
            rule_id: $rule_id,
            rule_name: $rule_name,
            anomaly_id: $anomaly_id,
            created_at: ($timestamp | tonumber),
            severity: $severity,
            priority: $priority,
            metric_name: $metric_name,
            message: $message,
            description: $description,
            suggested_actions: $suggested_actions,
            channels: $channels,
            status: "active",
            acknowledged: false,
            acknowledged_by: null,
            resolved_at: null
        }')

    # Save alert
    local alert_file="$ALERTS_ACTIVE_DIR/${alert_id}.json"
    echo "$alert" > "$alert_file"

    # Record in history
    echo "$alert" >> "$ALERTS_HISTORY_FILE"

    # Emit to channels
    local rules_config=$(load_alert_rules)

    for channel in $(echo "$channels" | jq -r '.[]'); do
        case "$channel" in
            dashboard)
                emit_to_dashboard "$alert"
                ;;
            log)
                emit_to_log "$alert"
                ;;
            webhook)
                local webhook_config=$(echo "$rules_config" | jq '.channels.webhook')
                local webhook_enabled=$(echo "$webhook_config" | jq -r '.enabled')
                if [[ "$webhook_enabled" == "true" ]]; then
                    emit_to_webhook "$alert" "$webhook_config"
                fi
                ;;
        esac
    done

    # Set cooldown
    set_cooldown "$rule_id" "$anomaly_type" "$metric_name" "$cooldown_minutes"

    log_alert "INFO" "Created alert $alert_id for anomaly $anomaly_id"
    echo "$alert_id"
}

#
# Process anomaly against all rules
#
process_anomaly_for_alerts() {
    local anomaly="$1"

    if [[ "$ENABLE_ALERTING" != "true" ]]; then
        return 0
    fi

    local rules_config=$(load_alert_rules)
    local rules=$(echo "$rules_config" | jq -c '.rules[]')

    local alerts_created=0

    while IFS= read -r rule; do
        local enabled=$(echo "$rule" | jq -r '.enabled')

        if [[ "$enabled" == "true" ]]; then
            if rule_matches_anomaly "$rule" "$anomaly"; then
                local alert_id=$(create_alert "$rule" "$anomaly")
                if [[ -n "$alert_id" ]]; then
                    alerts_created=$((alerts_created + 1))
                fi
            fi
        fi
    done <<< "$rules"

    echo "$alerts_created"
}

#
# Acknowledge an alert
#
acknowledge_alert() {
    local alert_id="$1"
    local acknowledged_by="${2:-system}"
    local notes="${3:-}"

    local alert_file="$ALERTS_ACTIVE_DIR/${alert_id}.json"

    if [[ ! -f "$alert_file" ]]; then
        log_alert "ERROR" "Alert not found: $alert_id"
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    jq \
        --arg acknowledged_by "$acknowledged_by" \
        --arg acknowledged_at "$timestamp" \
        --arg notes "$notes" \
        '.acknowledged = true |
         .acknowledged_by = $acknowledged_by |
         .acknowledged_at = ($acknowledged_at | tonumber) |
         .notes = $notes' \
        "$alert_file" > "${alert_file}.tmp" && mv "${alert_file}.tmp" "$alert_file"

    log_alert "INFO" "Alert $alert_id acknowledged by $acknowledged_by"
}

#
# Resolve an alert
#
resolve_alert() {
    local alert_id="$1"
    local resolved_by="${2:-system}"
    local resolution_notes="${3:-Resolved}"

    local alert_file="$ALERTS_ACTIVE_DIR/${alert_id}.json"

    if [[ ! -f "$alert_file" ]]; then
        log_alert "ERROR" "Alert not found: $alert_id"
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    jq \
        --arg status "resolved" \
        --arg resolved_at "$timestamp" \
        --arg resolved_by "$resolved_by" \
        --arg resolution_notes "$resolution_notes" \
        '.status = $status |
         .resolved_at = ($resolved_at | tonumber) |
         .resolved_by = $resolved_by |
         .resolution_notes = $resolution_notes' \
        "$alert_file" > "${alert_file}.tmp" && mv "${alert_file}.tmp" "$alert_file"

    # Move to resolved
    mv "$alert_file" "$ALERTS_RESOLVED_DIR/"

    log_alert "INFO" "Alert $alert_id resolved by $resolved_by"
}

#
# Get alert statistics
#
get_alert_stats() {
    local timeframe="${1:-today}"

    local active_count=$(find "$ALERTS_ACTIVE_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local resolved_count=$(find "$ALERTS_RESOLVED_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    # Count by severity
    local critical=0
    local high=0
    local medium=0
    local low=0

    for alert_file in "$ALERTS_ACTIVE_DIR"/*.json; do
        if [[ -f "$alert_file" ]]; then
            local severity=$(jq -r '.severity' "$alert_file")
            case "$severity" in
                critical) critical=$((critical + 1)) ;;
                high) high=$((high + 1)) ;;
                medium) medium=$((medium + 1)) ;;
                low) low=$((low + 1)) ;;
            esac
        fi
    done

    # Count acknowledged
    local acknowledged=0
    for alert_file in "$ALERTS_ACTIVE_DIR"/*.json; do
        if [[ -f "$alert_file" ]]; then
            local ack=$(jq -r '.acknowledged' "$alert_file")
            if [[ "$ack" == "true" ]]; then
                acknowledged=$((acknowledged + 1))
            fi
        fi
    done

    jq -n \
        --arg active "$active_count" \
        --arg resolved "$resolved_count" \
        --arg critical "$critical" \
        --arg high "$high" \
        --arg medium "$medium" \
        --arg low "$low" \
        --arg acknowledged "$acknowledged" \
        '{
            active_alerts: ($active | tonumber),
            resolved_alerts: ($resolved | tonumber),
            by_severity: {
                critical: ($critical | tonumber),
                high: ($high | tonumber),
                medium: ($medium | tonumber),
                low: ($low | tonumber)
            },
            acknowledged: ($acknowledged | tonumber),
            unacknowledged: (($active | tonumber) - ($acknowledged | tonumber))
        }'
}

#
# List active alerts
#
list_active_alerts() {
    local severity_filter="${1:-all}"

    local alerts="[]"

    for alert_file in "$ALERTS_ACTIVE_DIR"/*.json; do
        if [[ -f "$alert_file" ]]; then
            local alert=$(cat "$alert_file")
            local alert_severity=$(echo "$alert" | jq -r '.severity')

            if [[ "$severity_filter" == "all" || "$severity_filter" == "$alert_severity" ]]; then
                alerts=$(echo "$alerts" | jq --argjson alert "$alert" '. += [$alert]')
            fi
        fi
    done

    # Sort by created_at descending
    echo "$alerts" | jq 'sort_by(.created_at) | reverse'
}

#
# Cleanup old resolved alerts
#
cleanup_old_alerts() {
    local retention_days="${1:-7}"

    find "$ALERTS_RESOLVED_DIR" -name "*.json" -mtime +$retention_days -delete
    find "$ALERTS_COOLDOWN_DIR" -name "*.cooldown" -mmin +60 -delete

    log_alert "INFO" "Cleaned up alerts older than $retention_days days"
}

# Export functions
export -f generate_alert_id
export -f load_alert_rules
export -f rule_matches_anomaly
export -f is_in_cooldown
export -f set_cooldown
export -f create_alert
export -f process_anomaly_for_alerts
export -f acknowledge_alert
export -f resolve_alert
export -f get_alert_stats
export -f list_active_alerts
export -f cleanup_old_alerts
