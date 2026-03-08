#!/usr/bin/env bash
#
# Automated Worker Scheduling Library
# Part of Phase 8.1: Automated Worker Scheduling
#
# Provides intelligent task assignment, priority queuing, and load balancing
#

set -euo pipefail

if [[ -z "${SCHEDULER_LOADED:-}" ]]; then
    readonly SCHEDULER_LOADED=true
fi

# Directory setup
SCHEDULER_DIR="${SCHEDULER_DIR:-coordination/optimization/scheduling}"

#
# Initialize scheduler
#
init_scheduler() {
    mkdir -p "$SCHEDULER_DIR"/{queue,assignments,history}
}

#
# Get timestamp
#
_get_ts() {
    date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000))
}

#
# Calculate task priority score
#
calculate_priority() {
    local task_type="$1"
    local urgency="${2:-medium}"
    local dependencies="${3:-0}"

    local base_score=50

    # Type-based scoring
    case "$task_type" in
        security|scan) base_score=80 ;;
        fix|bug) base_score=70 ;;
        implementation) base_score=60 ;;
        test) base_score=50 ;;
        documentation) base_score=40 ;;
        *) base_score=50 ;;
    esac

    # Urgency modifier
    case "$urgency" in
        critical) base_score=$((base_score + 40)) ;;
        high) base_score=$((base_score + 20)) ;;
        medium) base_score=$((base_score + 0)) ;;
        low) base_score=$((base_score - 10)) ;;
    esac

    # Dependency modifier (fewer dependencies = higher priority)
    base_score=$((base_score - dependencies * 5))

    # Clamp to 0-100
    if [[ $base_score -gt 100 ]]; then base_score=100; fi
    if [[ $base_score -lt 0 ]]; then base_score=0; fi

    echo "$base_score"
}

#
# Schedule task
#
schedule_task() {
    local task_id="$1"
    local task_type="$2"
    local urgency="${3:-medium}"
    local estimated_tokens="${4:-5000}"

    init_scheduler

    local priority=$(calculate_priority "$task_type" "$urgency")
    local timestamp=$(_get_ts)

    local schedule=$(cat <<EOF
{
  "task_id": "$task_id",
  "task_type": "$task_type",
  "urgency": "$urgency",
  "priority": $priority,
  "estimated_tokens": $estimated_tokens,
  "status": "queued",
  "scheduled_at": $timestamp,
  "assigned_at": null,
  "worker_id": null
}
EOF
)

    echo "$schedule" > "$SCHEDULER_DIR/queue/${task_id}.json"
    echo "$task_id"
}

#
# Get optimal worker for task
#
get_optimal_worker() {
    local task_type="$1"
    local estimated_tokens="${2:-5000}"

    # Determine best worker type based on task
    local worker_type="analysis"
    case "$task_type" in
        security|scan) worker_type="scan" ;;
        fix|bug) worker_type="fix" ;;
        implementation|feature) worker_type="implementation" ;;
        test) worker_type="test" ;;
        documentation) worker_type="documentation" ;;
    esac

    # Check current worker load
    local active_count=$(ls coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')

    # Calculate optimal timing
    local delay=0
    if [[ $active_count -gt 10 ]]; then
        delay=$((active_count * 1000))
    fi

    cat <<EOF
{
  "worker_type": "$worker_type",
  "active_workers": $active_count,
  "recommended_delay_ms": $delay,
  "estimated_tokens": $estimated_tokens
}
EOF
}

#
# Assign task to worker
#
assign_task() {
    local task_id="$1"
    local worker_id="$2"

    local queue_file="$SCHEDULER_DIR/queue/${task_id}.json"
    if [[ ! -f "$queue_file" ]]; then
        echo "Task not found in queue: $task_id" >&2
        return 1
    fi

    local schedule=$(cat "$queue_file")
    schedule=$(echo "$schedule" | jq \
        --arg worker "$worker_id" \
        --argjson ts "$(_get_ts)" \
        '.status = "assigned" | .worker_id = $worker | .assigned_at = $ts')

    # Move to assignments
    echo "$schedule" > "$SCHEDULER_DIR/assignments/${task_id}.json"
    rm "$queue_file"

    echo "Task $task_id assigned to $worker_id"
}

