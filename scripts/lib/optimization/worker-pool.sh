#!/usr/bin/env bash
#
# Worker Pooling & Reuse Library
# Part of Phase 8.3: Worker Pooling & Reuse
#
# Provides persistent worker management, warm pools, and intelligent reuse
#

set -euo pipefail

if [[ -z "${WORKER_POOL_LOADED:-}" ]]; then
    readonly WORKER_POOL_LOADED=true
fi

# Directory setup
POOL_DIR="${POOL_DIR:-coordination/optimization/pooling}"

#
# Initialize pool
#
init_worker_pool() {
    mkdir -p "$POOL_DIR"/{warm,cold,assignments}
}

#
# Get timestamp
#
_get_ts() {
    date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000))
}

#
# Create warm worker
#
create_warm_worker() {
    local worker_type="$1"
    local master="${2:-coordinator}"

    init_worker_pool

    local worker_id="warm-${worker_type}-$(date +%s)-$RANDOM"
    local timestamp=$(_get_ts)

    local worker=$(cat <<EOF
{
  "worker_id": "$worker_id",
  "worker_type": "$worker_type",
  "master": "$master",
  "status": "warm",
  "created_at": $timestamp,
  "last_used": null,
  "tasks_completed": 0,
  "total_tokens_used": 0
}
EOF
)

    echo "$worker" > "$POOL_DIR/warm/${worker_id}.json"
    echo "$worker_id"
}

