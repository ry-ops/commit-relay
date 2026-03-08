#!/bin/bash
# scripts/daemons/auto-fix-daemon.sh
# Auto-Fix Daemon - Phase 4.5 Self-Healing Implementation
# Monitors failure patterns and applies automated fixes
#
# Features:
#   - Polls for high-confidence patterns every 10 minutes
#   - Evaluates and applies fixes automatically
#   - Monitors fix effectiveness
#   - Triggers rollbacks on validation failure
#
# Usage:
#   ./scripts/daemons/auto-fix-daemon.sh
#   or via systemd/launchd for auto-start

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load libraries
source "$COMMIT_RELAY_HOME/scripts/lib/auto-fix.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/failure-pattern-detection.sh" 2>/dev/null || true
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || true

# Daemon configuration
DAEMON_NAME="commit-relay-auto-fix"
POLL_INTERVAL="${AUTO_FIX_POLL_INTERVAL:-600}"  # Check every 10 minutes
LOG_FILE="${COMMIT_RELAY_HOME}/agents/logs/system/auto-fix-daemon.log"
PID_FILE="/tmp/${DAEMON_NAME}.pid"
METRICS_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/auto-fix-daemon-metrics.json"

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
        log_daemon "ERROR: Auto-fix daemon already running with PID $OLD_PID"
        exit 1
    else
        log_daemon "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_daemon "INFO: Auto-fix daemon starting (PID $$)"
log_daemon "INFO: Poll interval: ${POLL_INTERVAL}s"
log_daemon "INFO: Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_daemon "INFO: Auto-fix daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Metrics counters
TOTAL_FIXES_APPLIED=0
TOTAL_FIXES_FAILED=0
TOTAL_FIXES_ROLLED_BACK=0
CYCLE_COUNT=0

# ============================================================================
# Metrics Collection
# ============================================================================

save_metrics() {
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Count fixes by category
    local fixes_by_category="{}"
    if [ -f "$FIX_HISTORY_FILE" ]; then
        fixes_by_category=$(jq -s 'group_by(.fix_id | split("_")[1]) | map({(.[0].fix_id | split("_")[1]): length}) | add // {}' "$FIX_HISTORY_FILE" 2>/dev/null || echo "{}")
    fi

    # Count fixes by status
    local fixes_by_status="{}"
    if [ -f "$FIX_HISTORY_FILE" ]; then
        fixes_by_status=$(jq -s 'group_by(.status) | map({(.[0].status): length}) | add // {}' "$FIX_HISTORY_FILE" 2>/dev/null || echo "{}")
    fi

    # Calculate success rate
    local total_fixes=$((TOTAL_FIXES_APPLIED + TOTAL_FIXES_FAILED))
    local success_rate="0"
    if [ "$total_fixes" -gt 0 ]; then
        success_rate=$(echo "scale=4; $TOTAL_FIXES_APPLIED / $total_fixes" | bc)
    fi

    local metrics_json=$(jq -nc \
        --arg timestamp "$timestamp" \
        --argjson applied "$TOTAL_FIXES_APPLIED" \
        --argjson failed "$TOTAL_FIXES_FAILED" \
        --argjson rolled_back "$TOTAL_FIXES_ROLLED_BACK" \
        --argjson by_category "$fixes_by_category" \
        --argjson by_status "$fixes_by_status" \
        --argjson success_rate "$success_rate" \
        '{
            timestamp: $timestamp,
            fixes_applied_session: $applied,
            fixes_failed_session: $failed,
            fixes_rolled_back_session: $rolled_back,
            fixes_by_category: $by_category,
            fixes_by_status: $by_status,
            success_rate: $success_rate
        }')

    echo "$metrics_json" > "$METRICS_FILE"

    # Also append to time series log
    local metrics_log="${COMMIT_RELAY_HOME}/coordination/metrics/auto-fix-history.jsonl"
    mkdir -p "$(dirname "$metrics_log")"
    echo "$metrics_json" >> "$metrics_log"
}

# ============================================================================
# Pattern Evaluation
# ============================================================================

