#!/bin/bash
# scripts/system-maintenance.sh
# System Maintenance Script for commit-relay
# Performs automated cleanup, archival, and optimization tasks

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries if available
if [[ -f "$SCRIPT_DIR/lib/logging.sh" ]]; then
    source "$SCRIPT_DIR/lib/logging.sh"
else
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
fi

# Color definitions
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"  # No Color

# Configuration
ARCHIVE_DIR="$COMMIT_RELAY_HOME/coordination/archives"
LOG_RETENTION_DAYS=30
HISTORY_RETENTION_DAYS=7
DRY_RUN=false

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

System maintenance script for commit-relay. Performs cleanup, archival, and optimization.

OPTIONS:
    --dry-run           Show what would be done without making changes
    --logs-only         Only clean up log files
    --workers-only      Only clean up worker specs
    --history-only      Only clean up history files
    --all               Run all maintenance tasks (default)
    -h, --help          Show this help message

MAINTENANCE TASKS:
    1. Archive old logs (older than ${LOG_RETENTION_DAYS} days)
    2. Clean up failed worker specs
    3. Compress historical coordination data
    4. Archive dashboard events
    5. Remove temporary test artifacts
    6. Optimize coordination file sizes

EXAMPLES:
    # Run all maintenance tasks (dry run)
    $0 --dry-run

    # Run all maintenance tasks
    $0 --all

    # Only clean logs
    $0 --logs-only

EOF
    exit 1
}

# Parse arguments
TASK_FILTER="all"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --logs-only)
            TASK_FILTER="logs"
            shift
            ;;
        --workers-only)
            TASK_FILTER="workers"
            shift
            ;;
        --history-only)
            TASK_FILTER="history"
            shift
            ;;
        --all)
            TASK_FILTER="all"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Display banner
echo -e "${BLUE}"
cat <<'EOF'
╔═══════════════════════════════════════════════════════════╗
║         commit-relay System Maintenance Script            ║
║                                                           ║
║  Automated cleanup, archival, and optimization            ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY RUN MODE] No changes will be made${NC}\n"
fi

# Create archive directory
mkdir -p "$ARCHIVE_DIR"

# Task 1: Archive old logs
archive_logs() {
    echo -e "${BLUE}═══ Task 1: Archiving Old Logs ═══${NC}"

    local logs_dir="$COMMIT_RELAY_HOME/agents/logs"
    if [[ ! -d "$logs_dir" ]]; then
        log_warn "Logs directory not found: $logs_dir"
        return 0
    fi

    local archive_date=$(date +%Y-%m-%d)
    local log_archive="$ARCHIVE_DIR/logs-archive-$archive_date.tar.gz"

    # Find logs older than retention period
    local old_logs=$(find "$logs_dir" -type f -mtime +${LOG_RETENTION_DAYS} 2>/dev/null || true)

    if [[ -z "$old_logs" ]]; then
        log_info "No logs older than ${LOG_RETENTION_DAYS} days found"
        return 0
    fi

    local log_count=$(echo "$old_logs" | wc -l | tr -d ' ')
    log_info "Found $log_count log files older than ${LOG_RETENTION_DAYS} days"

    if [[ "$DRY_RUN" == "false" ]]; then
        # Create archive
        echo "$old_logs" | tar -czf "$log_archive" -T - 2>/dev/null || true

        if [[ -f "$log_archive" ]]; then
            log_info "Created archive: $log_archive"

            # Remove archived logs
            echo "$old_logs" | xargs rm -f
            log_info "Removed $log_count old log files"
        else
            log_error "Failed to create log archive"
        fi
    else
        log_info "[DRY RUN] Would archive $log_count files to $log_archive"
    fi

    echo ""
}