#
# Get available warm worker
#
get_warm_worker() {
    local worker_type="$1"

    init_worker_pool

    for file in "$POOL_DIR/warm"/*.json; do
        if [[ -f "$file" ]]; then
            local type=$(jq -r '.worker_type // ""' "$file")
            if [[ "$type" == "$worker_type" ]]; then
                local worker_id=$(jq -r '.worker_id' "$file")
                echo "$worker_id"
                return 0
            fi
        fi
    done

    echo ""
}

#
# Assign worker from pool
#
assign_from_pool() {
    local worker_type="$1"
    local task_id="$2"

    init_worker_pool

    local worker_id=$(get_warm_worker "$worker_type")

    if [[ -z "$worker_id" ]]; then
        # Create new warm worker
        worker_id=$(create_warm_worker "$worker_type")
    fi

    local file="$POOL_DIR/warm/${worker_id}.json"
    if [[ -f "$file" ]]; then
        local worker=$(cat "$file")
        worker=$(echo "$worker" | jq \
            --arg task "$task_id" \
            --argjson ts "$(_get_ts)" \
            '.status = "active" | .current_task = $task | .last_used = $ts')

        # Move to assignments
        echo "$worker" > "$POOL_DIR/assignments/${worker_id}.json"
        rm "$file"
    fi

    echo "$worker_id"
}

#
# Return worker to pool
#
return_to_pool() {
    local worker_id="$1"
    local tokens_used="${2:-0}"

    init_worker_pool

    local file="$POOL_DIR/assignments/${worker_id}.json"
    if [[ ! -f "$file" ]]; then
        echo "Worker not found in assignments: $worker_id" >&2
        return 1
    fi

    local worker=$(cat "$file")
    local tasks_completed=$(echo "$worker" | jq -r '.tasks_completed // 0')
    local total_tokens=$(echo "$worker" | jq -r '.total_tokens_used // 0')

    worker=$(echo "$worker" | jq \
        --argjson tasks "$((tasks_completed + 1))" \
        --argjson tokens "$((total_tokens + tokens_used))" \
        --argjson ts "$(_get_ts)" \
        '.status = "warm" | .current_task = null | .tasks_completed = $tasks | .total_tokens_used = $tokens | .last_used = $ts')

    # Return to warm pool
    echo "$worker" > "$POOL_DIR/warm/${worker_id}.json"
    rm "$file"

    echo "Worker returned to pool: $worker_id"
}

#
# Retire worker
#
retire_worker() {
    local worker_id="$1"
    local reason="${2:-max_tasks}"

    init_worker_pool

    local file="$POOL_DIR/warm/${worker_id}.json"
    if [[ -f "$file" ]]; then
        local worker=$(cat "$file")
        worker=$(echo "$worker" | jq \
            --arg reason "$reason" \
            --argjson ts "$(_get_ts)" \
            '.status = "retired" | .retired_at = $ts | .retirement_reason = $reason')

        # Move to cold storage
        echo "$worker" > "$POOL_DIR/cold/${worker_id}.json"
        rm "$file"

        echo "Worker retired: $worker_id ($reason)"
    fi
}

#
# Get pool status
#
get_pool_status() {
    init_worker_pool

    local warm=$(ls "$POOL_DIR/warm"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local active=$(ls "$POOL_DIR/assignments"/*.json 2>/dev/null | wc -l | tr -d ' ')
    local cold=$(ls "$POOL_DIR/cold"/*.json 2>/dev/null | wc -l | tr -d ' ')

    # Count by type
    local by_type="[]"
    local types=("implementation" "fix" "test" "scan" "security-fix" "documentation" "analysis")

    for wtype in "${types[@]}"; do
        local count=0
        for file in "$POOL_DIR/warm"/*.json; do
            if [[ -f "$file" ]]; then
                local t=$(jq -r '.worker_type // ""' "$file")
                if [[ "$t" == *"$wtype"* ]]; then
                    count=$((count + 1))
                fi
            fi
        done

        by_type=$(echo "$by_type" | jq \
            --arg type "$wtype" \
            --argjson count "$count" \
            '. + [{type: $type, warm: $count}]')
    done

    cat <<EOF
{
  "warm": $warm,
  "active": $active,
  "cold": $cold,
  "by_type": $by_type
}
EOF
}

#
# Warm up pool
#
warm_up_pool() {
    local target="${1:-5}"

    init_worker_pool

    local types=("implementation" "fix" "test" "scan" "analysis")
    local created=0

    for wtype in "${types[@]}"; do
        local current=$(get_warm_worker "$wtype" | wc -l | tr -d ' ')
        local needed=$((target - current))

        for _ in $(seq 1 $needed); do
            create_warm_worker "$wtype"
            created=$((created + 1))
        done
    done

    echo "Warmed up pool: $created workers created"
}

#
# Clean up cold workers
#
cleanup_cold_pool() {
    local max_age_hours="${1:-24}"

    init_worker_pool

    local now=$(_get_ts)
    local max_age_ms=$((max_age_hours * 3600000))
    local cleaned=0

    for file in "$POOL_DIR/cold"/*.json; do
        if [[ -f "$file" ]]; then
            local retired_at=$(jq -r '.retired_at // 0' "$file")
            local age=$((now - retired_at))

            if [[ $age -gt $max_age_ms ]]; then
                rm "$file"
                cleaned=$((cleaned + 1))
            fi
        fi
    done

    echo "Cleaned up $cleaned cold workers"
}

#
# Get pool efficiency
#
get_pool_efficiency() {
    init_worker_pool

    local total_tasks=0
    local total_tokens=0
    local worker_count=0

    for file in "$POOL_DIR/warm"/*.json "$POOL_DIR/cold"/*.json; do
        if [[ -f "$file" ]]; then
            local tasks=$(jq -r '.tasks_completed // 0' "$file")
            local tokens=$(jq -r '.total_tokens_used // 0' "$file")
            total_tasks=$((total_tasks + tasks))
            total_tokens=$((total_tokens + tokens))
            worker_count=$((worker_count + 1))
        fi
    done

    local avg_tasks=0
    local avg_tokens=0
    if [[ $worker_count -gt 0 ]]; then
        avg_tasks=$(echo "scale=2; $total_tasks / $worker_count" | bc)
        avg_tokens=$(echo "scale=2; $total_tokens / $worker_count" | bc)
    fi

    cat <<EOF
{
  "total_workers": $worker_count,
  "total_tasks": $total_tasks,
  "total_tokens": $total_tokens,
  "avg_tasks_per_worker": $avg_tasks,
  "avg_tokens_per_worker": $avg_tokens,
  "reuse_efficiency": $(echo "scale=2; ($total_tasks - $worker_count) * 100 / ($total_tasks + 1)" | bc)
}
EOF
}

#
# Get pool statistics
#
get_pool_stats() {
    cat <<EOF
{
  "status": $(get_pool_status),
  "efficiency": $(get_pool_efficiency)
}
EOF
}

# Export functions
export -f init_worker_pool
export -f create_warm_worker
export -f get_warm_worker
export -f assign_from_pool
export -f return_to_pool
export -f retire_worker
export -f get_pool_status
export -f warm_up_pool
export -f cleanup_cold_pool
export -f get_pool_efficiency
export -f get_pool_stats
