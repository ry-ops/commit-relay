#!/usr/bin/env bash
#
# Incident Classifier
# Part of Phase 2 Security Enhancements
#
# Classifies incidents by severity based on:
# - Scope (single worker vs system-wide)
# - Data sensitivity
# - Compliance impact
#
# Usage:
#   source scripts/lib/governance/incident-classifier.sh
#   classify_incident "$incident_data"
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source logging if available
if [[ -f "$PROJECT_ROOT/scripts/lib/logging.sh" ]]; then
    source "$PROJECT_ROOT/scripts/lib/logging.sh"
fi

# Configuration
readonly INCIDENT_LOG_FILE="${INCIDENT_LOG_FILE:-coordination/security/incidents.jsonl}"
readonly CLASSIFICATION_RULES_FILE="${CLASSIFICATION_RULES_FILE:-coordination/policies/classification-rules.json}"

# Severity levels
readonly SEVERITY_CRITICAL=4
readonly SEVERITY_HIGH=3
readonly SEVERITY_MEDIUM=2
readonly SEVERITY_LOW=1
readonly SEVERITY_INFO=0

# Priority levels (determines response time)
readonly PRIORITY_IMMEDIATE=1    # < 1 hour
readonly PRIORITY_URGENT=2       # < 4 hours
readonly PRIORITY_HIGH=3         # < 24 hours
readonly PRIORITY_MEDIUM=4       # < 72 hours
readonly PRIORITY_LOW=5          # < 7 days

#
# Generate incident ID
#
generate_incident_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 4)
    echo "INC-${timestamp}-${random}"
}

#
# Determine scope severity
# Single worker = low, Multiple workers = medium, System-wide = high
#
assess_scope_severity() {
    local incident_data="$1"

    local affected_workers=$(echo "$incident_data" | jq -r '.affected_workers // [] | length')
    local affected_masters=$(echo "$incident_data" | jq -r '.affected_masters // [] | length')
    local is_system_wide=$(echo "$incident_data" | jq -r '.system_wide // false')

    if [[ "$is_system_wide" == "true" ]] || [[ "$affected_masters" -gt 1 ]]; then
        echo $SEVERITY_CRITICAL
    elif [[ "$affected_workers" -gt 5 ]]; then
        echo $SEVERITY_HIGH
    elif [[ "$affected_workers" -gt 1 ]]; then
        echo $SEVERITY_MEDIUM
    else
        echo $SEVERITY_LOW
    fi
}

#
# Determine data sensitivity severity
# PII/credentials = critical, Business data = high, Operational = medium, Public = low
#
assess_data_sensitivity() {
    local incident_data="$1"

    local data_types=$(echo "$incident_data" | jq -r '.data_types_affected // []')
    local has_pii=$(echo "$data_types" | jq -r 'any(. == "pii" or . == "credentials" or . == "secrets")')
    local has_business=$(echo "$data_types" | jq -r 'any(. == "business_critical" or . == "financial")')
    local has_operational=$(echo "$data_types" | jq -r 'any(. == "operational" or . == "config")')

    if [[ "$has_pii" == "true" ]]; then
        echo $SEVERITY_CRITICAL
    elif [[ "$has_business" == "true" ]]; then
        echo $SEVERITY_HIGH
    elif [[ "$has_operational" == "true" ]]; then
        echo $SEVERITY_MEDIUM
    else
        echo $SEVERITY_LOW
    fi
}

#
# Determine compliance impact severity
# Regulatory breach = critical, Policy violation = high, Best practice = medium
#
assess_compliance_impact() {
    local incident_data="$1"

    local compliance_flags=$(echo "$incident_data" | jq -r '.compliance_flags // []')
    local has_regulatory=$(echo "$compliance_flags" | jq -r 'any(. == "gdpr" or . == "hipaa" or . == "pci-dss" or . == "sox")')
    local has_policy=$(echo "$compliance_flags" | jq -r 'any(. == "policy_violation" or . == "access_control")')
    local has_best_practice=$(echo "$compliance_flags" | jq -r 'any(. == "best_practice" or . == "security_hygiene")')

    if [[ "$has_regulatory" == "true" ]]; then
        echo $SEVERITY_CRITICAL
    elif [[ "$has_policy" == "true" ]]; then
        echo $SEVERITY_HIGH
    elif [[ "$has_best_practice" == "true" ]]; then
        echo $SEVERITY_MEDIUM
    else
        echo $SEVERITY_LOW
    fi
}

#
# Assess incident type severity
#
assess_incident_type() {
    local incident_type="$1"

    case "$incident_type" in
        # Critical incidents
        "data_breach"|"credential_exposure"|"ransomware"|"active_attack")
            echo $SEVERITY_CRITICAL
            ;;
        # High severity incidents
        "unauthorized_access"|"privilege_escalation"|"malware_detected"|"critical_vulnerability")
            echo $SEVERITY_HIGH
            ;;
        # Medium severity incidents
        "policy_violation"|"suspicious_activity"|"failed_auth_cluster"|"high_vulnerability")
            echo $SEVERITY_MEDIUM
            ;;
        # Low severity incidents
        "audit_finding"|"configuration_drift"|"medium_vulnerability"|"low_vulnerability")
            echo $SEVERITY_LOW
            ;;
        # Informational
        *)
            echo $SEVERITY_INFO
            ;;
    esac
}

