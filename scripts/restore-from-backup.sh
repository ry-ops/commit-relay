#!/usr/bin/env bash
#
# Restore from Backup Script
# Part of Phase 2: Disaster Recovery
#
# Restores coordination state from a backup archive.
# Supports selective restoration, dry-run mode, and verification.
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BACKUPS_DIR="${BACKUPS_DIR:-$PROJECT_ROOT/coordination/backups}"
readonly RESTORE_LOG="${RESTORE_LOG:-$BACKUPS_DIR/restore.log}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

#
# Log message
#
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$RESTORE_LOG"
}

#
# Print colored message
#
print_color() {
    local color="$1"
    shift
    echo -e "${color}$*${NC}"
}

#
# Show usage
#
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <backup_archive>

Restore coordination state from a backup archive.

OPTIONS:
    -d, --dry-run       Show what would be restored without making changes
    -f, --force         Skip confirmation prompts
    -s, --selective     Restore only specific items (interactive)
    -v, --verify-only   Only verify backup integrity, don't restore
    -o, --output-dir    Restore to alternate directory
    -l, --list          List available backups and exit
    -h, --help          Show this help message

EXAMPLES:
    # Restore from latest hourly backup
    $0 coordination/backups/hourly/backup-2025-11-21-1400.tar.gz

    # Dry-run to see what would be restored
    $0 --dry-run coordination/backups/daily/backup-2025-11-21.tar.gz

    # Restore to alternate directory
    $0 --output-dir /tmp/restore coordination/backups/hourly/backup-2025-11-21-1400.tar.gz

    # List available backups
    $0 --list

EOF
    exit 0
}

#
# List available backups
#
list_backups() {
    echo "=== Available Backups ==="
    echo ""

    echo "Hourly Backups:"
    for archive in $(ls -t "$BACKUPS_DIR/hourly"/backup-*.tar.gz 2>/dev/null | head -20); do
        local name=$(basename "$archive" .tar.gz)
        local size=$(du -h "$archive" | cut -f1)
        local date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$archive" 2>/dev/null || stat -c "%y" "$archive" 2>/dev/null | cut -d. -f1)
        echo "  $archive"
        echo "    Size: $size, Created: $date"
    done

    echo ""
    echo "Daily Backups:"
    for archive in $(ls -t "$BACKUPS_DIR/daily"/backup-*.tar.gz 2>/dev/null | head -10); do
        local name=$(basename "$archive" .tar.gz)
        local size=$(du -h "$archive" | cut -f1)
        local date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$archive" 2>/dev/null || stat -c "%y" "$archive" 2>/dev/null | cut -d. -f1)
        echo "  $archive"
        echo "    Size: $size, Created: $date"
    done

    exit 0
}

#
# Verify backup integrity
#
verify_backup() {
    local archive="$1"

    print_color "$YELLOW" "Verifying backup integrity..."

    if [[ ! -f "$archive" ]]; then
        print_color "$RED" "ERROR: Archive not found: $archive"
        return 1
    fi

    # Test archive integrity
    if tar -tzf "$archive" >/dev/null 2>&1; then
        print_color "$GREEN" "Archive integrity verified"

        # Show contents
        local item_count=$(tar -tzf "$archive" | wc -l | tr -d ' ')
        echo "  Items in archive: $item_count"

        return 0
    else
        print_color "$RED" "ERROR: Archive integrity check FAILED"
        return 1
    fi
}

#
# Get items from archive
#
get_archive_items() {
    local archive="$1"
    tar -tzf "$archive" | grep -v '/$' | sort
}