# Task 2: Clean up failed worker specs
cleanup_failed_workers() {
    echo -e "${BLUE}═══ Task 2: Cleaning Failed Worker Specs ═══${NC}"

    local failed_dir="$COMMIT_RELAY_HOME/coordination/worker-specs/failed"
    if [[ ! -d "$failed_dir" ]]; then
        log_warn "Failed worker specs directory not found: $failed_dir"
        return 0
    fi

    local archive_date=$(date +%Y-%m-%d)
    local worker_archive="$ARCHIVE_DIR/failed-workers-$archive_date.tar.gz"

    # Count failed worker specs
    local failed_count=$(find "$failed_dir" -type f -name "*.json" | wc -l | tr -d ' ')

    if [[ "$failed_count" -eq 0 ]]; then
        log_info "No failed worker specs found"
        return 0
    fi

    log_info "Found $failed_count failed worker specs"

    if [[ "$DRY_RUN" == "false" ]]; then
        # Create archive
        tar -czf "$worker_archive" -C "$failed_dir" . 2>/dev/null || true

        if [[ -f "$worker_archive" ]]; then
            log_info "Created archive: $worker_archive"

            # Remove failed worker specs
            rm -f "$failed_dir"/*.json
            log_info "Removed $failed_count failed worker specs"
        else
            log_error "Failed to create worker specs archive"
        fi
    else
        log_info "[DRY RUN] Would archive $failed_count worker specs to $worker_archive"
    fi

    echo ""
}

# Task 3: Compress historical coordination data
compress_history() {
    echo -e "${BLUE}═══ Task 3: Compressing Historical Data ═══${NC}"

    local history_dir="$COMMIT_RELAY_HOME/coordination/history"
    if [[ ! -d "$history_dir" ]]; then
        log_warn "History directory not found: $history_dir"
        return 0
    fi

    # Find history files older than retention period
    local old_history=$(find "$history_dir" -type f -mtime +${HISTORY_RETENTION_DAYS} 2>/dev/null || true)

    if [[ -z "$old_history" ]]; then
        log_info "No history files older than ${HISTORY_RETENTION_DAYS} days found"
        return 0
    fi

    local history_count=$(echo "$old_history" | wc -l | tr -d ' ')
    log_info "Found $history_count history files older than ${HISTORY_RETENTION_DAYS} days"

    local archive_date=$(date +%Y-%m-%d)
    local history_archive="$ARCHIVE_DIR/history-$archive_date.tar.gz"

    if [[ "$DRY_RUN" == "false" ]]; then
        # Create compressed archive
        echo "$old_history" | tar -czf "$history_archive" -T - 2>/dev/null || true

        if [[ -f "$history_archive" ]]; then
            log_info "Created compressed archive: $history_archive"

            # Remove archived files
            echo "$old_history" | xargs rm -f
            log_info "Removed $history_count old history files"

            # Calculate space saved
            local archive_size=$(du -h "$history_archive" | cut -f1)
            log_info "Archive size: $archive_size"
        else
            log_error "Failed to create history archive"
        fi
    else
        log_info "[DRY RUN] Would archive $history_count files to $history_archive"
    fi

    echo ""
}

# Task 4: Archive dashboard events
archive_dashboard_events() {
    echo -e "${BLUE}═══ Task 4: Archiving Dashboard Events ═══${NC}"

    local events_file="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        log_warn "Dashboard events file not found: $events_file"
        return 0
    fi

    local line_count=$(wc -l < "$events_file" | tr -d ' ')
    log_info "Dashboard events file has $line_count lines"

    # Archive if more than 1000 lines
    if [[ "$line_count" -gt 1000 ]]; then
        local archive_date=$(date +%Y-%m-%d)
        local events_archive="$ARCHIVE_DIR/dashboard-events-$archive_date.jsonl.gz"

        if [[ "$DRY_RUN" == "false" ]]; then
            # Keep last 100 lines, archive the rest
            local keep_lines=100
            local archive_lines=$((line_count - keep_lines))

            # Archive old events
            head -n "$archive_lines" "$events_file" | gzip > "$events_archive"
            log_info "Archived $archive_lines events to $events_archive"

            # Keep recent events
            tail -n "$keep_lines" "$events_file" > "$events_file.tmp"
            mv "$events_file.tmp" "$events_file"
            log_info "Kept most recent $keep_lines events in active file"
        else
            log_info "[DRY RUN] Would archive $((line_count - 100)) events"
        fi
    else
        log_info "Dashboard events file is within limits (< 1000 lines)"
    fi

    echo ""
}

# Task 5: Remove test artifacts
cleanup_test_artifacts() {
    echo -e "${BLUE}═══ Task 5: Removing Test Artifacts ═══${NC}"

    local test_patterns=(
        "*/test-*.tmp"
        "*/stress-test-*.tmp"
        "*/.DS_Store"
        "*/._*"
        "*.backup"
    )

    local removed_count=0

    for pattern in "${test_patterns[@]}"; do
        local files=$(find "$COMMIT_RELAY_HOME" -name "$(basename "$pattern")" -type f 2>/dev/null || true)

        if [[ -n "$files" ]]; then
            local count=$(echo "$files" | wc -l | tr -d ' ')

            if [[ "$DRY_RUN" == "false" ]]; then
                echo "$files" | xargs rm -f 2>/dev/null || true
                log_info "Removed $count files matching pattern: $pattern"
            else
                log_info "[DRY RUN] Would remove $count files matching: $pattern"
            fi

            removed_count=$((removed_count + count))
        fi
    done

    if [[ "$removed_count" -eq 0 ]]; then
        log_info "No test artifacts found"
    else
        log_info "Total artifacts processed: $removed_count"
    fi

    echo ""
}

# Task 6: Optimize coordination files
optimize_coordination_files() {
    echo -e "${BLUE}═══ Task 6: Optimizing Coordination Files ═══${NC}"

    # Clean up processed handoffs older than 7 days
    local handoff_dir="$COMMIT_RELAY_HOME/coordination/masters/coordinator/handoffs"
    if [[ -d "$handoff_dir" ]]; then
        local old_handoffs=$(find "$handoff_dir" -name "*.processed" -mtime +7 2>/dev/null || true)

        if [[ -n "$old_handoffs" ]]; then
            local handoff_count=$(echo "$old_handoffs" | wc -l | tr -d ' ')

            if [[ "$DRY_RUN" == "false" ]]; then
                echo "$old_handoffs" | xargs rm -f
                log_info "Removed $handoff_count processed handoff files older than 7 days"
            else
                log_info "[DRY RUN] Would remove $handoff_count processed handoffs"
            fi
        else
            log_info "No old processed handoffs found"
        fi
    fi

    echo ""
}

# Execute maintenance tasks based on filter
run_maintenance() {
    local start_time=$(date +%s)

    log_info "Starting system maintenance (filter: $TASK_FILTER)"
    echo ""

    if [[ "$TASK_FILTER" == "all" || "$TASK_FILTER" == "logs" ]]; then
        archive_logs
    fi

    if [[ "$TASK_FILTER" == "all" || "$TASK_FILTER" == "workers" ]]; then
        cleanup_failed_workers
    fi

    if [[ "$TASK_FILTER" == "all" || "$TASK_FILTER" == "history" ]]; then
        compress_history
        archive_dashboard_events
    fi

    if [[ "$TASK_FILTER" == "all" ]]; then
        cleanup_test_artifacts
        optimize_coordination_files
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}System maintenance completed in ${duration}s${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"

    # Show archive directory contents
    if [[ -d "$ARCHIVE_DIR" ]]; then
        echo ""
        log_info "Archive directory contents:"
        ls -lh "$ARCHIVE_DIR" | tail -n +2 || true
    fi
}

# Main execution
run_maintenance

exit 0
