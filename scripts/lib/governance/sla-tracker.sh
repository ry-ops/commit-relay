#!/usr/bin/env bash
#
# SLA Tracker
# Part of Phase 2 Security Enhancements
#
# Tracks vulnerability SLAs:
# - Discovery time
# - Severity (CVSS)
# - SLA deadline
# - Closure time
#
# SLA by severity:
# - Critical (CVSS >= 9.0): 24 hours
# - High (CVSS 7.0-8.9): 72 hours
# - Medium (CVSS 4.0-6.9): 7 days
# - Low (CVSS < 4.0): 30 days
#
# Usage:
#   source scripts/lib/governance/sla-tracker.sh
#   track_vulnerability "$cve_id" "$cvss_score" "$severity"
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Configuration
readonly SLA_DATA_FILE="${SLA_DATA_FILE:-coordination/security/vulnerability-slas.jsonl}"
readonly SLA_ALERTS_FILE="${SLA_ALERTS_FILE:-coordination/security/sla-alerts.jsonl}"
readonly SLA_METRICS_FILE="${SLA_METRICS_FILE:-coordination/security/sla-metrics.json}"

# SLA definitions (in hours)
readonly SLA_CRITICAL_HOURS=24
readonly SLA_HIGH_HOURS=72
readonly SLA_MEDIUM_HOURS=168    # 7 days
readonly SLA_LOW_HOURS=720       # 30 days

# Alert thresholds (percentage of SLA remaining)
readonly ALERT_WARNING_THRESHOLD=50    # Alert when 50% of SLA remaining
readonly ALERT_CRITICAL_THRESHOLD=25   # Critical alert when 25% remaining

#
# Initialize SLA tracking
#
initialize_sla_tracking() {
    mkdir -p "$(dirname "$SLA_DATA_FILE")"

    if [[ ! -f "$SLA_METRICS_FILE" ]]; then
        jq -n '{
            total_tracked: 0,
            open_vulnerabilities: 0,
            closed_within_sla: 0,
            breached_sla: 0,
            by_severity: {
                critical: {open: 0, closed: 0, breached: 0},
                high: {open: 0, closed: 0, breached: 0},
                medium: {open: 0, closed: 0, breached: 0},
                low: {open: 0, closed: 0, breached: 0}
            },
            avg_remediation_time_hours: 0,
            sla_compliance_rate: 100
        }' > "$SLA_METRICS_FILE"
    fi
}

#
# Get SLA hours for severity
#
get_sla_hours() {
    local severity="$1"

    case "$severity" in
        critical) echo $SLA_CRITICAL_HOURS ;;
        high) echo $SLA_HIGH_HOURS ;;
        medium) echo $SLA_MEDIUM_HOURS ;;
        low) echo $SLA_LOW_HOURS ;;
        *) echo $SLA_MEDIUM_HOURS ;;
    esac
}

#
# Calculate SLA deadline
#
calculate_sla_deadline() {
    local discovery_time="$1"
    local severity="$2"

    local sla_hours=$(get_sla_hours "$severity")

    # Convert discovery time to epoch and add SLA hours
    local discovery_epoch
    if [[ "$OSTYPE" == "darwin"* ]]; then
        discovery_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$discovery_time" "+%s" 2>/dev/null || date +%s)
    else
        discovery_epoch=$(date -d "$discovery_time" +%s 2>/dev/null || date +%s)
    fi

    local deadline_epoch=$((discovery_epoch + (sla_hours * 3600)))

    # Format as ISO 8601
    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -r "$deadline_epoch" -u +%Y-%m-%dT%H:%M:%SZ
    else
        date -d "@$deadline_epoch" -u +%Y-%m-%dT%H:%M:%SZ
    fi
}

#
# Calculate time remaining in SLA
#
calculate_time_remaining() {
    local deadline="$1"

    local now_epoch=$(date +%s)
    local deadline_epoch

    if [[ "$OSTYPE" == "darwin"* ]]; then
        deadline_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$deadline" "+%s" 2>/dev/null || date +%s)
    else
        deadline_epoch=$(date -d "$deadline" +%s 2>/dev/null || date +%s)
    fi

    local remaining=$((deadline_epoch - now_epoch))
    echo "$remaining"
}

