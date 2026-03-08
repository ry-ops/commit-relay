#!/bin/bash
# Governance Monitoring Daemon
# Continuously monitors governance health and generates alerts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Configuration
MONITOR_INTERVAL=300  # 5 minutes
HEALTH_THRESHOLD=85   # Alert if health score drops below 85

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] GOVERNANCE-MONITOR: $1"
}

check_governance_health() {
    log "Checking governance health..."

    # Run governance dashboard check
    local health_json=$(node "$COMMIT_RELAY_HOME/lib/governance/compliance.js" dashboard 2>/dev/null)
    local health_score=$(echo "$health_json" | jq -r '.health_score // 0')
    local status=$(echo "$health_json" | jq -r '.status // "unknown"')

    log "Health Score: $health_score/100 (Status: $status)"

    # Check for critical alerts
    local critical_alerts=$(echo "$health_json" | jq -r '.alerts.critical // 0')
    local high_alerts=$(echo "$health_json" | jq -r '.alerts.high // 0')

    if [ "$critical_alerts" -gt 0 ]; then
        log "⚠️  CRITICAL: $critical_alerts critical alerts detected!"
    fi

    if [ "$high_alerts" -gt 0 ]; then
        log "⚠️  HIGH: $high_alerts high-priority alerts detected!"
    fi

    # Check health threshold
    if (( $(echo "$health_score < $HEALTH_THRESHOLD" | bc -l) )); then
        log "❌ Health score below threshold ($health_score < $HEALTH_THRESHOLD)"

        # Get recommendations
        local recommendations=$(echo "$health_json" | jq -r '.top_recommendations[] | "  - [\(.priority)] \(.recommendation)"')
        log "Recommendations:"
        echo "$recommendations" | while read -r line; do
            log "$line"
        done
    else
        log "✅ Governance health: $status ($health_score/100)"
    fi

    # Log metrics
    log "Metrics:"
    log "  Compliance: $(echo "$health_json" | jq -r '.kpi_summary.compliance')"
    log "  Security: $(echo "$health_json" | jq -r '.kpi_summary.security')"
    log "  Quality: $(echo "$health_json" | jq -r '.kpi_summary.quality')"
    log "  Availability: $(echo "$health_json" | jq -r '.kpi_summary.availability')"
}

run_compliance_checks() {
    log "Running compliance checks..."

    local report=$(node "$COMMIT_RELAY_HOME/lib/governance/compliance.js" compliance-report 2>/dev/null)
    local total_violations=$(echo "$report" | jq -r '.summary.total_violations // 0')
    local compliance_rate=$(echo "$report" | jq -r '.summary.compliance_rate // "0%"')

    log "Compliance Rate: $compliance_rate (Violations: $total_violations)"

    if [ "$total_violations" -gt 0 ]; then
        log "⚠️  Compliance violations detected:"
        echo "$report" | jq -r '.frameworks[] | select(.compliant == false) | .results[] | select(.compliant == false) | "  - [\(.rule_id)] \(.rule_name): \(.evidence)"' | while read -r line; do
            log "$line"
        done
    fi
}

check_pii_detections() {
    log "Checking recent PII detections..."

    local pii_log="$COMMIT_RELAY_HOME/coordination/governance/pii-detections.jsonl"
    if [ -f "$pii_log" ]; then
        local recent_count=$(tail -100 "$pii_log" | wc -l | tr -d ' ')
        if [ "$recent_count" -gt 0 ]; then
            log "⚠️  $recent_count PII detections in recent activity"

            # Get critical PII detections
            local critical=$(tail -100 "$pii_log" | jq -r 'select(.severity == "critical") | "\(.pii_type) in \(.context.source // "unknown")"' 2>/dev/null | head -5)
            if [ -n "$critical" ]; then
                log "Critical PII detections:"
                echo "$critical" | while read -r line; do
                    log "  - $line"
                done
            fi
        fi
    fi
}

check_drift_detections() {
    log "Checking for agent performance drift..."

    local drift_log="$COMMIT_RELAY_HOME/coordination/governance/drift-detections.jsonl"
    if [ -f "$drift_log" ]; then
        local recent_drift=$(tail -50 "$drift_log" | jq -r 'select(.drifts | length > 0) | "\(.agent_id): \(.drifts | length) metrics drifting"' 2>/dev/null | head -5)
        if [ -n "$recent_drift" ]; then
            log "⚠️  Agent performance drift detected:"
            echo "$recent_drift" | while read -r line; do
                log "  - $line"
            done
        fi
    fi
}

generate_summary_report() {
    local report_file="$COMMIT_RELAY_HOME/coordination/governance/monitoring-summary.json"

    cat > "$report_file" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "health_check": $(node "$COMMIT_RELAY_HOME/lib/governance/compliance.js" dashboard 2>/dev/null || echo '{"error": "failed"}'),
  "compliance": $(node "$COMMIT_RELAY_HOME/lib/governance/compliance.js" compliance-report 2>/dev/null || echo '{"error": "failed"}'),
  "metrics": $(node "$COMMIT_RELAY_HOME/lib/governance/compliance.js" metrics 2>/dev/null || echo '{"error": "failed"}')
}
EOF

    log "Summary report saved to: $report_file"
}

# Main monitoring loop
main() {
    log "Starting Governance Monitoring Daemon"
    log "Interval: ${MONITOR_INTERVAL}s, Health Threshold: ${HEALTH_THRESHOLD}/100"

    while true; do
        echo ""
        log "=== Governance Health Check ==="

        check_governance_health
        echo ""

        run_compliance_checks
        echo ""

        check_pii_detections
        echo ""

        check_drift_detections
        echo ""

        generate_summary_report

        log "=== Check Complete ==="
        log "Next check in ${MONITOR_INTERVAL} seconds"
        sleep "$MONITOR_INTERVAL"
    done
}

# Handle interrupts gracefully
trap 'log "Governance monitoring daemon stopped"; exit 0' INT TERM

# Run daemon
main
