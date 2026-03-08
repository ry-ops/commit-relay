#!/bin/bash

# Zombie Worker Cleanup Script
# Detects and cleans up workers that failed to launch or are stuck

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
ZOMBIE_AGE_MINUTES=${1:-30}  # Workers older than this with no progress are zombies
DRY_RUN=${DRY_RUN:-false}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date -u +%Y-%m-%dT%H:%M:%SZ)]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR:${NC} $1"
}

# Calculate worker age in minutes
calculate_age_minutes() {
    local created_at="$1"

    # Convert to epoch seconds
    if [[ "$OSTYPE" == "darwin"* ]]; then
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$created_at" "+%s" 2>/dev/null || echo "0")
    else
        created_epoch=$(date -d "$created_at" "+%s" 2>/dev/null || echo "0")
    fi

    current_epoch=$(date "+%s")
    age_seconds=$((current_epoch - created_epoch))
    age_minutes=$((age_seconds / 60))

    echo "$age_minutes"
}

# Detect zombie workers
detect_zombies() {
    local zombies=()

    log "Scanning for zombie workers (age > $ZOMBIE_AGE_MINUTES minutes)..."

    for worker_spec in "$PROJECT_ROOT/coordination/worker-specs/active"/*.json; do
        if [ ! -f "$worker_spec" ]; then
            continue
        fi

        worker_id=$(basename "$worker_spec" .json)
        worker_status=$(jq -r '.status' "$worker_spec" 2>/dev/null)
        created_at=$(jq -r '.created_at' "$worker_spec" 2>/dev/null)
        task_id=$(jq -r '.task_id' "$worker_spec" 2>/dev/null)

        # Calculate age
        age_minutes=$(calculate_age_minutes "$created_at")

        # Check if worker is zombie
        worker_dir="$PROJECT_ROOT/agents/workers/$worker_id"
        is_zombie=false
        zombie_reason=""

        # Reason 1: No worker directory created
        if [ ! -d "$worker_dir" ]; then
            is_zombie=true
            zombie_reason="No worker directory"
        # Reason 2: No logs directory (old broken launcher)
        elif [ ! -d "$worker_dir/logs" ] && [ "$age_minutes" -gt "$ZOMBIE_AGE_MINUTES" ]; then
            is_zombie=true
            zombie_reason="No logs directory (old launcher)"
        # Reason 3: Status still 'pending' or 'running' with no progress
        elif [ "$worker_status" = "pending" ] || [ "$worker_status" = "running" ]; then
            file_count=$(find "$worker_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$file_count" -le 3 ] && [ "$age_minutes" -gt "$ZOMBIE_AGE_MINUTES" ]; then
                is_zombie=true
                zombie_reason="No progress ($file_count files, $age_minutes min old)"
            fi
        fi

        if [ "$is_zombie" = true ]; then
            warn "ZOMBIE: $worker_id - $zombie_reason"
            zombies+=("$worker_id:$task_id:$zombie_reason")
        fi
    done

    echo "${zombies[@]}"
}

# Clean up a zombie worker
cleanup_zombie() {
    local worker_id="$1"
    local task_id="$2"
    local reason="$3"

    log "Cleaning up zombie: $worker_id (task: $task_id)"
    log "  Reason: $reason"

    if [ "$DRY_RUN" = true ]; then
        log "  [DRY RUN] Would clean up $worker_id"
        return
    fi

    # 1. Archive worker spec to failed/
    mkdir -p "$PROJECT_ROOT/coordination/worker-specs/failed"
    if [ -f "$PROJECT_ROOT/coordination/worker-specs/active/$worker_id.json" ]; then
        # Add zombie metadata
        jq ". + {zombie_detected_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", zombie_reason: \"$reason\"}" \
            "$PROJECT_ROOT/coordination/worker-specs/active/$worker_id.json" > \
            "$PROJECT_ROOT/coordination/worker-specs/failed/$worker_id.json"

        rm "$PROJECT_ROOT/coordination/worker-specs/active/$worker_id.json"
        log "  ✅ Archived worker spec to failed/"
    fi

    # 2. Archive worker directory
    worker_dir="$PROJECT_ROOT/agents/workers/$worker_id"
    if [ -d "$worker_dir" ]; then
        mkdir -p "$PROJECT_ROOT/agents/workers/zombies"
        mv "$worker_dir" "$PROJECT_ROOT/agents/workers/zombies/"
        log "  ✅ Archived worker directory to zombies/"
    fi

    # 3. Update task status to 'pending' for retry
    if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
        jq --arg tid "$task_id" \
            '(.tasks[] | select(.id == $tid)) |= (. + {
                status: "pending",
                zombie_cleanup_at: "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
                previous_worker: "'$worker_id'",
                retry_count: ((.retry_count // 0) + 1)
            })' \
            "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue-zombie-cleanup.json

        mv /tmp/task-queue-zombie-cleanup.json "$PROJECT_ROOT/coordination/task-queue.json"
        log "  ✅ Reset task $task_id to 'pending' for retry"
    fi

    # 4. Emit zombie detection event
    if [ -f "$SCRIPT_DIR/emit-event.sh" ]; then
        "$SCRIPT_DIR/emit-event.sh" "zombie_detected" \
            "{\"worker_id\":\"$worker_id\",\"task_id\":\"$task_id\",\"reason\":\"$reason\"}" \
            "zombie-cleanup" 2>/dev/null || true
    fi

    log "  ✅ Zombie cleanup complete"
}

# Main execution
main() {
    log "=========================================="
    log "ZOMBIE WORKER CLEANUP"
    log "Age threshold: $ZOMBIE_AGE_MINUTES minutes"
    log "Dry run: $DRY_RUN"
    log "=========================================="
    echo ""

    # Detect zombies
    zombies=$(detect_zombies)

    if [ -z "$zombies" ]; then
        log "No zombie workers detected. System healthy!"
        exit 0
    fi

    # Count zombies
    zombie_array=($zombies)
    zombie_count=${#zombie_array[@]}

    warn "Found $zombie_count zombie workers"
    echo ""

    # Clean up each zombie
    for zombie_entry in "${zombie_array[@]}"; do
        IFS=':' read -r worker_id task_id reason <<< "$zombie_entry"
        cleanup_zombie "$worker_id" "$task_id" "$reason"
        echo ""
    done

    log "=========================================="
    log "Zombie cleanup complete: $zombie_count workers processed"
    log "=========================================="

    # Summary
    if [ "$DRY_RUN" = false ]; then
        log ""
        log "Next steps:"
        log "  1. Worker specs archived to: coordination/worker-specs/failed/"
        log "  2. Worker directories archived to: agents/workers/zombies/"
        log "  3. Tasks reset to 'pending' for retry"
        log "  4. Run worker daemon to relaunch tasks"
    fi
}

# Run main
main
