#!/bin/bash
# scripts/worker-checkin.sh
# Worker check-in helper for PM system
# Provides simple function for workers to report progress

set -euo pipefail

# Configuration
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHECKINS_DIR="$COMMIT_RELAY_HOME/coordination/worker-checkins"

# Ensure check-ins directory exists
mkdir -p "$CHECKINS_DIR"

# Main check-in function
# Usage: worker_checkin <status> <progress> [options]
#
# Arguments:
#   status: starting|in_progress|blocked|completed|failed
#   progress: 0-100 (percentage complete)
#
# Options:
#   --current-step "description"   What worker is doing now
#   --next-step "description"      What worker will do next
#   --time-remaining "estimate"    Time estimate like "15 minutes"
#   --token-usage N                Tokens consumed so far
#   --issue "description"          Non-blocking issue description
#   --request "request_id"         Active request ID
#   --deliverables "description"   Final deliverables (for completion)
#   --failure-reason "reason"      Why task failed (for failures)
#
# Examples:
#   worker_checkin "in_progress" 25
#   worker_checkin "in_progress" 50 --current-step "Writing tests"
#   worker_checkin "completed" 100 --deliverables "PR #123"
#   worker_checkin "failed" 60 --failure-reason "Tests failed"
worker_checkin() {
    local status="$1"
    local progress="$2"
    shift 2

    # Validate required environment variable
    if [ -z "${WORKER_ID:-}" ]; then
        echo "ERROR: WORKER_ID environment variable not set" >&2
        return 1
    fi

    # Validate status
    case "$status" in
        starting|in_progress|blocked|completed|failed)
            ;;
        *)
            echo "ERROR: Invalid status '$status'" >&2
            echo "Valid: starting, in_progress, blocked, completed, failed" >&2
            return 1
            ;;
    esac

    # Validate progress
    if ! [[ "$progress" =~ ^[0-9]+$ ]] || [ "$progress" -lt 0 ] || [ "$progress" -gt 100 ]; then
        echo "ERROR: Progress must be 0-100, got '$progress'" >&2
        return 1
    fi

    # Parse optional arguments
    local current_step=""
    local next_step=""
    local time_remaining=""
    local token_usage=""
    local issues=()
    local requests=()
    local deliverables=""
    local failure_reason=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --current-step)
                current_step="$2"
                shift 2
                ;;
            --next-step)
                next_step="$2"
                shift 2
                ;;
            --time-remaining)
                time_remaining="$2"
                shift 2
                ;;
            --token-usage)
                token_usage="$2"
                shift 2
                ;;
            --issue)
                issues+=("$2")
                shift 2
                ;;
            --request)
                requests+=("$2")
                shift 2
                ;;
            --deliverables)
                deliverables="$2"
                shift 2
                ;;
            --failure-reason)
                failure_reason="$2"
                shift 2
                ;;
            *)
                echo "WARNING: Unknown option '$1', ignoring" >&2
                shift
                ;;
        esac
    done

    # Generate timestamp
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)
    local timestamp_compact=$(date +%Y%m%dT%H%M%SZ)

    # Build check-in JSON
    local checkin_file="$CHECKINS_DIR/${WORKER_ID}-${timestamp_compact}.json"

    # Start building JSON
    local json_builder="jq -n"
    json_builder="$json_builder --arg wid \"$WORKER_ID\""
    json_builder="$json_builder --arg ts \"$timestamp\""
    json_builder="$json_builder --arg status \"$status\""
    json_builder="$json_builder --arg progress \"$progress\""

    local json_template='{
        worker_id: $wid,
        timestamp: $ts,
        status: $status,
        progress_pct: ($progress | tonumber)
    }'

    # Add optional fields
    if [ -n "$current_step" ]; then
        json_builder="$json_builder --arg step \"$current_step\""
        json_template=$(echo "$json_template" | sed 's/}$/, current_step: $step}/')
    fi

    if [ -n "$next_step" ]; then
        json_builder="$json_builder --arg next \"$next_step\""
        json_template=$(echo "$json_template" | sed 's/}$/, next_step: $next}/')
    fi

    if [ -n "$time_remaining" ]; then
        json_builder="$json_builder --arg time \"$time_remaining\""
        json_template=$(echo "$json_template" | sed 's/}$/, time_remaining_estimate: $time}/')
    fi

    if [ -n "$token_usage" ]; then
        json_builder="$json_builder --arg tokens \"$token_usage\""
        json_template=$(echo "$json_template" | sed 's/}$/, token_usage: ($tokens | tonumber)}/')
    fi

    if [ -n "$deliverables" ]; then
        json_builder="$json_builder --arg deliverables \"$deliverables\""
        json_template=$(echo "$json_template" | sed 's/}$/, deliverables: $deliverables}/')
    fi

    if [ -n "$failure_reason" ]; then
        json_builder="$json_builder --arg reason \"$failure_reason\""
        json_template=$(echo "$json_template" | sed 's/}$/, failure_reason: $reason}/')
    fi

    # Add issues array if any
    if [ ${#issues[@]} -gt 0 ]; then
        local issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
        json_builder="$json_builder --argjson issues '$issues_json'"
        json_template=$(echo "$json_template" | sed 's/}$/, issues: $issues}/')
    fi

    # Add requests array if any
    if [ ${#requests[@]} -gt 0 ]; then
        local requests_json=$(printf '%s\n' "${requests[@]}" | jq -R . | jq -s .)
        json_builder="$json_builder --argjson requests '$requests_json'"
        json_template=$(echo "$json_template" | sed 's/}$/, requests: $requests}/')
    fi

    # Generate JSON and write to file
    eval "$json_builder '$json_template'" > "$checkin_file"

    # Verify file was created
    if [ ! -f "$checkin_file" ]; then
        echo "ERROR: Failed to create check-in file" >&2
        return 1
    fi

    # Success (silent by default, can uncomment for debugging)
    # echo "Check-in recorded: $status at $progress%" >&2
    return 0
}

# Convenience function: Quick check-in (minimal)
# Usage: quick_checkin <progress>
quick_checkin() {
    local progress="$1"
    worker_checkin "in_progress" "$progress"
}

# Convenience function: Start check-in
# Usage: checkin_start
checkin_start() {
    worker_checkin "starting" 0 \
        --current-step "Initializing worker and reading task specification" \
        --next-step "Planning implementation approach"
}

# Convenience function: Completion check-in
# Usage: checkin_complete "deliverables description"
checkin_complete() {
    local deliverables="${1:-Task completed successfully}"
    worker_checkin "completed" 100 \
        --current-step "Task completed successfully" \
        --deliverables "$deliverables"
}

# Convenience function: Failure check-in
# Usage: checkin_failed "reason for failure"
checkin_failed() {
    local reason="${1:-Task failed}"
    local progress="${2:-50}"
    worker_checkin "failed" "$progress" \
        --current-step "Task failed" \
        --failure-reason "$reason"
}

# Convenience function: Blocked check-in
# Usage: checkin_blocked "what is blocking" <progress>
checkin_blocked() {
    local blocker="$1"
    local progress="${2:-50}"
    worker_checkin "blocked" "$progress" \
        --current-step "Blocked: $blocker" \
        --issue "$blocker"
}

# Export functions for use in worker scripts
export -f worker_checkin
export -f quick_checkin
export -f checkin_start
export -f checkin_complete
export -f checkin_failed
export -f checkin_blocked

# If executed directly (not sourced), show usage
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    cat << 'EOF'
Worker Check-In Helper

This script provides functions for workers to report progress to the PM system.

USAGE (source this script in your worker):
    source scripts/worker-checkin.sh

MAIN FUNCTION:
    worker_checkin <status> <progress> [options]

    status:   starting | in_progress | blocked | completed | failed
    progress: 0-100 (percentage complete)

    Options:
        --current-step "description"      What worker is doing now
        --next-step "description"         What worker will do next
        --time-remaining "estimate"       Time estimate like "15 minutes"
        --token-usage N                   Tokens consumed so far
        --deliverables "description"      Final deliverables (for completion)
        --failure-reason "reason"         Why task failed (for failures)

CONVENIENCE FUNCTIONS:
    quick_checkin <progress>                     # Simple progress update
    checkin_start                                # Task start check-in
    checkin_complete "deliverables"              # Task completion
    checkin_failed "reason" [progress]           # Task failure
    checkin_blocked "blocker" [progress]         # Worker blocked

EXAMPLES:

    # Minimal check-in
    worker_checkin "in_progress" 25

    # Standard check-in with context
    worker_checkin "in_progress" 50 \
        --current-step "Implementing authentication logic" \
        --next-step "Writing unit tests"

    # Detailed check-in
    worker_checkin "in_progress" 75 \
        --current-step "Running test suite" \
        --next-step "Creating pull request" \
        --time-remaining "10 minutes" \
        --token-usage 3500

    # Completion
    worker_checkin "completed" 100 \
        --deliverables "PR #123 created, tests passing, docs updated"

    # Failure
    worker_checkin "failed" 60 \
        --failure-reason "Test suite failed with 3 errors"

    # Using convenience functions
    checkin_start
    quick_checkin 25
    quick_checkin 50
    checkin_complete "PR #123"

REQUIREMENTS:
    - WORKER_ID environment variable must be set
    - jq must be installed
    - coordination/worker-checkins/ directory must exist

CHECK-IN FREQUENCY:
    - Required: At task start (within 5 minutes)
    - Required: At task completion or failure
    - Recommended: Every 5-10 minutes during execution
    - Optional: At major phase transitions

NOTES:
    - Check-ins are fast (< 100ms)
    - No blocking or network calls
    - Failures are logged but don't crash worker
    - PM daemon processes check-ins asynchronously

EOF
    exit 0
fi
