#!/bin/bash
# scripts/lib/coordination.sh
# Coordination file utilities for commit-relay

# Coordination directory
COORD_DIR="${COMMIT_RELAY_HOME:-$(pwd)}/coordination"

# Ensure coordination directory exists
ensure_coordination_dir() {
    if [ ! -d "$COORD_DIR" ]; then
        log_error "Coordination directory not found: $COORD_DIR"
        return 1
    fi
    return 0
}

# Read task from task queue
get_task() {
    local task_id=$1
    ensure_coordination_dir || return 1

    local task_file="$COORD_DIR/task-queue.json"
    if [ ! -f "$task_file" ]; then
        log_error "Task queue file not found: $task_file"
        return 1
    fi

    jq ".tasks[] | select(.id == \"$task_id\")" "$task_file"
}

# Get all pending tasks of a specific type
get_pending_tasks() {
    local task_type="${1:-}"
    ensure_coordination_dir || return 1

    local task_file="$COORD_DIR/task-queue.json"
    if [ ! -f "$task_file" ]; then
        echo "[]"
        return 0
    fi

    if [ -n "$task_type" ]; then
        jq "[.tasks[] | select(.status == \"pending\" and .type == \"$task_type\")]" "$task_file"
    else
        jq '[.tasks[] | select(.status == "pending")]' "$task_file"
    fi
}

# Update task status
update_task_status() {
    local task_id=$1
    local new_status=$2
    local additional_data="${3:-{}"

    ensure_coordination_dir || return 1

    local task_file="$COORD_DIR/task-queue.json"
    local temp_file=$(mktemp)

    # Update task with new status
    log_debug "Updating task $task_id with data: $additional_data"
    jq \
        --arg id "$task_id" \
        --arg status "$new_status" \
        --arg timestamp "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson data "$additional_data" \
        '(.tasks[] | select(.id == $id)) |= (. + {status: $status} + $data + {updated_at: $timestamp})' \
        "$task_file" > "$temp_file" 2>&1 | tee /tmp/jq-error.log

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$task_file"
        log_info "Updated task $task_id status: $new_status"
        return 0
    else
        rm -f "$temp_file"
        log_error "Failed to update task $task_id"
        return 1
    fi
}

# Add worker to worker pool
add_worker_to_pool() {
    local worker_id=$1
    local worker_type=$2
    local task_id=$3
    local spawned_by=$4
    local status="${5:-active}"

    ensure_coordination_dir || return 1

    local pool_file="$COORD_DIR/worker-pool.json"
    local temp_file=$(mktemp)

    local worker_data=$(jq -n \
        --arg id "$worker_id" \
        --arg type "$worker_type" \
        --arg task "$task_id" \
        --arg by "$spawned_by" \
        --arg status "$status" \
        --arg started "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            id: $id,
            type: $type,
            task_id: $task,
            spawned_by: $by,
            status: $status,
            started_at: $started,
            tokens_used: 0
        }')

    # Add to active_workers array
    jq \
        --argjson worker "$worker_data" \
        '.active_workers += [$worker]' \
        "$pool_file" > "$temp_file"

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$pool_file"
        log_info "Added worker $worker_id to pool"
        return 0
    else
        rm -f "$temp_file"
        log_error "Failed to add worker $worker_id to pool"
        return 1
    fi
}

# Update worker status in pool
update_worker_status() {
    local worker_id=$1
    local new_status=$2
    local tokens_used="${3:-0}"

    ensure_coordination_dir || return 1

    local pool_file="$COORD_DIR/worker-pool.json"
    local temp_file=$(mktemp)

    local completed_at=""
    if [ "$new_status" == "completed" ] || [ "$new_status" == "failed" ]; then
        completed_at=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)
    fi

    # Move worker from active to completed/failed
    if [ "$new_status" == "completed" ]; then
        jq \
            --arg id "$worker_id" \
            --arg ts "$completed_at" \
            --arg tokens "$tokens_used" \
            '(.active_workers[] | select(.id == $id)) as $worker |
             .active_workers = [.active_workers[] | select(.id != $id)] |
             .completed_workers += [$worker + {completed_at: $ts, tokens_used: ($tokens | tonumber)}]' \
            "$pool_file" > "$temp_file"
    elif [ "$new_status" == "failed" ]; then
        jq \
            --arg id "$worker_id" \
            --arg ts "$completed_at" \
            '(.active_workers[] | select(.id == $id)) as $worker |
             .active_workers = [.active_workers[] | select(.id != $id)] |
             .failed_workers += [$worker + {failed_at: $ts}]' \
            "$pool_file" > "$temp_file"
    else
        # Just update status in active_workers
        jq \
            --arg id "$worker_id" \
            --arg status "$new_status" \
            '(.active_workers[] | select(.id == $id)).status = $status' \
            "$pool_file" > "$temp_file"
    fi

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$pool_file"
        log_info "Updated worker $worker_id status: $new_status"
        return 0
    else
        rm -f "$temp_file"
        log_error "Failed to update worker $worker_id"
        return 1
    fi
}