#
# Track a new vulnerability
#
track_vulnerability() {
    local vuln_id="$1"
    local cvss_score="$2"
    local severity="$3"
    local description="${4:-}"
    local source="${5:-manual}"

    initialize_sla_tracking

    local discovery_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local sla_deadline=$(calculate_sla_deadline "$discovery_time" "$severity")
    local sla_hours=$(get_sla_hours "$severity")

    local tracking_id="SLA-$(date +%s%N | cut -b1-13)-$(openssl rand -hex 4)"

    local entry=$(jq -n \
        --arg id "$tracking_id" \
        --arg vuln_id "$vuln_id" \
        --arg cvss "$cvss_score" \
        --arg severity "$severity" \
        --arg desc "$description" \
        --arg source "$source" \
        --arg discovery "$discovery_time" \
        --arg deadline "$sla_deadline" \
        --arg sla_hours "$sla_hours" \
        '{
            tracking_id: $id,
            vulnerability_id: $vuln_id,
            cvss_score: ($cvss | tonumber),
            severity: $severity,
            description: $desc,
            source: $source,
            discovery_time: $discovery,
            sla_deadline: $deadline,
            sla_hours: ($sla_hours | tonumber),
            status: "open",
            closure_time: null,
            resolution_notes: null,
            breached: false,
            time_to_resolution_hours: null
        }')

    echo "$entry" >> "$SLA_DATA_FILE"

    # Update metrics
    update_metrics

    echo "$tracking_id"
}