#
# Get queue status
#
get_queue_status() {
    init_scheduler

    local queued=0
    local assigned=0
    local tasks="[]"

    for file in "$SCHEDULER_DIR/queue"/*.json; do
        if [[ -f "$file" ]]; then
            queued=$((queued + 1))
            local task=$(cat "$file")
            tasks=$(echo "$tasks" | jq --argjson t "$task" '. + [$t]')
        fi
    done

    for file in "$SCHEDULER_DIR/assignments"/*.json; do
        if [[ -f "$file" ]]; then
            assigned=$((assigned + 1))
        fi
    done

    cat <<EOF
{
  "queued": $queued,
  "assigned": $assigned,
  "tasks": $(echo "$tasks" | jq 'sort_by(.priority) | reverse')
}
EOF
}

#
# Auto-schedule next tasks
#
auto_schedule() {
    local max_concurrent="${1:-10}"

    init_scheduler

    local active_workers=$(ls coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
    local available_slots=$((max_concurrent - active_workers))

    if [[ $available_slots -le 0 ]]; then
        echo '{"scheduled": 0, "message": "No available slots"}'
        return
    fi

    local scheduled=0
    local scheduled_tasks="[]"

    # Get tasks sorted by priority
    for file in $(ls -t "$SCHEDULER_DIR/queue"/*.json 2>/dev/null | head -n "$available_slots"); do
        if [[ -f "$file" ]]; then
            local task=$(cat "$file")
            local task_id=$(echo "$task" | jq -r '.task_id')
            local task_type=$(echo "$task" | jq -r '.task_type')

            # Get optimal worker
            local optimal=$(get_optimal_worker "$task_type")
            local worker_type=$(echo "$optimal" | jq -r '.worker_type')

            scheduled=$((scheduled + 1))
            scheduled_tasks=$(echo "$scheduled_tasks" | jq \
                --arg id "$task_id" \
                --arg type "$worker_type" \
                '. + [{task_id: $id, worker_type: $type}]')
        fi
    done

    cat <<EOF
{
  "scheduled": $scheduled,
  "available_slots": $available_slots,
  "tasks": $scheduled_tasks
}
EOF
}

#
# Balance load across masters
#
balance_load() {
    local masters=("coordinator" "development" "security" "inventory" "cicd")
    local load="[]"

    for master in "${masters[@]}"; do
        local count=0
        for file in coordination/worker-specs/active/*.json; do
            if [[ -f "$file" ]]; then
                local m=$(jq -r '.master // ""' "$file" 2>/dev/null)
                if [[ "$m" == "$master" ]]; then
                    count=$((count + 1))
                fi
            fi
        done

        load=$(echo "$load" | jq \
            --arg master "$master" \
            --argjson count "$count" \
            '. + [{master: $master, active_workers: $count}]')
    done

    # Find least loaded master
    local recommended=$(echo "$load" | jq -r 'min_by(.active_workers) | .master')

    cat <<EOF
{
  "load_distribution": $load,
  "recommended_master": "$recommended"
}
EOF
}

#
# Get scheduling statistics
#
get_scheduler_stats() {
    init_scheduler

    local queued=$(ls "$SCHEDULER_DIR/queue"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local assigned=$(ls "$SCHEDULER_DIR/assignments"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local completed=$(ls "$SCHEDULER_DIR/history"/*.json 2>/dev/null | wc -l | tr -d ' ')

    cat <<EOF
{
  "queued": $queued,
  "assigned": $assigned,
  "completed": $completed,
  "queue_status": $(get_queue_status),
  "load_balance": $(balance_load)
}
EOF
}

# Export functions
export -f init_scheduler
export -f calculate_priority
export -f schedule_task
export -f get_optimal_worker
export -f assign_task
export -f get_queue_status
export -f auto_schedule
export -f balance_load
export -f get_scheduler_stats