evaluate_patterns_for_fixes() {
    log_daemon "INFO: Evaluating patterns for auto-fix candidates..."

    if [ ! -f "$PATTERN_DB" ]; then
        log_daemon "WARN: Pattern database not found"
        return 0
    fi

    # Get policy thresholds
    local min_confidence=$(jq -r '.pattern_matching.min_pattern_confidence' "$FIX_POLICY_FILE")
    local min_occurrences=$(jq -r '.pattern_matching.min_pattern_occurrences' "$FIX_POLICY_FILE")
    local max_age_hours=$(jq -r '.pattern_matching.max_pattern_age_hours' "$FIX_POLICY_FILE")

    # Calculate age cutoff
    local now=$(date +%s)
    local cutoff=$((now - (max_age_hours * 3600)))

    local candidates=0
    local fixes_attempted=0

    # Read patterns and filter
    while IFS= read -r pattern; do
        local pattern_id=$(echo "$pattern" | jq -r '.pattern_id')
        local confidence=$(echo "$pattern" | jq -r '.confidence')
        local occurrences=$(echo "$pattern" | jq -r '.frequency.total_occurrences')
        local updated_at=$(echo "$pattern" | jq -r '.updated_at')

        # Convert timestamp to epoch
        local pattern_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$updated_at" +%s 2>/dev/null || echo "0")

        # Check if pattern is recent enough
        if [ "$pattern_ts" -lt "$cutoff" ]; then
            continue
        fi

        # Check confidence and occurrences
        if (( $(echo "$confidence < $min_confidence" | bc -l) )); then
            continue
        fi

        if [ "$occurrences" -lt "$min_occurrences" ]; then
            continue
        fi

        # Check if fix already applied recently
        if [ -f "$FIX_HISTORY_FILE" ]; then
            local recent_fix=$(grep "\"pattern_id\":\"$pattern_id\"" "$FIX_HISTORY_FILE" | tail -1 || echo "")
            if [ -n "$recent_fix" ]; then
                local fix_ts=$(echo "$recent_fix" | jq -r '.applied_at')
                local fix_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$fix_ts" +%s 2>/dev/null || echo "0")
                local min_time_between=$(jq -r '.rate_limiting.per_fix.min_time_between_applications_minutes' "$FIX_POLICY_FILE")
                local min_interval=$((min_time_between * 60))

                if [ $((now - fix_epoch)) -lt "$min_interval" ]; then
                    log_daemon "INFO: Skipping $pattern_id - fix applied too recently"
                    continue
                fi
            fi
        fi

        ((candidates++))
        log_daemon "INFO: Pattern candidate for auto-fix: $pattern_id (confidence: $confidence, occurrences: $occurrences)"

        # Try to apply fix
        local applied_fix=$(apply_auto_fix "$pattern_id" 2>&1 || echo "")

        if [ -n "$applied_fix" ] && [ "$applied_fix" != "0" ]; then
            ((TOTAL_FIXES_APPLIED++))
            ((fixes_attempted++))
            log_daemon "SUCCESS: Applied fix for pattern: $pattern_id"
            emit_fix_event "fix_auto_applied" "$applied_fix" "{\"pattern_id\":\"$pattern_id\"}"
        else
            log_daemon "INFO: No applicable fix for pattern: $pattern_id"
        fi

    done < "$PATTERN_DB"

    log_daemon "INFO: Evaluated $candidates pattern candidate(s), applied $fixes_attempted fix(es)"
    return "$fixes_attempted"
}

# ============================================================================
# Fix Validation Monitoring
# ============================================================================

monitor_fix_validation() {
    log_daemon "INFO: Monitoring fix validation..."

    if [ ! -f "$FIX_HISTORY_FILE" ]; then
        return 0
    fi

    local validation_interval=$(jq -r '.validation.validation_check_interval_minutes' "$FIX_POLICY_FILE")
    local auto_rollback=$(jq -r '.validation.auto_rollback_on_failure' "$FIX_POLICY_FILE")

    local now=$(date +%s)
    local recent_cutoff=$((now - (validation_interval * 60)))

    local validations_checked=0

    # Check recent fixes that need validation
    while IFS= read -r fix_entry; do
        local fix_id=$(echo "$fix_entry" | jq -r '.fix_id')
        local pattern_id=$(echo "$fix_entry" | jq -r '.pattern_id')
        local applied_at=$(echo "$fix_entry" | jq -r '.applied_at')
        local status=$(echo "$fix_entry" | jq -r '.status')

        # Skip if not applied status
        if [ "$status" != "applied" ]; then
            continue
        fi

        # Get fix validation config
        local fix=$(get_fix_by_id "$fix_id" 2>/dev/null || echo "")
        if [ -z "$fix" ]; then
            continue
        fi

        local monitoring_period=$(echo "$fix" | jq -r '.validation.monitoring_period_hours // 24')
        local monitoring_seconds=$((monitoring_period * 3600))

        # Check if within monitoring period
        local applied_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$applied_at" +%s 2>/dev/null || echo "0")
        local age=$((now - applied_epoch))

        if [ "$age" -gt "$monitoring_seconds" ]; then
            # Monitoring period expired, mark as validated
            continue
        fi

        # Perform validation check
        ((validations_checked++))
        log_daemon "INFO: Validating fix: $fix_id (age: ${age}s / ${monitoring_seconds}s)"

        if validate_fix_success "$fix_id" "$pattern_id" "$monitoring_period"; then
            log_daemon "SUCCESS: Fix validation passed: $fix_id"
        else
            log_daemon "ERROR: Fix validation failed: $fix_id"

            if [ "$auto_rollback" = "true" ]; then
                local backup_info=$(echo "$fix_entry" | jq -r '.backup_info')
                log_daemon "WARN: Triggering automatic rollback for: $fix_id"

                if rollback_fix "$fix_id" "$backup_info"; then
                    ((TOTAL_FIXES_ROLLED_BACK++))
                    log_daemon "SUCCESS: Fix rolled back: $fix_id"
                else
                    log_daemon "ERROR: Rollback failed for: $fix_id"
                fi
            fi
        fi

    done < <(tac "$FIX_HISTORY_FILE" | head -20)

    log_daemon "INFO: Monitored $validations_checked fix validation(s)"
}

# ============================================================================
# Main Processing Loop
# ============================================================================

while true; do
    cd "$COMMIT_RELAY_HOME"

    ((CYCLE_COUNT++))
    log_daemon "INFO: Starting auto-fix cycle #$CYCLE_COUNT"

    # Check if auto-fix is enabled
    auto_fix_enabled=$(jq -r '.global_settings.auto_fix_enabled' "$FIX_POLICY_FILE")

    if [ "$auto_fix_enabled" != "true" ]; then
        log_daemon "WARN: Auto-fix is disabled, skipping cycle"
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Evaluate patterns for fixes
    fixes_applied=$(evaluate_patterns_for_fixes 2>&1 || echo "0")

    # Monitor validation of previously applied fixes
    monitor_fix_validation

    # Save metrics
    save_metrics

    # Log summary
    log_daemon "INFO: Cycle #$CYCLE_COUNT complete - Fixes applied: $TOTAL_FIXES_APPLIED, Failed: $TOTAL_FIXES_FAILED, Rolled back: $TOTAL_FIXES_ROLLED_BACK"

    # Sleep until next cycle
    sleep "$POLL_INTERVAL"
done
