#!/usr/bin/env bash
#
# Backup Daemon
# Part of Phase 2: Disaster Recovery
#
# Manages automated backups of coordination state:
# - Hourly snapshots with 7-day retention
# - Daily snapshots with 30-day retention
# - Integrity verification
# - Backup health reporting
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
readonly DAEMON_NAME="backup-daemon"
readonly PID_FILE="${PID_FILE:-/tmp/commit-relay-backup-daemon.pid}"
readonly LOG_FILE="${LOG_FILE:-$PROJECT_ROOT/coordination/observability/backups/backup-daemon.log}"
readonly BACKUPS_DIR="${BACKUPS_DIR:-$PROJECT_ROOT/coordination/backups}"
readonly HOURLY_DIR="$BACKUPS_DIR/hourly"
readonly DAILY_DIR="$BACKUPS_DIR/daily"
readonly HEALTH_FILE="$BACKUPS_DIR/backup-health.json"

# Backup intervals
readonly HOURLY_INTERVAL=3600      # 1 hour
readonly DAILY_INTERVAL=86400      # 24 hours
readonly CLEANUP_INTERVAL=21600    # 6 hours

# Retention policies
readonly HOURLY_RETENTION_DAYS=7
readonly DAILY_RETENTION_DAYS=30

# Items to backup
readonly BACKUP_ITEMS=(
    "coordination/worker-pool.json"
    "coordination/token-budget.json"
    "coordination/task-queue.json"
    "coordination/handoffs.json"
    "coordination/status.json"
    "coordination/orchestrator/state/current.json"
    "coordination/pm-state.json"
    "coordination/routing-health.json"
    "coordination/health-alerts.json"
    "coordination/knowledge-base/learned-patterns/patterns-latest.json"
    "coordination/masters/coordinator/context/master-state.json"
    "coordination/masters/development/context/master-state.json"
    "coordination/masters/security/context/master-state.json"
    "coordination/masters/inventory/context/master-state.json"
    "coordination/observability/alert-rules.json"
)

#
# Log message
#
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

#
# Check if daemon is already running
#
check_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    return 1
}

#
# Initialize daemon
#
initialize() {
    log "INFO" "Initializing backup daemon..."

    # Create directories
    mkdir -p "$HOURLY_DIR" "$DAILY_DIR" "$(dirname "$LOG_FILE")"

    # Check if already running
    if check_running; then
        log "ERROR" "Daemon already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    # Write PID file
    echo $$ > "$PID_FILE"

    # Initialize health file
    update_health "initializing" "Daemon starting up"

    log "INFO" "Initialization complete"
}

#
# Get current timestamp in ISO format
#
get_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

#
# Get date for backup naming
#
get_backup_date() {
    date +%Y-%m-%d
}

#
# Get hour for backup naming
#
get_backup_hour() {
    date +%Y-%m-%d-%H00
}

