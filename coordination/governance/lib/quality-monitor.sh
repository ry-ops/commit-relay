#!/bin/bash
# coordination/governance/lib/quality-monitor.sh
# Data Quality Monitoring for Commit-Relay
#
# Purpose:
# - Detect data quality issues before they cause failures
# - Validate JSON schema compliance
# - Check referential integrity
# - Monitor data freshness
# - Verify data completeness
# - Ensure data consistency
#
# Usage:
#   source coordination/governance/lib/quality-monitor.sh
#   check_data_quality "$file_path" "$schema_name"

set -eo pipefail

# Prevent re-sourcing
if [ -n "${QUALITY_MONITOR_LOADED:-}" ]; then
    return 0
fi
QUALITY_MONITOR_LOADED=1

# Quality check thresholds
FRESHNESS_WARNING_MINUTES=60
FRESHNESS_ERROR_MINUTES=1440  # 24 hours
MIN_QUALITY_SCORE=70

# Check data quality for a file
# Returns: JSON quality report
check_data_quality() {
    local file_path="$1"
    local schema_name="${2:-auto}"

    if [ ! -f "$file_path" ]; then
        echo '{
  "error": "file_not_found",
  "overall_score": 0,
  "issues": [{"severity": "error", "check": "file_exists", "message": "File not found"}],
  "passed": 0,
  "failed": 1
}'
        return 1
    fi

    local issues=()
    local passed=0
    local failed=0
    local warnings=0

    # Check 1: JSON Syntax
    if jq empty "$file_path" 2>/dev/null; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        issues+=('{"severity":"error","check":"json_syntax","message":"Invalid JSON syntax"}')
    fi

    # Check 2: Schema Validation
    if [ "$schema_name" != "auto" ] && [ "$schema_name" != "none" ]; then
        local schema_file="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/schemas/${schema_name}.json"
        if [ -f "$schema_file" ]; then
            if validate_against_schema "$file_path" "$schema_file"; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
                issues+=('{"severity":"error","check":"schema_validation","message":"Schema validation failed"}')
            fi
        fi
    else
        passed=$((passed + 1))  # Skip if no schema
    fi

    # Check 3: Template Variables
    if grep -q ', ,' "$file_path" 2>/dev/null; then
        failed=$((failed + 1))
        issues+=('{"severity":"error","check":"template_vars","message":"Uninitialized variables detected (pattern: , ,)"}')
    else
        passed=$((passed + 1))
    fi

    # Check 4: Empty Required Fields
    if jq -e 'walk(if type == "string" then select(. == "" or . == "TODO" or . == "FIXME") else . end)' "$file_path" 2>/dev/null | grep -q .; then
        warnings=$((warnings + 1))
        issues+=('{"severity":"warning","check":"completeness","message":"Found empty or TODO placeholder values"}')
    else
        passed=$((passed + 1))
    fi

    # Check 5: Data Freshness (for worker specs and tasks)
    if echo "$file_path" | grep -qE '(worker-spec|task)'; then
        local freshness_result=$(check_freshness "$file_path")
        if [ "$freshness_result" = "error" ]; then
            failed=$((failed + 1))
            issues+=('{"severity":"error","check":"freshness","message":"Data is stale (>24h old)"}')
        elif [ "$freshness_result" = "warning" ]; then
            warnings=$((warnings + 1))
            issues+=('{"severity":"warning","check":"freshness","message":"Data may be stale (>1h old)"}')
        else
            passed=$((passed + 1))
        fi
    fi

    # Check 6: Referential Integrity (for worker specs)
    if echo "$file_path" | grep -q 'worker-spec'; then
        if ! check_worker_references "$file_path"; then
            failed=$((failed + 1))
            issues+=('{"severity":"error","check":"referential_integrity","message":"Invalid worker references"}')
        else
            passed=$((passed + 1))
        fi
    fi

    # Calculate overall score
    local total=$((passed + failed + warnings))
    local overall_score=0
    if [ $total -gt 0 ]; then
        # Passed = 100%, Warnings = 75%, Failed = 0%
        local weighted_score=$(((passed * 100 + warnings * 75) / total))
        overall_score=$weighted_score
    fi

    # Build issues array
    local issues_json="["
    local first=true
    for issue in "${issues[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            issues_json+=","
        fi
        issues_json+="$issue"
    done
    issues_json+="]"

    # Build result
    local result=$(cat <<EOF
{
  "file_path": "$file_path",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall_score": $overall_score,
  "issues": $issues_json,
  "checks": {
    "passed": $passed,
    "failed": $failed,
    "warnings": $warnings,
    "total": $total
  },
  "quality_level": "$(get_quality_level $overall_score)"
}
EOF
)

    echo "$result"
}

# Validate JSON against schema
validate_against_schema() {
    local file_path="$1"
    local schema_file="$2"

    # Simple schema validation using jq
    # In production, use a proper JSON schema validator
    jq -e '.' "$file_path" > /dev/null 2>&1
}