#
# Close a vulnerability
#
close_vulnerability() {
    local tracking_id="$1"
    local resolution_notes="${2:-Remediated}"

    local closure_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Find and update the entry
    if ! grep -q "\"tracking_id\": \"$tracking_id\"" "$SLA_DATA_FILE" 2>/dev/null; then
        echo "Error: Tracking ID not found: $tracking_id" >&2
        return 1
    fi

    # Calculate time to resolution
    local entry=$(grep "\"tracking_id\": \"$tracking_id\"" "$SLA_DATA_FILE" | tail -1)
    local discovery_time=$(echo "$entry" | jq -r '.discovery_time')
    local sla_deadline=$(echo "$entry" | jq -r '.sla_deadline')

    local discovery_epoch closure_epoch deadline_epoch
    if [[ "$OSTYPE" == "darwin"* ]]; then
        discovery_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$discovery_time" "+%s" 2>/dev/null || date +%s)
        closure_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$closure_time" "+%s" 2>/dev/null || date +%s)
        deadline_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$sla_deadline" "+%s" 2>/dev/null || date +%s)
    else
        discovery_epoch=$(date -d "$discovery_time" +%s 2>/dev/null || date +%s)
        closure_epoch=$(date -d "$closure_time" +%s 2>/dev/null || date +%s)
        deadline_epoch=$(date -d "$sla_deadline" +%s 2>/dev/null || date +%s)
    fi

    local resolution_hours=$(echo "scale=2; ($closure_epoch - $discovery_epoch) / 3600" | bc)
    local breached="false"

    if [[ "$closure_epoch" -gt "$deadline_epoch" ]]; then
        breached="true"
    fi

    # Create updated entry
    local updated_entry=$(echo "$entry" | jq \
        --arg status "closed" \
        --arg closure "$closure_time" \
        --arg notes "$resolution_notes" \
        --arg breached "$breached" \
        --arg hours "$resolution_hours" \
        '.status = $status |
         .closure_time = $closure |
         .resolution_notes = $notes |
         .breached = ($breached == "true") |
         .time_to_resolution_hours = ($hours | tonumber)')

    # Append updated entry (keep history)
    echo "$updated_entry" >> "$SLA_DATA_FILE"

    # Update metrics
    update_metrics

    echo "Closed vulnerability $tracking_id (breached: $breached)"
}

#
# Check for approaching and breached SLAs
#
check_sla_status() {
    if [[ ! -f "$SLA_DATA_FILE" ]]; then
        echo "[]"
        return
    fi

    local alerts='[]'
    local now_epoch=$(date +%s)

    # Get all open vulnerabilities
    grep '"status": "open"' "$SLA_DATA_FILE" | while read -r entry; do
        local tracking_id=$(echo "$entry" | jq -r '.tracking_id')
        local vuln_id=$(echo "$entry" | jq -r '.vulnerability_id')
        local severity=$(echo "$entry" | jq -r '.severity')
        local deadline=$(echo "$entry" | jq -r '.sla_deadline')
        local sla_hours=$(echo "$entry" | jq -r '.sla_hours')

        local remaining=$(calculate_time_remaining "$deadline")
        local remaining_hours=$(echo "scale=2; $remaining / 3600" | bc)
        local percent_remaining=$(echo "scale=2; ($remaining_hours / $sla_hours) * 100" | bc)

        local alert_level=""
        local alert_message=""

        if [[ $(echo "$remaining < 0" | bc -l) -eq 1 ]]; then
            alert_level="breached"
            alert_message="SLA BREACHED: $vuln_id ($severity) deadline was $deadline"

            # Mark as breached in data
            mark_sla_breached "$tracking_id"
        elif [[ $(echo "$percent_remaining < $ALERT_CRITICAL_THRESHOLD" | bc -l) -eq 1 ]]; then
            alert_level="critical"
            alert_message="CRITICAL: $vuln_id ($severity) only $remaining_hours hours remaining"
        elif [[ $(echo "$percent_remaining < $ALERT_WARNING_THRESHOLD" | bc -l) -eq 1 ]]; then
            alert_level="warning"
            alert_message="WARNING: $vuln_id ($severity) $remaining_hours hours remaining"
        fi

        if [[ -n "$alert_level" ]]; then
            local alert=$(jq -n \
                --arg id "sla-alert-$(date +%s%N | cut -b1-10)" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg level "$alert_level" \
                --arg msg "$alert_message" \
                --arg tid "$tracking_id" \
                --arg vid "$vuln_id" \
                --arg sev "$severity" \
                --arg remaining "$remaining_hours" \
                '{
                    alert_id: $id,
                    timestamp: $ts,
                    level: $level,
                    message: $msg,
                    tracking_id: $tid,
                    vulnerability_id: $vid,
                    severity: $sev,
                    hours_remaining: ($remaining | tonumber)
                }')

            echo "$alert" >> "$SLA_ALERTS_FILE"
            echo "$alert"
        fi
    done
}

#
# Mark SLA as breached
#
mark_sla_breached() {
    local tracking_id="$1"

    # This is called when check detects a breach
    # The actual breach marking happens in close_vulnerability
    echo "SLA breach detected for: $tracking_id" >&2
}

#
# Update SLA metrics
#
update_metrics() {
    if [[ ! -f "$SLA_DATA_FILE" ]]; then
        return
    fi

    # Get latest status for each tracking_id (since we append updates)
    local latest_entries=$(tac "$SLA_DATA_FILE" | awk -F'"tracking_id": "' '!seen[$2]++' | tac)

    local total=$(echo "$latest_entries" | wc -l | tr -d ' ')
    local open=$(echo "$latest_entries" | grep -c '"status": "open"' || echo "0")
    local closed=$(echo "$latest_entries" | grep -c '"status": "closed"' || echo "0")
    local breached=$(echo "$latest_entries" | grep -c '"breached": true' || echo "0")
    local closed_within_sla=$((closed - breached))

    # Calculate by severity
    local crit_open=$(echo "$latest_entries" | grep '"severity": "critical"' | grep -c '"status": "open"' || echo "0")
    local crit_closed=$(echo "$latest_entries" | grep '"severity": "critical"' | grep -c '"status": "closed"' || echo "0")
    local crit_breached=$(echo "$latest_entries" | grep '"severity": "critical"' | grep -c '"breached": true' || echo "0")

    local high_open=$(echo "$latest_entries" | grep '"severity": "high"' | grep -c '"status": "open"' || echo "0")
    local high_closed=$(echo "$latest_entries" | grep '"severity": "high"' | grep -c '"status": "closed"' || echo "0")
    local high_breached=$(echo "$latest_entries" | grep '"severity": "high"' | grep -c '"breached": true' || echo "0")

    local med_open=$(echo "$latest_entries" | grep '"severity": "medium"' | grep -c '"status": "open"' || echo "0")
    local med_closed=$(echo "$latest_entries" | grep '"severity": "medium"' | grep -c '"status": "closed"' || echo "0")
    local med_breached=$(echo "$latest_entries" | grep '"severity": "medium"' | grep -c '"breached": true' || echo "0")

    local low_open=$(echo "$latest_entries" | grep '"severity": "low"' | grep -c '"status": "open"' || echo "0")
    local low_closed=$(echo "$latest_entries" | grep '"severity": "low"' | grep -c '"status": "closed"' || echo "0")
    local low_breached=$(echo "$latest_entries" | grep '"severity": "low"' | grep -c '"breached": true' || echo "0")

    # Calculate average resolution time
    local avg_time=0
    if [[ "$closed" -gt 0 ]]; then
        local total_time=$(echo "$latest_entries" | grep '"status": "closed"' | \
            jq -r '.time_to_resolution_hours // 0' | awk '{sum+=$1} END {print sum}')
        avg_time=$(echo "scale=2; $total_time / $closed" | bc)
    fi

    # Calculate compliance rate
    local compliance_rate=100
    if [[ "$closed" -gt 0 ]]; then
        compliance_rate=$(echo "scale=2; ($closed_within_sla / $closed) * 100" | bc)
    fi

    # Update metrics file
    jq -n \
        --arg total "$total" \
        --arg open "$open" \
        --arg closed_sla "$closed_within_sla" \
        --arg breached "$breached" \
        --arg crit_open "$crit_open" \
        --arg crit_closed "$crit_closed" \
        --arg crit_breached "$crit_breached" \
        --arg high_open "$high_open" \
        --arg high_closed "$high_closed" \
        --arg high_breached "$high_breached" \
        --arg med_open "$med_open" \
        --arg med_closed "$med_closed" \
        --arg med_breached "$med_breached" \
        --arg low_open "$low_open" \
        --arg low_closed "$low_closed" \
        --arg low_breached "$low_breached" \
        --arg avg "$avg_time" \
        --arg rate "$compliance_rate" \
        --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            total_tracked: ($total | tonumber),
            open_vulnerabilities: ($open | tonumber),
            closed_within_sla: ($closed_sla | tonumber),
            breached_sla: ($breached | tonumber),
            by_severity: {
                critical: {
                    open: ($crit_open | tonumber),
                    closed: ($crit_closed | tonumber),
                    breached: ($crit_breached | tonumber)
                },
                high: {
                    open: ($high_open | tonumber),
                    closed: ($high_closed | tonumber),
                    breached: ($high_breached | tonumber)
                },
                medium: {
                    open: ($med_open | tonumber),
                    closed: ($med_closed | tonumber),
                    breached: ($med_breached | tonumber)
                },
                low: {
                    open: ($low_open | tonumber),
                    closed: ($low_closed | tonumber),
                    breached: ($low_breached | tonumber)
                }
            },
            avg_remediation_time_hours: ($avg | tonumber),
            sla_compliance_rate: ($rate | tonumber),
            last_updated: $updated
        }' > "$SLA_METRICS_FILE"
}