#
# Create a backup snapshot
#
create_backup() {
    local backup_type="$1"  # hourly or daily
    local backup_dir=""
    local backup_name=""

    case "$backup_type" in
        hourly)
            backup_dir="$HOURLY_DIR"
            backup_name="backup-$(get_backup_hour)"
            ;;
        daily)
            backup_dir="$DAILY_DIR"
            backup_name="backup-$(get_backup_date)"
            ;;
        *)
            log "ERROR" "Unknown backup type: $backup_type"
            return 1
            ;;
    esac

    local backup_path="$backup_dir/$backup_name"
    local archive_path="${backup_path}.tar.gz"
    local manifest_path="${backup_path}-manifest.json"

    # Skip if backup already exists (for hourly, allow overwrite)
    if [[ "$backup_type" == "daily" && -f "$archive_path" ]]; then
        log "INFO" "Daily backup already exists for today, skipping"
        return 0
    fi

    log "INFO" "Creating $backup_type backup: $backup_name"

    # Create temporary backup directory
    local temp_dir=$(mktemp -d)
    local backup_temp="$temp_dir/$backup_name"
    mkdir -p "$backup_temp"

    # Copy items to backup
    local items_backed_up=0
    local items_failed=0
    local total_size=0
    local manifest_items="[]"

    for item in "${BACKUP_ITEMS[@]}"; do
        local source_path="$PROJECT_ROOT/$item"

        if [[ -f "$source_path" ]]; then
            local dest_dir="$backup_temp/$(dirname "$item")"
            mkdir -p "$dest_dir"

            if cp "$source_path" "$dest_dir/"; then
                items_backed_up=$((items_backed_up + 1))
                local file_size=$(stat -f%z "$source_path" 2>/dev/null || stat -c%s "$source_path" 2>/dev/null || echo "0")
                total_size=$((total_size + file_size))

                # Add to manifest
                local checksum=$(md5sum "$source_path" 2>/dev/null | cut -d' ' -f1 || md5 -q "$source_path" 2>/dev/null || echo "unknown")
                manifest_items=$(echo "$manifest_items" | jq \
                    --arg path "$item" \
                    --arg size "$file_size" \
                    --arg checksum "$checksum" \
                    '. += [{path: $path, size: ($size | tonumber), checksum: $checksum}]')
            else
                items_failed=$((items_failed + 1))
                log "WARN" "Failed to backup: $item"
            fi
        else
            log "DEBUG" "File not found, skipping: $item"
        fi
    done

    # Also backup active worker specs
    local worker_specs_dir="$PROJECT_ROOT/coordination/worker-specs/active"
    if [[ -d "$worker_specs_dir" ]]; then
        local specs_dest="$backup_temp/coordination/worker-specs/active"
        mkdir -p "$specs_dest"
        cp "$worker_specs_dir"/*.json "$specs_dest/" 2>/dev/null || true
        local specs_count=$(ls "$specs_dest"/*.json 2>/dev/null | wc -l | tr -d ' ')
        items_backed_up=$((items_backed_up + specs_count))
    fi

    # Create archive
    if tar -czf "$archive_path" -C "$temp_dir" "$backup_name" 2>/dev/null; then
        local archive_size=$(stat -f%z "$archive_path" 2>/dev/null || stat -c%s "$archive_path" 2>/dev/null || echo "0")

        # Create manifest
        jq -n \
            --arg name "$backup_name" \
            --arg type "$backup_type" \
            --arg timestamp "$(get_timestamp)" \
            --arg items_backed_up "$items_backed_up" \
            --arg items_failed "$items_failed" \
            --arg total_size "$total_size" \
            --arg archive_size "$archive_size" \
            --argjson items "$manifest_items" \
            '{
                backup_name: $name,
                backup_type: $type,
                created_at: $timestamp,
                items_backed_up: ($items_backed_up | tonumber),
                items_failed: ($items_failed | tonumber),
                total_size_bytes: ($total_size | tonumber),
                archive_size_bytes: ($archive_size | tonumber),
                compression_ratio: (if ($total_size | tonumber) > 0 then (($archive_size | tonumber) / ($total_size | tonumber)) else 0 end),
                items: $items,
                integrity_verified: false
            }' > "$manifest_path"

        log "INFO" "Backup created: $archive_path ($items_backed_up items, $(numfmt --to=iec-i --suffix=B $archive_size 2>/dev/null || echo "$archive_size bytes"))"

        # Cleanup temp
        rm -rf "$temp_dir"

        return 0
    else
        log "ERROR" "Failed to create archive: $archive_path"
        rm -rf "$temp_dir"
        return 1
    fi
}

#
# Verify backup integrity
#
verify_backup() {
    local archive_path="$1"

    if [[ ! -f "$archive_path" ]]; then
        return 1
    fi

    # Test archive integrity
    if tar -tzf "$archive_path" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

#
# Cleanup old backups
#
cleanup_backups() {
    log "INFO" "Cleaning up old backups..."

    local hourly_deleted=0
    local daily_deleted=0

    # Cleanup hourly backups older than retention
    find "$HOURLY_DIR" -name "backup-*.tar.gz" -mtime +$HOURLY_RETENTION_DAYS -delete 2>/dev/null && \
        hourly_deleted=$(find "$HOURLY_DIR" -name "backup-*.tar.gz" -mtime +$HOURLY_RETENTION_DAYS 2>/dev/null | wc -l | tr -d ' ')
    find "$HOURLY_DIR" -name "backup-*-manifest.json" -mtime +$HOURLY_RETENTION_DAYS -delete 2>/dev/null

    # Cleanup daily backups older than retention
    find "$DAILY_DIR" -name "backup-*.tar.gz" -mtime +$DAILY_RETENTION_DAYS -delete 2>/dev/null && \
        daily_deleted=$(find "$DAILY_DIR" -name "backup-*.tar.gz" -mtime +$DAILY_RETENTION_DAYS 2>/dev/null | wc -l | tr -d ' ')
    find "$DAILY_DIR" -name "backup-*-manifest.json" -mtime +$DAILY_RETENTION_DAYS -delete 2>/dev/null

    log "INFO" "Cleanup complete: hourly=$hourly_deleted, daily=$daily_deleted deleted"
}

#
# Update backup health status
#
update_health() {
    local status="$1"
    local message="${2:-}"

    local hourly_count=$(find "$HOURLY_DIR" -name "backup-*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    local daily_count=$(find "$DAILY_DIR" -name "backup-*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')

    # Get latest backup timestamps
    local latest_hourly=$(ls -t "$HOURLY_DIR"/backup-*.tar.gz 2>/dev/null | head -1 | xargs -I {} stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" {} 2>/dev/null || echo "none")
    local latest_daily=$(ls -t "$DAILY_DIR"/backup-*.tar.gz 2>/dev/null | head -1 | xargs -I {} stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" {} 2>/dev/null || echo "none")

    # Calculate total size
    local total_hourly_size=$(du -sh "$HOURLY_DIR" 2>/dev/null | cut -f1 || echo "0")
    local total_daily_size=$(du -sh "$DAILY_DIR" 2>/dev/null | cut -f1 || echo "0")

    jq -n \
        --arg status "$status" \
        --arg message "$message" \
        --arg timestamp "$(get_timestamp)" \
        --arg hourly_count "$hourly_count" \
        --arg daily_count "$daily_count" \
        --arg latest_hourly "$latest_hourly" \
        --arg latest_daily "$latest_daily" \
        --arg hourly_size "$total_hourly_size" \
        --arg daily_size "$total_daily_size" \
        --arg hourly_retention "$HOURLY_RETENTION_DAYS" \
        --arg daily_retention "$DAILY_RETENTION_DAYS" \
        '{
            status: $status,
            message: $message,
            last_check: $timestamp,
            backups: {
                hourly: {
                    count: ($hourly_count | tonumber),
                    latest: $latest_hourly,
                    total_size: $hourly_size,
                    retention_days: ($hourly_retention | tonumber)
                },
                daily: {
                    count: ($daily_count | tonumber),
                    latest: $latest_daily,
                    total_size: $daily_size,
                    retention_days: ($daily_retention | tonumber)
                }
            }
        }' > "$HEALTH_FILE"
}

#
# Print statistics
#
print_stats() {
    log "INFO" "=== Backup Statistics ==="

    local hourly_count=$(find "$HOURLY_DIR" -name "backup-*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    local daily_count=$(find "$DAILY_DIR" -name "backup-*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')

    log "INFO" "Hourly backups: $hourly_count (retention: ${HOURLY_RETENTION_DAYS}d)"
    log "INFO" "Daily backups: $daily_count (retention: ${DAILY_RETENTION_DAYS}d)"

    local total_hourly_size=$(du -sh "$HOURLY_DIR" 2>/dev/null | cut -f1 || echo "0")
    local total_daily_size=$(du -sh "$DAILY_DIR" 2>/dev/null | cut -f1 || echo "0")

    log "INFO" "Hourly size: $total_hourly_size"
    log "INFO" "Daily size: $total_daily_size"
    log "INFO" "========================="
}

#
# List backups
#
list_backups() {
    local backup_type="${1:-all}"

    echo "=== Available Backups ==="

    if [[ "$backup_type" == "all" || "$backup_type" == "hourly" ]]; then
        echo ""
        echo "Hourly Backups:"
        for archive in $(ls -t "$HOURLY_DIR"/backup-*.tar.gz 2>/dev/null); do
            local name=$(basename "$archive" .tar.gz)
            local size=$(du -h "$archive" | cut -f1)
            local date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$archive" 2>/dev/null || stat -c "%y" "$archive" 2>/dev/null | cut -d. -f1)
            echo "  $name ($size) - $date"
        done
    fi

    if [[ "$backup_type" == "all" || "$backup_type" == "daily" ]]; then
        echo ""
        echo "Daily Backups:"
        for archive in $(ls -t "$DAILY_DIR"/backup-*.tar.gz 2>/dev/null); do
            local name=$(basename "$archive" .tar.gz)
            local size=$(du -h "$archive" | cut -f1)
            local date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$archive" 2>/dev/null || stat -c "%y" "$archive" 2>/dev/null | cut -d. -f1)
            echo "  $name ($size) - $date"
        done
    fi
}

#
# Cleanup on exit
#
cleanup() {
    log "INFO" "Shutting down backup daemon..."
    rm -f "$PID_FILE"
    update_health "stopped" "Daemon shutdown"
    print_stats
    log "INFO" "Daemon stopped"
}

#
# Main daemon loop
#
main() {
    trap cleanup EXIT INT TERM

    initialize

    local last_hourly_backup=$(date +%s)
    local last_daily_backup=$(date +%s)
    local last_cleanup=$(date +%s)

    # Create initial backup
    create_backup "hourly"

    # Check if we need a daily backup
    local today=$(get_backup_date)
    if [[ ! -f "$DAILY_DIR/backup-${today}.tar.gz" ]]; then
        create_backup "daily"
    fi

    update_health "healthy" "Daemon running normally"
    log "INFO" "Starting backup loop..."

    while true; do
        local now=$(date +%s)

        # Hourly backup
        if [[ $((now - last_hourly_backup)) -ge $HOURLY_INTERVAL ]]; then
            create_backup "hourly"
            last_hourly_backup=$now
        fi

        # Daily backup (check at midnight or if missing)
        local current_date=$(get_backup_date)
        if [[ ! -f "$DAILY_DIR/backup-${current_date}.tar.gz" ]]; then
            local hour=$(date +%H)
            # Create daily backup early morning or if forced
            if [[ "$hour" == "00" || "$hour" == "01" ]]; then
                create_backup "daily"
                last_daily_backup=$now
            fi
        fi

        # Cleanup old backups
        if [[ $((now - last_cleanup)) -ge $CLEANUP_INTERVAL ]]; then
            cleanup_backups
            last_cleanup=$now
        fi

        # Update health status
        update_health "healthy" "Last check: $(date '+%H:%M:%S')"

        # Sleep for 5 minutes
        sleep 300
    done
}

#
# CLI commands
#
case "${1:-start}" in
    start)
        main
        ;;
    stop)
        if [[ -f "$PID_FILE" ]]; then
            pid=$(cat "$PID_FILE")
            log "INFO" "Stopping daemon (PID: $pid)"
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
        else
            log "INFO" "Daemon not running"
        fi
        ;;
    status)
        if check_running; then
            log "INFO" "Daemon is running (PID: $(cat "$PID_FILE"))"
            print_stats
        else
            log "INFO" "Daemon is not running"
        fi
        ;;
    backup)
        backup_type="${2:-hourly}"
        create_backup "$backup_type"
        ;;
    list)
        backup_type="${2:-all}"
        list_backups "$backup_type"
        ;;
    verify)
        archive="${2:-}"
        if [[ -z "$archive" ]]; then
            echo "Usage: $0 verify <archive_path>"
            exit 1
        fi
        if verify_backup "$archive"; then
            echo "Backup integrity verified: $archive"
        else
            echo "Backup integrity check FAILED: $archive"
            exit 1
        fi
        ;;
    cleanup)
        cleanup_backups
        ;;
    stats)
        print_stats
        ;;
    *)
        echo "Usage: $0 {start|stop|status|backup|list|verify|cleanup|stats}"
        echo ""
        echo "Commands:"
        echo "  start              Start the daemon"
        echo "  stop               Stop the daemon"
        echo "  status             Check daemon status"
        echo "  backup [type]      Create backup (hourly/daily)"
        echo "  list [type]        List backups (all/hourly/daily)"
        echo "  verify <archive>   Verify backup integrity"
        echo "  cleanup            Clean up old backups"
        echo "  stats              Show backup statistics"
        exit 1
        ;;
esac