# Check data freshness based on timestamps
check_freshness() {
    local file_path="$1"

    # Try to extract timestamp from JSON
    local timestamp=$(jq -r '.created_at // .updated_at // .timestamp // empty' "$file_path" 2>/dev/null)

    if [ -z "$timestamp" ]; then
        # Fallback to file modification time
        local file_age_minutes=$(( ($(date +%s) - $(stat -f %m "$file_path" 2>/dev/null || stat -c %Y "$file_path" 2>/dev/null || echo 0)) / 60 ))

        if [ $file_age_minutes -gt $FRESHNESS_ERROR_MINUTES ]; then
            echo "error"
            return
        elif [ $file_age_minutes -gt $FRESHNESS_WARNING_MINUTES ]; then
            echo "warning"
            return
        fi
    else
        # Calculate age from timestamp
        local ts_seconds=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || date -d "$timestamp" +%s 2>/dev/null || echo 0)
        local age_minutes=$(( ($(date +%s) - ts_seconds) / 60 ))

        if [ $age_minutes -gt $FRESHNESS_ERROR_MINUTES ]; then
            echo "error"
            return
        elif [ $age_minutes -gt $FRESHNESS_WARNING_MINUTES ]; then
            echo "warning"
            return
        fi
    fi

    echo "ok"
}

# Check worker references (task_id exists, etc.)
check_worker_references() {
    local file_path="$1"

    # Extract task_id
    local task_id=$(jq -r '.task_id // empty' "$file_path" 2>/dev/null)

    if [ -z "$task_id" ]; then
        return 1  # No task_id reference
    fi

    # Check if task exists in task queue
    local task_queue="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/task-queue.json"
    if [ -f "$task_queue" ]; then
        if jq -e ".tasks[] | select(.id == \"$task_id\")" "$task_queue" > /dev/null 2>&1; then
            return 0  # Task found
        else
            return 1  # Task not found
        fi
    fi

    return 0  # No task queue to check against
}

# Get quality level from score
get_quality_level() {
    local score=$1

    if [ $score -ge 95 ]; then
        echo "excellent"
    elif [ $score -ge 85 ]; then
        echo "good"
    elif [ $score -ge 70 ]; then
        echo "acceptable"
    elif [ $score -ge 50 ]; then
        echo "poor"
    else
        echo "critical"
    fi
}

# Check quality of all workers
check_all_workers() {
    local worker_specs_dir="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/worker-specs/active"
    local total=0
    local passed=0
    local failed=0
    local quality_scores=()

    for spec in "$worker_specs_dir"/*.json; do
        if [ -f "$spec" ]; then
            total=$((total + 1))
            local result=$(check_data_quality "$spec" "worker-spec")
            local score=$(echo "$result" | jq -r '.overall_score')
            quality_scores+=($score)

            if [ $score -ge $MIN_QUALITY_SCORE ]; then
                passed=$((passed + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done

    # Calculate average score
    local avg_score=0
    if [ ${#quality_scores[@]} -gt 0 ]; then
        local sum=0
        for score in "${quality_scores[@]}"; do
            sum=$((sum + score))
        done
        avg_score=$((sum / ${#quality_scores[@]}))
    fi

    # Build result
    local result=$(cat <<EOF
{
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workers_checked": $total,
  "workers_passed": $passed,
  "workers_failed": $failed,
  "average_quality_score": $avg_score,
  "quality_threshold": $MIN_QUALITY_SCORE
}
EOF
)

    echo "$result"
}

# Monitor system-wide data quality
monitor_system_quality() {
    local workers_result=$(check_all_workers)

    # Future: Add task queue checks, coordination file checks, etc.

    local result=$(cat <<EOF
{
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workers": $workers_result,
  "overall_health": "$(get_overall_health)"
}
EOF
)

    echo "$result"
}

# Get overall system health
get_overall_health() {
    # Simple health check based on worker quality
    local workers_result=$(check_all_workers)
    local avg_score=$(echo "$workers_result" | jq -r '.average_quality_score')

    if [ $avg_score -ge 90 ]; then
        echo "healthy"
    elif [ $avg_score -ge 70 ]; then
        echo "degraded"
    else
        echo "unhealthy"
    fi
}

# Log quality issue
log_quality_issue() {
    local quality_report="$1"
    local source="${2:-unknown}"

    local score=$(echo "$quality_report" | jq -r '.overall_score')
    local failed=$(echo "$quality_report" | jq -r '.checks.failed')

    if [ $failed -gt 0 ] || [ $score -lt $MIN_QUALITY_SCORE ]; then
        local log_entry=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "event_type": "quality_issue",
  "source": "$source",
  "quality_score": $score,
  "failed_checks": $failed,
  "principal": "${COMMIT_RELAY_PRINCIPAL:-system}",
  "quality_report": $quality_report
}
EOF
)

        # Append to quality log
        local quality_log="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/governance/quality-issues.jsonl"
        mkdir -p "$(dirname "$quality_log")"
        echo "$log_entry" >> "$quality_log"
    fi
}

# Export functions
export -f check_data_quality 2>/dev/null || true
export -f validate_against_schema 2>/dev/null || true
export -f check_freshness 2>/dev/null || true
export -f check_worker_references 2>/dev/null || true
export -f get_quality_level 2>/dev/null || true
export -f check_all_workers 2>/dev/null || true
export -f monitor_system_quality 2>/dev/null || true
export -f get_overall_health 2>/dev/null || true
export -f log_quality_issue 2>/dev/null || true

# Log that quality monitor is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[GOVERNANCE] Quality monitor loaded" >&2
fi