#
# Get open vulnerabilities by severity
#
get_open_vulnerabilities() {
    local severity="${1:-}"

    if [[ ! -f "$SLA_DATA_FILE" ]]; then
        echo "[]"
        return
    fi

    if [[ -n "$severity" ]]; then
        grep '"status": "open"' "$SLA_DATA_FILE" | grep "\"severity\": \"$severity\"" | jq -s '.'
    else
        grep '"status": "open"' "$SLA_DATA_FILE" | jq -s 'sort_by(.sla_deadline)'
    fi
}

#
# Get SLA metrics
#
get_sla_metrics() {
    if [[ ! -f "$SLA_METRICS_FILE" ]]; then
        initialize_sla_tracking
    fi

    cat "$SLA_METRICS_FILE"
}

#
# Get approaching deadlines
#
get_approaching_deadlines() {
    local hours="${1:-24}"

    if [[ ! -f "$SLA_DATA_FILE" ]]; then
        echo "[]"
        return
    fi

    local now_epoch=$(date +%s)
    local threshold_epoch=$((now_epoch + (hours * 3600)))

    grep '"status": "open"' "$SLA_DATA_FILE" | while read -r entry; do
        local deadline=$(echo "$entry" | jq -r '.sla_deadline')
        local deadline_epoch

        if [[ "$OSTYPE" == "darwin"* ]]; then
            deadline_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$deadline" "+%s" 2>/dev/null || echo "0")
        else
            deadline_epoch=$(date -d "$deadline" +%s 2>/dev/null || echo "0")
        fi

        if [[ "$deadline_epoch" -le "$threshold_epoch" ]]; then
            echo "$entry"
        fi
    done | jq -s 'sort_by(.sla_deadline)'
}

#
# Generate SLA report
#
generate_sla_report() {
    update_metrics

    local metrics=$(get_sla_metrics)
    local approaching=$(get_approaching_deadlines 48)
    local open_critical=$(get_open_vulnerabilities "critical")
    local open_high=$(get_open_vulnerabilities "high")

    jq -n \
        --argjson metrics "$metrics" \
        --argjson approaching "$approaching" \
        --argjson critical "$open_critical" \
        --argjson high "$open_high" \
        '{
            generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            metrics: $metrics,
            approaching_deadlines_48h: $approaching,
            open_critical: $critical,
            open_high: $high,
            recommended_actions: (
                if ($critical | length) > 0 then
                    ["IMMEDIATE: Address critical vulnerabilities within 24h SLA"]
                else
                    []
                end +
                if ($approaching | length) > 0 then
                    ["URGENT: Review vulnerabilities with approaching deadlines"]
                else
                    []
                end
            )
        }'
}

# Export functions
export -f initialize_sla_tracking
export -f track_vulnerability
export -f close_vulnerability
export -f check_sla_status
export -f get_sla_metrics
export -f get_open_vulnerabilities
export -f get_approaching_deadlines
export -f generate_sla_report
export -f calculate_sla_deadline