#
# Calculate overall severity (weighted average)
#
calculate_overall_severity() {
    local scope_severity="$1"
    local data_severity="$2"
    local compliance_severity="$3"
    local type_severity="$4"

    # Weights: type=0.3, scope=0.25, data=0.25, compliance=0.2
    local weighted_score=$(echo "scale=2; ($type_severity * 0.30) + ($scope_severity * 0.25) + ($data_severity * 0.25) + ($compliance_severity * 0.20)" | bc)

    # Round to nearest integer
    local rounded_score=$(echo "($weighted_score + 0.5) / 1" | bc)

    # Map score to severity level
    if [[ "$rounded_score" -ge 4 ]]; then
        echo "critical"
    elif [[ "$rounded_score" -ge 3 ]]; then
        echo "high"
    elif [[ "$rounded_score" -ge 2 ]]; then
        echo "medium"
    elif [[ "$rounded_score" -ge 1 ]]; then
        echo "low"
    else
        echo "info"
    fi
}

#
# Determine priority based on severity and context
#
determine_priority() {
    local severity="$1"
    local incident_data="$2"

    local is_active_threat=$(echo "$incident_data" | jq -r '.active_threat // false')
    local business_hours=$(date +%H)

    case "$severity" in
        "critical")
            if [[ "$is_active_threat" == "true" ]]; then
                echo $PRIORITY_IMMEDIATE
            else
                echo $PRIORITY_URGENT
            fi
            ;;
        "high")
            echo $PRIORITY_HIGH
            ;;
        "medium")
            echo $PRIORITY_MEDIUM
            ;;
        "low"|"info")
            echo $PRIORITY_LOW
            ;;
        *)
            echo $PRIORITY_MEDIUM
            ;;
    esac
}

#
# Get SLA response time based on priority
#
get_sla_response_time() {
    local priority="$1"

    case "$priority" in
        $PRIORITY_IMMEDIATE)
            echo "1h"
            ;;
        $PRIORITY_URGENT)
            echo "4h"
            ;;
        $PRIORITY_HIGH)
            echo "24h"
            ;;
        $PRIORITY_MEDIUM)
            echo "72h"
            ;;
        $PRIORITY_LOW)
            echo "7d"
            ;;
        *)
            echo "24h"
            ;;
    esac
}

#
# Generate recommended actions based on incident type and severity
#
generate_recommended_actions() {
    local incident_type="$1"
    local severity="$2"

    local actions='[]'

    case "$incident_type" in
        "data_breach"|"credential_exposure")
            actions='[
                "Immediately isolate affected systems",
                "Rotate all exposed credentials",
                "Notify security team and management",
                "Begin forensic investigation",
                "Prepare breach notification if required"
            ]'
            ;;
        "unauthorized_access"|"privilege_escalation")
            actions='[
                "Revoke compromised access immediately",
                "Review audit logs for scope",
                "Reset affected user credentials",
                "Check for lateral movement",
                "Update access controls"
            ]'
            ;;
        "malware_detected"|"ransomware")
            actions='[
                "Isolate affected system from network",
                "Do not reboot or power off",
                "Capture memory and disk images",
                "Identify infection vector",
                "Scan all connected systems"
            ]'
            ;;
        "critical_vulnerability"|"high_vulnerability")
            actions='[
                "Apply emergency patch if available",
                "Implement compensating controls",
                "Monitor for exploitation attempts",
                "Update WAF/IDS rules",
                "Schedule formal remediation"
            ]'
            ;;
        "policy_violation"|"configuration_drift")
            actions='[
                "Document the violation",
                "Restore compliant configuration",
                "Review change management process",
                "Update monitoring rules",
                "Provide team training if needed"
            ]'
            ;;
        *)
            actions='[
                "Document incident details",
                "Assess impact and scope",
                "Implement appropriate remediation",
                "Update incident tracking"
            ]'
            ;;
    esac

    echo "$actions"
}