# Create handoff
create_handoff() {
    local from_agent=$1
    local to_agent=$2
    local task_id=$3
    local context=$4

    ensure_coordination_dir || return 1

    local handoffs_file="$COORD_DIR/handoffs.json"
    local temp_file=$(mktemp)

    local handoff_id="handoff-$(date +%s)"
    local handoff_data=$(jq -n \
        --arg id "$handoff_id" \
        --arg from "$from_agent" \
        --arg to "$to_agent" \
        --arg task "$task_id" \
        --arg ctx "$context" \
        --arg ts "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            handoff_id: $id,
            from_agent: $from,
            to_agent: $to,
            task_id: $task,
            context: $ctx,
            status: "pending",
            created_at: $ts
        }')

    # Add to handoffs array
    jq \
        --argjson handoff "$handoff_data" \
        '.handoffs += [$handoff]' \
        "$handoffs_file" > "$temp_file"

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$handoffs_file"
        log_info "Created handoff: $from_agent -> $to_agent (task: $task_id)"
        echo "$handoff_id"
        return 0
    else
        rm -f "$temp_file"
        log_error "Failed to create handoff"
        return 1
    fi
}

# Check token budget availability
check_token_budget() {
    local agent_id=$1
    local estimated_tokens=$2

    ensure_coordination_dir || return 1

    local budget_file="$COORD_DIR/token-budget.json"

    local allocated=$(jq -r ".masters[\"$agent_id\"].allocated // 0" "$budget_file")
    local used=$(jq -r ".masters[\"$agent_id\"].used // 0" "$budget_file")
    local available=$((allocated - used))

    if [ "$estimated_tokens" -gt "$available" ]; then
        log_warn "Insufficient token budget for $agent_id: need $estimated_tokens, have $available"
        return 1
    fi

    log_debug "Token budget check passed for $agent_id: $estimated_tokens / $available available"
    return 0
}

# Consume tokens from budget
consume_tokens() {
    local agent_id=$1
    local tokens_used=$2
    local token_type="${3:-used}"  # "used" or "worker_pool"

    ensure_coordination_dir || return 1

    local budget_file="$COORD_DIR/token-budget.json"
    local temp_file=$(mktemp)

    jq \
        --arg agent "$agent_id" \
        --arg tokens "$tokens_used" \
        --arg type "$token_type" \
        ".masters[\$agent].\$type += (\$tokens | tonumber)" \
        "$budget_file" > "$temp_file"

    if [ $? -eq 0 ]; then
        mv "$temp_file" "$budget_file"
        log_debug "Consumed $tokens_used tokens from $agent_id.$token_type"
        return 0
    else
        rm -f "$temp_file"
        log_error "Failed to consume tokens"
        return 1
    fi
}

# Acquire lock for agent (prevent concurrent runs)
acquire_lock() {
    local agent_id=$1
    local lock_file="/tmp/commit-relay-${agent_id}.lock"

    if [ -f "$lock_file" ]; then
        local pid=$(cat "$lock_file")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "$agent_id already running (PID: $pid)"
            return 1
        else
            log_warn "Stale lock file found for $agent_id, removing"
            rm -f "$lock_file"
        fi
    fi

    echo $$ > "$lock_file"
    log_debug "Acquired lock for $agent_id (PID: $$)"
    return 0
}

# Release lock for agent
release_lock() {
    local agent_id=$1
    local lock_file="/tmp/commit-relay-${agent_id}.lock"

    rm -f "$lock_file"
    log_debug "Released lock for $agent_id"
}

# Get worker type config
get_worker_config() {
    local worker_type=$1
    local registry_file="${COMMIT_RELAY_HOME:-$(pwd)}/agents/configs/agent-registry.json"

    if [ ! -f "$registry_file" ]; then
        log_error "Agent registry not found: $registry_file"
        return 1
    fi

    jq ".worker_types[\"$worker_type\"]" "$registry_file"
}
