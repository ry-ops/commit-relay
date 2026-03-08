#!/bin/bash
# scripts/daemons/failure-pattern-daemon.sh
# Failure Pattern Detection Daemon - Phase 4.4 Self-Healing Implementation
# Monitors failure events and detects recurring patterns
#
# Features:
#   - Polls for new failure events every 5 minutes
#   - Runs pattern detection algorithms
#   - Updates pattern database
#   - Emits alerts for new patterns
#   - Generates daily pattern reports
#
# Usage:
#   ./scripts/daemons/failure-pattern-daemon.sh
#   or via systemd/launchd for auto-start

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load libraries
source "$COMMIT_RELAY_HOME/scripts/lib/failure-pattern-detection.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || true

# Daemon configuration
DAEMON_NAME="commit-relay-failure-pattern"
POLL_INTERVAL="${PATTERN_DETECTION_POLL_INTERVAL:-300}"  # Check every 5 minutes
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/failure-pattern-daemon.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
METRICS_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/failure-pattern-metrics.json"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$METRICS_FILE")"

# Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

log_daemon() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_daemon "ERROR: Failure pattern daemon already running with PID $OLD_PID"
        exit 1
    else
        log_daemon "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_daemon "INFO: Failure pattern detection daemon starting (PID $$)"
log_daemon "INFO: Poll interval: ${POLL_INTERVAL}s"
log_daemon "INFO: Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_daemon "INFO: Failure pattern daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Metrics counters
TOTAL_PATTERNS_DETECTED=0
TOTAL_EVENTS_ANALYZED=0
CYCLE_COUNT=0

# ============================================================================
# Metrics Collection
# ============================================================================

save_metrics() {
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Count patterns by category
    local patterns_by_category="{}"
    if [ -f "$PATTERN_DB" ]; then
        patterns_by_category=$(jq -s 'group_by(.category) | map({(.[0].category): length}) | add // {}' "$PATTERN_DB" 2>/dev/null || echo "{}")
    fi

    # Count patterns by severity
    local patterns_by_severity="{}"
    if [ -f "$PATTERN_DB" ]; then
        patterns_by_severity=$(jq -s 'group_by(.severity) | map({(.[0].severity): length}) | add // {}' "$PATTERN_DB" 2>/dev/null || echo "{}")
    fi

    # Get total patterns
    local total_patterns=$(grep -c . "$PATTERN_DB" 2>/dev/null || echo "0")

    # Calculate average confidence
    local avg_confidence="0"
    if [ "$total_patterns" -gt 0 ]; then
        avg_confidence=$(jq -s 'map(.confidence) | add / length' "$PATTERN_DB" 2>/dev/null || echo "0")
    fi

    local metrics_json=$(jq -nc \
        --arg timestamp "$timestamp" \
        --argjson total "$total_patterns" \
        --argjson by_category "$patterns_by_category" \
        --argjson by_severity "$patterns_by_severity" \
        --argjson detected "$TOTAL_PATTERNS_DETECTED" \
        --argjson analyzed "$TOTAL_EVENTS_ANALYZED" \
        --argjson avg_conf "$avg_confidence" \
        '{
            timestamp: $timestamp,
            total_patterns: $total,
            patterns_by_category: $by_category,
            patterns_by_severity: $by_severity,
            patterns_detected_session: $detected,
            events_analyzed_session: $analyzed,
            average_confidence: $avg_conf
        }')

    echo "$metrics_json" > "$METRICS_FILE"

    # Also append to time series log
    local metrics_log="${COMMIT_RELAY_HOME}/coordination/metrics/failure-pattern-history.jsonl"
    mkdir -p "$(dirname "$metrics_log")"
    echo "$metrics_json" >> "$metrics_log"
}

# ============================================================================
# Daily Report Generation
# ============================================================================

generate_daily_report() {
    local report_dir="$COMMIT_RELAY_HOME/coordination/reports/failure-patterns"
    mkdir -p "$report_dir"

    local report_date=$(date +%Y-%m-%d)
    local report_file="$report_dir/${report_date}-failure-pattern-report.md"

    log_daemon "INFO: Generating daily report: $report_file"

    # Count patterns
    local total_patterns=$(grep -c . "$PATTERN_DB" 2>/dev/null || echo "0")

    # Get high severity patterns
    local high_severity=$(jq -s 'map(select(.severity == "high" or .severity == "critical"))' "$PATTERN_DB" 2>/dev/null || echo "[]")
    local high_count=$(echo "$high_severity" | jq 'length')

    # Create report
    cat > "$report_file" <<EOFREPORT
# Failure Pattern Detection Report
**Date**: $report_date
**Generated**: $(date +%Y-%m-%dT%H:%M:%S%z)

---

## Summary

- **Total Patterns**: $total_patterns
- **High/Critical Severity**: $high_count
- **Events Analyzed (24h)**: $TOTAL_EVENTS_ANALYZED
- **New Patterns Detected (24h)**: $TOTAL_PATTERNS_DETECTED

---

## High Severity Patterns

EOFREPORT

    # Add high severity patterns if any
    if [ "$high_count" -gt 0 ]; then
        echo "$high_severity" | jq -r '.[] | "### \(.pattern_id)\n- **Category**: \(.category)\n- **Type**: \(.type)\n- **Occurrences**: \(.frequency.total_occurrences)\n- **Confidence**: \(.confidence)\n- **Worker Type**: \(.signature.worker_type)\n\n"' >> "$report_file"
    else
        echo "No high severity patterns detected." >> "$report_file"
    fi

    cat >> "$report_file" <<EOFREPORT

---

## Pattern Distribution

### By Category

EOFREPORT

    # Add category breakdown
    if [ "$total_patterns" -gt 0 ]; then
        jq -s 'group_by(.category) | map("\(.[] | .category): \(length) patterns") | .[]' "$PATTERN_DB" 2>/dev/null | while read -r line; do
            echo "- $line" >> "$report_file"
        done
    fi

    cat >> "$report_file" <<EOFREPORT

### By Worker Type

EOFREPORT

    # Add worker type breakdown
    if [ "$total_patterns" -gt 0 ]; then
        jq -s 'group_by(.signature.worker_type) | map("\(.[] | .signature.worker_type): \(length) patterns") | .[]' "$PATTERN_DB" 2>/dev/null | while read -r line; do
            echo "- $line" >> "$report_file"
        done
    fi

    log_daemon "INFO: Daily report generated: $report_file"
}

# ============================================================================
# Main Processing Loop
# ============================================================================

while true; do
    cd "$COMMIT_RELAY_HOME"

    ((CYCLE_COUNT++))
    log_daemon "INFO: Starting pattern detection cycle #$CYCLE_COUNT"

    # Run pattern analysis
    patterns_detected=$(analyze_patterns 2>&1 || echo "0")

    if [ "$patterns_detected" != "0" ]; then
        ((TOTAL_PATTERNS_DETECTED += patterns_detected))
        log_daemon "INFO: Detected $patterns_detected patterns this cycle"
    fi

    # Save metrics
    save_metrics

    # Generate daily report (once per day at midnight)
    current_hour=$(date +%H)
    if [ "$current_hour" = "00" ] && [ $((CYCLE_COUNT % 12)) -eq 1 ]; then
        generate_daily_report
    fi

    # Log summary
    log_daemon "INFO: Cycle #$CYCLE_COUNT complete - Patterns detected: $TOTAL_PATTERNS_DETECTED, Events analyzed: $TOTAL_EVENTS_ANALYZED"

    # Sleep until next cycle
    sleep "$POLL_INTERVAL"
done