#
# Classify an incident
#
classify_incident() {
    local incident_data="$1"

    # Extract incident type
    local incident_type=$(echo "$incident_data" | jq -r '.incident_type // "unknown"')

    # Assess severity from multiple dimensions
    local scope_severity=$(assess_scope_severity "$incident_data")
    local data_severity=$(assess_data_sensitivity "$incident_data")
    local compliance_severity=$(assess_compliance_impact "$incident_data")
    local type_severity=$(assess_incident_type "$incident_type")

    # Calculate overall severity
    local overall_severity=$(calculate_overall_severity "$scope_severity" "$data_severity" "$compliance_severity" "$type_severity")

    # Determine priority
    local priority=$(determine_priority "$overall_severity" "$incident_data")
    local sla_time=$(get_sla_response_time "$priority")

    # Generate recommended actions
    local actions=$(generate_recommended_actions "$incident_type" "$overall_severity")

    # Generate incident ID
    local incident_id=$(generate_incident_id)
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build classification result
    local classification=$(jq -n \
        --arg id "$incident_id" \
        --arg ts "$timestamp" \
        --arg type "$incident_type" \
        --arg severity "$overall_severity" \
        --arg priority "$priority" \
        --arg sla "$sla_time" \
        --arg scope_sev "$scope_severity" \
        --arg data_sev "$data_severity" \
        --arg compliance_sev "$compliance_severity" \
        --arg type_sev "$type_severity" \
        --argjson actions "$actions" \
        --argjson original "$incident_data" \
        '{
            incident_id: $id,
            classified_at: $ts,
            incident_type: $type,
            severity: $severity,
            priority: ($priority | tonumber),
            sla_response_time: $sla,
            severity_breakdown: {
                scope: ($scope_sev | tonumber),
                data_sensitivity: ($data_sev | tonumber),
                compliance: ($compliance_sev | tonumber),
                type: ($type_sev | tonumber)
            },
            recommended_actions: $actions,
            status: "new",
            original_data: $original
        }')

    # Log classification
    mkdir -p "$(dirname "$INCIDENT_LOG_FILE")"
    echo "$classification" >> "$INCIDENT_LOG_FILE"

    # Return classification
    echo "$classification"
}

#
# Update health alert with priority
#
add_priority_to_health_alert() {
    local alert_file="$1"

    if [[ ! -f "$alert_file" ]]; then
        echo "Error: Alert file not found: $alert_file" >&2
        return 1
    fi

    local alerts=$(cat "$alert_file")

    # Process each alert and add priority
    local updated_alerts=$(echo "$alerts" | jq '
        .alerts = [.alerts[] |
            . + {
                priority: (
                    if .severity == "critical" then 1
                    elif .severity == "high" then 2
                    elif .severity == "medium" then 3
                    else 4
                    end
                ),
                sla_deadline: (
                    .created_at as $created |
                    if .severity == "critical" then ($created | sub("T.*"; "T") + "01:00:00Z")
                    elif .severity == "high" then ($created | sub("T.*"; "T") + "04:00:00Z")
                    elif .severity == "medium" then ($created | sub("T.*"; "T") + "24:00:00Z")
                    else ($created | sub("T.*"; "T") + "72:00:00Z")
                    end
                )
            }
        ]
    ')

    echo "$updated_alerts" > "$alert_file"
    echo "Updated alerts with priority fields"
}

#
# Get incidents by severity
#
get_incidents_by_severity() {
    local severity="$1"
    local limit="${2:-10}"

    if [[ ! -f "$INCIDENT_LOG_FILE" ]]; then
        echo "[]"
        return
    fi

    tail -1000 "$INCIDENT_LOG_FILE" | jq -s --arg sev "$severity" --arg lim "$limit" '
        map(select(.severity == $sev)) |
        sort_by(.classified_at) |
        reverse |
        .[:($lim | tonumber)]
    '
}

#
# Get open incidents by priority
#
get_open_incidents() {
    local max_priority="${1:-5}"

    if [[ ! -f "$INCIDENT_LOG_FILE" ]]; then
        echo "[]"
        return
    fi

    tail -1000 "$INCIDENT_LOG_FILE" | jq -s --arg mp "$max_priority" '
        map(select(.status != "closed" and .priority <= ($mp | tonumber))) |
        sort_by(.priority, .classified_at)
    '
}

#
# Get incident statistics
#
get_incident_stats() {
    local timeframe="${1:-24h}"

    if [[ ! -f "$INCIDENT_LOG_FILE" ]]; then
        jq -n '{total: 0, by_severity: {}, by_status: {}}'
        return
    fi

    # Calculate cutoff time
    local cutoff=""
    case "$timeframe" in
        "1h") cutoff=$(date -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ) ;;
        "24h") cutoff=$(date -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "1 day ago" +%Y-%m-%dT%H:%M:%SZ) ;;
        "7d") cutoff=$(date -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ) ;;
        *) cutoff="1970-01-01T00:00:00Z" ;;
    esac

    cat "$INCIDENT_LOG_FILE" | jq -s --arg cutoff "$cutoff" '
        map(select(.classified_at >= $cutoff)) |
        {
            total: length,
            by_severity: (group_by(.severity) | map({key: .[0].severity, value: length}) | from_entries),
            by_status: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
            by_priority: (group_by(.priority) | map({key: (.[0].priority | tostring), value: length}) | from_entries),
            avg_priority: (if length > 0 then (map(.priority) | add / length) else 0 end)
        }
    '
}

# Export functions
export -f classify_incident
export -f add_priority_to_health_alert
export -f get_incidents_by_severity
export -f get_open_incidents
export -f get_incident_stats
export -f generate_incident_id
