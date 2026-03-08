#!/bin/bash
# EM Spawning Library - v4.0
# Reusable functions for Execution Manager spawning decision logic
# Used by specialist master agents (Development, Security, Inventory)

# v4.0: Check if task requires Execution Manager
should_spawn_execution_manager() {
    local task_data="$1"

    # Extract task characteristics
    local files_count=$(echo "$task_data" | jq -r '.files_affected | length // 0' 2>/dev/null || echo 0)
    local repos_count=$(echo "$task_data" | jq -r '.repos | length // 0' 2>/dev/null || echo 0)
    local estimated_workers=$(echo "$task_data" | jq -r '.estimated_workers // 0' 2>/dev/null || echo 0)
    local token_budget=$(echo "$task_data" | jq -r '.token_budget // 0' 2>/dev/null || echo 0)
    local has_dependencies=$(echo "$task_data" | jq -r '.dependencies | length > 0' 2>/dev/null || echo "false")
    local multi_phase=$(echo "$task_data" | jq -r '.multi_phase // false' 2>/dev/null)

    # Decision criteria (from v4.0 specs)
    # Spawn EM if ANY of these conditions are met:
    if [ "$files_count" -ge 10 ]; then
        log_info "EM needed: 10+ files affected ($files_count files)"
        return 0
    fi

    if [ "$repos_count" -ge 2 ]; then
        log_info "EM needed: Multi-repository task ($repos_count repos)"
        return 0
    fi

    if [ "$estimated_workers" -ge 5 ]; then
        log_info "EM needed: 5+ workers required ($estimated_workers workers)"
        return 0
    fi

    if [ "$token_budget" -ge 30000 ]; then
        log_info "EM needed: Large token budget (${token_budget}k tokens)"
        return 0
    fi

    if [ "$has_dependencies" = "true" ]; then
        log_info "EM needed: Task has dependencies requiring sequencing"
        return 0
    fi

    if [ "$multi_phase" = "true" ]; then
        log_info "EM needed: Multi-phase execution required"
        return 0
    fi

    log_info "EM not needed: Task suitable for direct worker spawning"
    return 1
}

# v4.0: Spawn Execution Manager for complex tasks
# Parameters:
#   $1 - task_id
#   $2 - task_data (JSON)
#   $3 - master_type (development|security|inventory)
spawn_execution_manager_for_master() {
    local task_id="$1"
    local task_data="$2"
    local master_type="$3"

    log_section "v4.0: Spawning Execution Manager"

    # Extract task details
    local description=$(echo "$task_data" | jq -r '.description // "Complex multi-worker coordination task"')
    local files_affected=$(echo "$task_data" | jq -r '.files_affected // [] | join(",")')
    local repos=$(echo "$task_data" | jq -r '.repos // [] | join(",")')
    local token_budget=$(echo "$task_data" | jq -r '.token_budget // 25000')
    local estimated_duration=$(echo "$task_data" | jq -r '.estimated_duration_minutes // 60')

    # Generate subtask ID based on master type
    local prefix=""
    case "$master_type" in
        development) prefix="dev" ;;
        security) prefix="sec" ;;
        inventory) prefix="inv" ;;
        *) prefix="unknown" ;;
    esac

    local subtask_id="${prefix}-$(echo $task_id | cut -d'-' -f2-)-subtask-001"

    # Build spawn-execution-manager.sh command
    local spawn_cmd="$SCRIPT_DIR/spawn-execution-manager.sh"
    spawn_cmd="$spawn_cmd --master $master_type"
    spawn_cmd="$spawn_cmd --subtask-id $subtask_id"
    spawn_cmd="$spawn_cmd --description \"$description\""

    if [ -n "$files_affected" ]; then
        spawn_cmd="$spawn_cmd --files \"$files_affected\""
    fi

    if [ -n "$repos" ]; then
        spawn_cmd="$spawn_cmd --repos \"$repos\""
    fi

    spawn_cmd="$spawn_cmd --token-budget $token_budget"
    spawn_cmd="$spawn_cmd --estimated-duration $estimated_duration"

    # Execute EM spawning
    log_info "Executing: $spawn_cmd"
    eval "$spawn_cmd"

    if [ $? -eq 0 ]; then
        log_success "Execution Manager spawned successfully for subtask: $subtask_id"
        update_task_status "$task_id" "em_spawned" "{\"subtask_id\": \"$subtask_id\", \"coordination_mode\": \"execution_manager\"}"
        return 0
    else
        log_error "Failed to spawn Execution Manager"
        return 1
    fi
}
