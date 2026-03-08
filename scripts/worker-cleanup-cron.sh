#!/bin/bash
################################################################################
# Worker Cleanup Cron Job
#
# Purpose: Automated worker pool maintenance and cleanup
# Schedule: Run every hour via cron (recommended)
#
# Features:
#   - Identifies completed/stale workers (status=completed, >24hr old)
#   - Archives workers to dated directories
#   - Updates worker-pool.json to reflect current state
#   - Reconciles worker status with actual PIDs
#   - Monitors pool size and alerts on anomalies
#   - Maintains worker lifecycle audit trail
#
# Usage:
#   ./scripts/worker-cleanup-cron.sh [--dry-run] [--verbose]
#
# Cron Setup:
#   # Add to crontab (edit with: crontab -e)
#   0 * * * * /path/to/commit-relay/scripts/worker-cleanup-cron.sh >> /path/to/commit-relay/agents/logs/system/worker-cleanup.log 2>&1
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_SPECS_DIR="$PROJECT_ROOT/coordination/worker-specs"
WORKER_POOL_FILE="$PROJECT_ROOT/coordination/worker-pool.json"
LOG_FILE="$PROJECT_ROOT/agents/logs/system/worker-cleanup.log"
EVENTS_FILE="$PROJECT_ROOT/coordination/dashboard-events.jsonl"

# Thresholds
MAX_WORKER_AGE_HOURS=24
POOL_SIZE_WARNING=10
POOL_SIZE_CRITICAL=15

# Options
DRY_RUN=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--verbose]"
            exit 1
            ;;
    esac
done

# Initialize logging
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

emit_event() {
    local event_type="$1"
    local event_data="$2"

    local event_json=$(jq -n \
        --arg timestamp "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --arg type "$event_type" \
        --argjson data "$event_data" \
        '{
            timestamp: $timestamp,
            type: $type,
            data: $data
        }')

    echo "$event_json" >> "$EVENTS_FILE" 2>/dev/null || true
}

################################################################################
# Worker Status Reconciliation
################################################################################

reconcile_worker_status() {
    local worker_file="$1"
    local worker_id=$(basename "$worker_file" .json)

    # Extract PID from worker session if available
    local pid=$(jq -r '.execution.pid // empty' "$worker_file" 2>/dev/null)

    if [ -n "$pid" ]; then
        # Check if process is still running
        if ! kill -0 "$pid" 2>/dev/null; then
            # Process not running, check status
            local status=$(jq -r '.status' "$worker_file" 2>/dev/null)
            if [ "$status" = "running" ]; then
                log_warn "Worker $worker_id (PID: $pid) marked as running but process not found"
                return 1  # Stale worker
            fi
        fi
    fi

    return 0  # Worker status OK
}

################################################################################
# Worker Age Calculation
################################################################################

calculate_worker_age_hours() {
    local worker_file="$1"

    # Try multiple timestamp fields
    local created_at=$(jq -r '.created_at // .execution.started_at // empty' "$worker_file" 2>/dev/null)

    if [ -z "$created_at" ]; then
        # Fallback to file modification time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            local file_age_seconds=$(( $(date +%s) - $(stat -f %m "$worker_file") ))
        else
            # Linux
            local file_age_seconds=$(( $(date +%s) - $(stat -c %Y "$worker_file") ))
        fi
        echo $(( file_age_seconds / 3600 ))
        return
    fi

    # Parse timestamp and calculate age
    local created_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$created_at" +%s 2>/dev/null || echo "0")
    local current_timestamp=$(date +%s)
    local age_seconds=$(( current_timestamp - created_timestamp ))
    local age_hours=$(( age_seconds / 3600 ))

    echo "$age_hours"
}

################################################################################
# Cleanup Logic
################################################################################