#
# Create pre-restore backup
#
create_pre_restore_backup() {
    local backup_name="pre-restore-$(date +%Y%m%d-%H%M%S)"
    local backup_dir="$BACKUPS_DIR/pre-restore"
    local backup_path="$backup_dir/$backup_name.tar.gz"

    mkdir -p "$backup_dir"

    print_color "$YELLOW" "Creating pre-restore backup..."

    # Backup current coordination state
    local items_to_backup=""
    for item in coordination/*.json coordination/orchestrator/state/*.json coordination/masters/*/context/*.json; do
        if [[ -f "$PROJECT_ROOT/$item" ]]; then
            items_to_backup="$items_to_backup $item"
        fi
    done

    if [[ -n "$items_to_backup" ]]; then
        cd "$PROJECT_ROOT"
        tar -czf "$backup_path" $items_to_backup 2>/dev/null || true
        cd - >/dev/null

        local size=$(du -h "$backup_path" | cut -f1)
        print_color "$GREEN" "Pre-restore backup created: $backup_path ($size)"
        echo "  To rollback, run: $0 $backup_path"
    else
        print_color "$YELLOW" "No items to backup"
    fi
}

#
# Restore from archive
#
restore_from_archive() {
    local archive="$1"
    local output_dir="$2"
    local dry_run="$3"
    local selective="$4"

    local restore_to="$output_dir"

    if [[ "$dry_run" == "true" ]]; then
        print_color "$YELLOW" "=== DRY RUN MODE ==="
        echo "Would restore to: $restore_to"
        echo ""
        echo "Items to restore:"
        get_archive_items "$archive" | while read -r item; do
            echo "  - $item"
        done
        return 0
    fi

    # Create output directory
    mkdir -p "$restore_to"

    # Get backup name from archive
    local backup_name=$(tar -tzf "$archive" | head -1 | cut -d'/' -f1)

    if [[ "$selective" == "true" ]]; then
        # Interactive selective restore
        print_color "$YELLOW" "Selective restore mode. Select items to restore:"
        echo ""

        local items_to_restore=""
        get_archive_items "$archive" | while read -r item; do
            read -p "  Restore $item? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                items_to_restore="$items_to_restore $item"
            fi
        done

        if [[ -z "$items_to_restore" ]]; then
            print_color "$YELLOW" "No items selected for restore"
            return 0
        fi

        # Extract selected items
        tar -xzf "$archive" -C "$restore_to" $items_to_restore
    else
        # Full restore
        print_color "$YELLOW" "Extracting backup..."

        # Extract to temp and then move to final location
        local temp_dir=$(mktemp -d)
        tar -xzf "$archive" -C "$temp_dir"

        # Move items from backup to restore location
        local restored_count=0
        local failed_count=0

        for item in $(find "$temp_dir/$backup_name" -type f); do
            local relative_path="${item#$temp_dir/$backup_name/}"
            local dest_path="$restore_to/$relative_path"
            local dest_dir=$(dirname "$dest_path")

            mkdir -p "$dest_dir"

            if cp "$item" "$dest_path"; then
                restored_count=$((restored_count + 1))
                log "INFO" "Restored: $relative_path"
            else
                failed_count=$((failed_count + 1))
                log "ERROR" "Failed to restore: $relative_path"
            fi
        done

        # Cleanup
        rm -rf "$temp_dir"

        echo ""
        print_color "$GREEN" "Restore complete!"
        echo "  Items restored: $restored_count"
        echo "  Items failed: $failed_count"
        echo "  Restored to: $restore_to"
    fi
}

#
# Main
#
main() {
    local archive=""
    local dry_run="false"
    local force="false"
    local selective="false"
    local verify_only="false"
    local output_dir="$PROJECT_ROOT"
    local do_list="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                dry_run="true"
                shift
                ;;
            -f|--force)
                force="true"
                shift
                ;;
            -s|--selective)
                selective="true"
                shift
                ;;
            -v|--verify-only)
                verify_only="true"
                shift
                ;;
            -o|--output-dir)
                output_dir="$2"
                shift 2
                ;;
            -l|--list)
                do_list="true"
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                print_color "$RED" "Unknown option: $1"
                usage
                ;;
            *)
                archive="$1"
                shift
                ;;
        esac
    done

    # Handle list command
    if [[ "$do_list" == "true" ]]; then
        list_backups
    fi

    # Validate archive
    if [[ -z "$archive" ]]; then
        print_color "$RED" "ERROR: No backup archive specified"
        echo ""
        usage
    fi

    if [[ ! -f "$archive" ]]; then
        print_color "$RED" "ERROR: Archive not found: $archive"
        exit 1
    fi

    # Create log directory
    mkdir -p "$(dirname "$RESTORE_LOG")"

    log "INFO" "Starting restore from: $archive"
    echo ""
    print_color "$GREEN" "=== Commit-Relay Backup Restore ==="
    echo ""
    echo "Archive: $archive"
    echo "Output: $output_dir"
    echo ""

    # Verify backup integrity
    if ! verify_backup "$archive"; then
        exit 1
    fi

    # Exit if verify-only
    if [[ "$verify_only" == "true" ]]; then
        echo ""
        echo "Contents:"
        get_archive_items "$archive" | while read -r item; do
            echo "  - $item"
        done
        exit 0
    fi

    # Confirm restore
    if [[ "$force" != "true" && "$dry_run" != "true" ]]; then
        echo ""
        print_color "$YELLOW" "WARNING: This will overwrite existing coordination files!"
        read -p "Continue with restore? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_color "$YELLOW" "Restore cancelled"
            exit 0
        fi

        # Create pre-restore backup
        if [[ "$output_dir" == "$PROJECT_ROOT" ]]; then
            create_pre_restore_backup
        fi
    fi

    echo ""

    # Perform restore
    restore_from_archive "$archive" "$output_dir" "$dry_run" "$selective"

    log "INFO" "Restore completed"
}

main "$@"