cleanup_completed_workers() {
    log_info "Starting worker cleanup process..."

    local completed_count=0
    local stale_count=0
    local archived_count=0

    # Create archive directory with date
    local archive_date=$(date +"%Y-%m-%d")
    local archive_dir="$WORKER_SPECS_DIR/archived/$archive_date"

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$archive_dir"
    fi

    # Process active workers
    for worker_file in "$WORKER_SPECS_DIR/active"/*.json; do
        [ -f "$worker_file" ] || continue

        local worker_id=$(basename "$worker_file" .json)
        local status=$(jq -r '.status // "unknown"' "$worker_file" 2>/dev/null)
        local age_hours=$(calculate_worker_age_hours "$worker_file")

        [ "$VERBOSE" = true ] && log_info "Checking $worker_id: status=$status, age=${age_hours}h"

        # Identify cleanup candidates
        local should_archive=false
        local reason=""

        if [ "$status" = "completed" ]; then
            should_archive=true
            reason="completed"
            ((completed_count++))
        elif [ "$status" = "failed" ]; then
            should_archive=true
            reason="failed"
        elif [ "$age_hours" -gt "$MAX_WORKER_AGE_HOURS" ]; then
            # Check if process is still running
            if ! reconcile_worker_status "$worker_file"; then
                should_archive=true
                reason="stale (${age_hours}h old, process not running)"
                ((stale_count++))
            fi
        fi

        # Archive worker if needed
        if [ "$should_archive" = true ]; then
            log_info "Archiving $worker_id: $reason"

            if [ "$DRY_RUN" = false ]; then
                # Move to archive
                mv "$worker_file" "$archive_dir/"
                ((archived_count++))

                # Emit event
                local event_data=$(jq -n \
                    --arg worker_id "$worker_id" \
                    --arg status "$status" \
                    --arg reason "$reason" \
                    --arg age_hours "$age_hours" \
                    '{
                        worker_id: $worker_id,
                        status: $status,
                        reason: $reason,
                        age_hours: ($age_hours | tonumber)
                    }')
                emit_event "worker_archived" "$event_data"
            else
                log_info "[DRY RUN] Would archive $worker_id"
            fi
        fi
    done

    log_success "Cleanup complete: $archived_count workers archived ($completed_count completed, $stale_count stale)"

    # Update worker-pool.json
    if [ "$DRY_RUN" = false ] && [ $archived_count -gt 0 ]; then
        update_worker_pool
    fi
}

################################################################################
# Worker Pool Update
################################################################################

update_worker_pool() {
    log_info "Updating worker-pool.json..."

    if [ ! -f "$WORKER_POOL_FILE" ]; then
        log_warn "worker-pool.json not found, skipping update"
        return
    fi

    # Get current active worker IDs
    local active_worker_ids=()
    for worker_file in "$WORKER_SPECS_DIR/active"/*.json; do
        [ -f "$worker_file" ] || continue
        local worker_id=$(jq -r '.worker_id // empty' "$worker_file" 2>/dev/null)
        [ -n "$worker_id" ] && active_worker_ids+=("$worker_id")
    done

    # Filter worker-pool.json to only include active workers
    local active_workers_json=$(printf '%s\n' "${active_worker_ids[@]}" | jq -R . | jq -s .)

    jq --argjson active_ids "$active_workers_json" \
       --arg updated_at "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       '.active_workers = [.active_workers[] | select(.worker_id as $id | $active_ids | index($id))] | .updated_at = $updated_at' \
       "$WORKER_POOL_FILE" > /tmp/worker-pool-updated-$$.json

    mv /tmp/worker-pool-updated-$$.json "$WORKER_POOL_FILE"

    log_success "worker-pool.json updated with ${#active_worker_ids[@]} active workers"
}

################################################################################
# Pool Size Monitoring
################################################################################

check_pool_size() {
    log_info "Checking pool size..."

    local active_count=$(find "$WORKER_SPECS_DIR/active" -name "*.json" | wc -l | tr -d ' ')

    log_info "Current pool size: $active_count workers"

    if [ "$active_count" -ge "$POOL_SIZE_CRITICAL" ]; then
        log_error "CRITICAL: Pool size ($active_count) exceeds critical threshold ($POOL_SIZE_CRITICAL)"

        # Emit alert event
        local event_data=$(jq -n \
            --arg count "$active_count" \
            --arg threshold "$POOL_SIZE_CRITICAL" \
            '{
                pool_size: ($count | tonumber),
                threshold: ($threshold | tonumber),
                severity: "critical"
            }')
        emit_event "pool_size_alert" "$event_data"

    elif [ "$active_count" -ge "$POOL_SIZE_WARNING" ]; then
        log_warn "WARNING: Pool size ($active_count) exceeds warning threshold ($POOL_SIZE_WARNING)"

        # Emit warning event
        local event_data=$(jq -n \
            --arg count "$active_count" \
            --arg threshold "$POOL_SIZE_WARNING" \
            '{
                pool_size: ($count | tonumber),
                threshold: ($threshold | tonumber),
                severity: "warning"
            }')
        emit_event "pool_size_alert" "$event_data"
    else
        log_success "Pool size is healthy ($active_count workers)"
    fi
}

################################################################################
# Worker Pool Health Report
################################################################################

generate_health_report() {
    log_info "Generating worker pool health report..."

    local active_count=$(find "$WORKER_SPECS_DIR/active" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local completed_count=$(find "$WORKER_SPECS_DIR/completed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local failed_count=$(find "$WORKER_SPECS_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local archived_count=$(find "$WORKER_SPECS_DIR/archived" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    log_info "Worker Pool Health Report:"
    log_info "  Active:    $active_count"
    log_info "  Completed: $completed_count"
    log_info "  Failed:    $failed_count"
    log_info "  Archived:  $archived_count"
    log_info "  Total:     $((active_count + completed_count + failed_count + archived_count))"
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "=========================================="
    log_info "Worker Cleanup Cron Job Started"
    log_info "=========================================="

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Run cleanup operations
    cleanup_completed_workers
    check_pool_size
    generate_health_report

    log_info "=========================================="
    log_info "Worker Cleanup Cron Job Completed"
    log_info "=========================================="
}

# Execute main
main
