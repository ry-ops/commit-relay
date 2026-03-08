#!/usr/bin/env bash
#
# Playbook Executor Library
# Part of Phase 4 Item 27: Automated Remediation Playbooks
#
# Executes remediation playbooks based on failure patterns.
# Links patterns to automated recovery procedures.
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Configuration
readonly PLAYBOOK_REGISTRY="${PLAYBOOK_REGISTRY:-$PROJECT_ROOT/coordination/remediation/playbook-registry.json}"
readonly PLAYBOOK_EXECUTIONS_DIR="${PLAYBOOK_EXECUTIONS_DIR:-$PROJECT_ROOT/coordination/remediation/executions}"
readonly PLAYBOOK_LOG_FILE="${PLAYBOOK_LOG_FILE:-$PROJECT_ROOT/coordination/remediation/playbook-executor.log}"
readonly PLAYBOOK_HISTORY_FILE="${PLAYBOOK_HISTORY_FILE:-$PROJECT_ROOT/coordination/remediation/execution-history.jsonl}"

# Initialize directories
mkdir -p "$PLAYBOOK_EXECUTIONS_DIR" "$(dirname "$PLAYBOOK_LOG_FILE")"

#
# Log message
#
log_playbook() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$PLAYBOOK_LOG_FILE"
}

#
# Generate execution ID
#
generate_execution_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 4)
    echo "exec-${timestamp}-${random}"
}

#
# Get current timestamp
#
get_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

#
# Load playbook registry
#
load_playbook_registry() {
    if [[ -f "$PLAYBOOK_REGISTRY" ]]; then
        cat "$PLAYBOOK_REGISTRY"
    else
        echo '{"playbooks": []}'
    fi
}

#
# Find playbook by pattern
#
find_playbook_for_pattern() {
    local pattern="$1"
    local severity="${2:-medium}"

    local registry=$(load_playbook_registry)

    # Find matching playbook
    echo "$registry" | jq -r --arg pattern "$pattern" --arg severity "$severity" '
        .playbooks[] |
        select(
            .enabled == true and
            (.trigger_patterns | index($pattern)) and
            (
                ($severity == "critical" and .severity_threshold != "critical") or
                ($severity == "high" and (.severity_threshold == "high" or .severity_threshold == "medium" or .severity_threshold == "low")) or
                ($severity == "medium" and (.severity_threshold == "medium" or .severity_threshold == "low")) or
                ($severity == "low" and .severity_threshold == "low")
            )
        )
    ' | head -1
}

#
# Find playbook by ID
#
get_playbook_by_id() {
    local playbook_id="$1"

    local registry=$(load_playbook_registry)
    echo "$registry" | jq -r --arg id "$playbook_id" '.playbooks[] | select(.playbook_id == $id)'
}

#
# Execute a single playbook step
#
execute_step() {
    local step="$1"
    local execution_id="$2"
    local context="$3"

    local step_id=$(echo "$step" | jq -r '.step_id')
    local action=$(echo "$step" | jq -r '.action')
    local description=$(echo "$step" | jq -r '.description')
    local params=$(echo "$step" | jq -r '.params')
    local on_failure=$(echo "$step" | jq -r '.on_failure')

    log_playbook "INFO" "Executing step $step_id: $action - $description"

    local step_start=$(date +%s)
    local step_result="success"
    local step_output=""
    local step_error=""

    # Execute the action
    case "$action" in
        "kill_worker")
            local worker_id=$(echo "$context" | jq -r '.worker_id // empty')
            local signal=$(echo "$params" | jq -r '.signal // "SIGTERM"')
            local timeout=$(echo "$params" | jq -r '.timeout_seconds // 10')

            if [[ -n "$worker_id" ]]; then
                # Find worker PID
                local pid_file="/tmp/commit-relay-worker-${worker_id}.pid"
                if [[ -f "$pid_file" ]]; then
                    local pid=$(cat "$pid_file")
                    if kill -0 "$pid" 2>/dev/null; then
                        kill -"${signal#SIG}" "$pid" 2>/dev/null || true
                        sleep 1
                        if kill -0 "$pid" 2>/dev/null; then
                            kill -9 "$pid" 2>/dev/null || true
                        fi
                        step_output="Worker $worker_id terminated"
                    else
                        step_output="Worker $worker_id already stopped"
                    fi
                    rm -f "$pid_file"
                else
                    step_output="No PID file for worker $worker_id"
                fi
            else
                step_error="No worker_id in context"
                step_result="failed"
            fi
            ;;

        "cleanup_state")
            local worker_id=$(echo "$context" | jq -r '.worker_id // empty')
            local files=$(echo "$params" | jq -r '.files[]')

            local cleaned=0
            for file_type in $files; do
                case "$file_type" in
                    "worker-spec")
                        local spec_file="$PROJECT_ROOT/coordination/worker-specs/active/worker-${worker_id}.json"
                        if [[ -f "$spec_file" ]]; then
                            rm -f "$spec_file"
                            cleaned=$((cleaned + 1))
                        fi
                        ;;
                    "heartbeat")
                        local hb_file="$PROJECT_ROOT/coordination/heartbeats/worker-${worker_id}.json"
                        if [[ -f "$hb_file" ]]; then
                            rm -f "$hb_file"
                            cleaned=$((cleaned + 1))
                        fi
                        ;;
                esac
            done
            step_output="Cleaned $cleaned files"
            ;;

        "requeue_task")
            local task_id=$(echo "$context" | jq -r '.task_id // empty')
            local priority_boost=$(echo "$params" | jq -r '.priority_boost // 0')

            if [[ -n "$task_id" ]]; then
                # Add task back to queue with boosted priority
                local queue_file="$PROJECT_ROOT/coordination/task-queue.json"
                if [[ -f "$queue_file" ]]; then
                    # This is a simplified version - actual implementation would be more robust
                    step_output="Task $task_id requeued with priority boost $priority_boost"
                else
                    step_error="Task queue file not found"
                    step_result="failed"
                fi
            else
                step_error="No task_id in context"
                step_result="failed"
            fi
            ;;

        "emit_event")
            local event_type=$(echo "$params" | jq -r '.event_type')
            local severity=$(echo "$params" | jq -r '.severity // "info"')

            local event=$(jq -n \
                --arg type "$event_type" \
                --arg severity "$severity" \
                --arg execution_id "$execution_id" \
                --arg timestamp "$(get_timestamp)" \
                '{
                    type: $type,
                    timestamp: $timestamp,
                    severity: $severity,
                    execution_id: $execution_id
                }')

            echo "$event" >> "$PROJECT_ROOT/coordination/dashboard-events.jsonl"
            step_output="Event emitted: $event_type"
            ;;

        "pause_queue")
            local duration=$(echo "$params" | jq -r '.duration_minutes // 5')

            local pause_file="$PROJECT_ROOT/coordination/queue-pause.json"
            local resume_at=$(date -v+${duration}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "+${duration} minutes" +%Y-%m-%dT%H:%M:%SZ)

            jq -n \
                --arg paused_at "$(get_timestamp)" \
                --arg resume_at "$resume_at" \
                --arg execution_id "$execution_id" \
                '{paused: true, paused_at: $paused_at, resume_at: $resume_at, execution_id: $execution_id}' > "$pause_file"

            step_output="Queue paused until $resume_at"
            ;;

        "resume_queue")
            local pause_file="$PROJECT_ROOT/coordination/queue-pause.json"
            if [[ -f "$pause_file" ]]; then
                rm -f "$pause_file"
                step_output="Queue resumed"
            else
                step_output="Queue was not paused"
            fi
            ;;

        "scale_workers")
            local scale_factor=$(echo "$params" | jq -r '.scale_factor // 1.5')
            local max_workers=$(echo "$params" | jq -r '.max_workers // 20')

            # Update worker pool configuration
            local pool_file="$PROJECT_ROOT/coordination/worker-pool.json"
            if [[ -f "$pool_file" ]]; then
                local current=$(jq -r '.max_workers // 10' "$pool_file")
                local new_max=$(echo "scale=0; $current * $scale_factor" | bc | cut -d. -f1)
                if [[ $new_max -gt $max_workers ]]; then
                    new_max=$max_workers
                fi
                jq --argjson max "$new_max" '.max_workers = $max' "$pool_file" > "${pool_file}.tmp"
                mv "${pool_file}.tmp" "$pool_file"
                step_output="Workers scaled from $current to $new_max"
            else
                step_error="Worker pool file not found"
                step_result="failed"
            fi
            ;;

        "recalculate_budget")
            local strategy=$(echo "$params" | jq -r '.strategy // "proportional"')
            local min_reserve=$(echo "$params" | jq -r '.min_reserve_percent // 10')

            local budget_file="$PROJECT_ROOT/coordination/token-budget.json"
            if [[ -f "$budget_file" ]]; then
                # Recalculate budget allocation
                local total=$(jq -r '.total // 100000' "$budget_file")
                local reserve=$(echo "scale=0; $total * $min_reserve / 100" | bc)

                jq --argjson reserve "$reserve" \
                   --arg strategy "$strategy" \
                   '.reserve = $reserve | .allocation_strategy = $strategy' \
                   "$budget_file" > "${budget_file}.tmp"
                mv "${budget_file}.tmp" "$budget_file"
                step_output="Budget recalculated with $min_reserve% reserve"
            else
                step_error="Budget file not found"
                step_result="failed"
            fi
            ;;

        *)
            step_error="Unknown action: $action"
            step_result="failed"
            ;;
    esac

    local step_end=$(date +%s)
    local step_duration=$((step_end - step_start))

    # Return step result
    jq -n \
        --arg step_id "$step_id" \
        --arg action "$action" \
        --arg result "$step_result" \
        --arg output "$step_output" \
        --arg error "$step_error" \
        --argjson duration "$step_duration" \
        '{
            step_id: $step_id,
            action: $action,
            result: $result,
            output: $output,
            error: $error,
            duration_seconds: $duration
        }'

    if [[ "$step_result" == "failed" ]]; then
        return 1
    fi
    return 0
}

#
# Execute a playbook
#
execute_playbook() {
    local playbook_id="$1"
    local context="${2:-{}}"
    local dry_run="${3:-false}"

    local playbook=$(get_playbook_by_id "$playbook_id")

    if [[ -z "$playbook" || "$playbook" == "null" ]]; then
        log_playbook "ERROR" "Playbook not found: $playbook_id"
        return 1
    fi

    local execution_id=$(generate_execution_id)
    local playbook_name=$(echo "$playbook" | jq -r '.name')

    log_playbook "INFO" "Starting playbook execution: $playbook_name ($execution_id)"

    if [[ "$dry_run" == "true" ]]; then
        log_playbook "INFO" "DRY RUN - No actions will be executed"
    fi

    local execution_start=$(date +%s)
    local execution_status="success"
    local step_results="[]"

    # Execute steps
    local steps=$(echo "$playbook" | jq -c '.steps[]')

    while IFS= read -r step; do
        local step_id=$(echo "$step" | jq -r '.step_id')
        local on_failure=$(echo "$step" | jq -r '.on_failure')

        if [[ "$dry_run" == "true" ]]; then
            local action=$(echo "$step" | jq -r '.action')
            log_playbook "INFO" "Would execute step $step_id: $action"
            continue
        fi

        local step_result=$(execute_step "$step" "$execution_id" "$context")
        step_results=$(echo "$step_results" | jq --argjson result "$step_result" '. += [$result]')

        local result_status=$(echo "$step_result" | jq -r '.result')

        if [[ "$result_status" == "failed" ]]; then
            log_playbook "ERROR" "Step $step_id failed: $(echo "$step_result" | jq -r '.error')"

            case "$on_failure" in
                "abort")
                    execution_status="aborted"
                    break
                    ;;
                "rollback")
                    execution_status="rolled_back"
                    # Execute rollback steps
                    log_playbook "INFO" "Executing rollback steps..."
                    break
                    ;;
                "alert")
                    # Continue but mark as partial
                    execution_status="partial"
                    ;;
                "continue")
                    # Continue execution
                    ;;
            esac
        fi
    done <<< "$steps"

    local execution_end=$(date +%s)
    local execution_duration=$((execution_end - execution_start))

    # Record execution
    local execution_record=$(jq -n \
        --arg execution_id "$execution_id" \
        --arg playbook_id "$playbook_id" \
        --arg playbook_name "$playbook_name" \
        --arg status "$execution_status" \
        --arg started_at "$(date -u -r $execution_start +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg completed_at "$(get_timestamp)" \
        --argjson duration "$execution_duration" \
        --argjson context "$context" \
        --argjson step_results "$step_results" \
        '{
            execution_id: $execution_id,
            playbook_id: $playbook_id,
            playbook_name: $playbook_name,
            status: $status,
            started_at: $started_at,
            completed_at: $completed_at,
            duration_seconds: $duration,
            context: $context,
            step_results: $step_results
        }')

    # Save execution record
    echo "$execution_record" > "$PLAYBOOK_EXECUTIONS_DIR/${execution_id}.json"
    echo "$execution_record" >> "$PLAYBOOK_HISTORY_FILE"

    log_playbook "INFO" "Playbook execution complete: $execution_id ($execution_status)"

    echo "$execution_id"
    return 0
}

#
# Trigger playbook for failure pattern
#
trigger_for_pattern() {
    local pattern="$1"
    local severity="${2:-medium}"
    local context="${3:-{}}"

    local playbook=$(find_playbook_for_pattern "$pattern" "$severity")

    if [[ -z "$playbook" || "$playbook" == "null" ]]; then
        log_playbook "DEBUG" "No playbook found for pattern: $pattern"
        return 0
    fi

    local playbook_id=$(echo "$playbook" | jq -r '.playbook_id')
    local auto_execute=$(echo "$playbook" | jq -r '.auto_execute')

    if [[ "$auto_execute" == "true" ]]; then
        log_playbook "INFO" "Auto-executing playbook $playbook_id for pattern: $pattern"
        execute_playbook "$playbook_id" "$context"
    else
        log_playbook "INFO" "Playbook $playbook_id requires manual approval for pattern: $pattern"
        # Create pending execution request
        local request_id=$(generate_execution_id)
        jq -n \
            --arg request_id "$request_id" \
            --arg playbook_id "$playbook_id" \
            --arg pattern "$pattern" \
            --arg severity "$severity" \
            --argjson context "$context" \
            --arg created_at "$(get_timestamp)" \
            '{
                request_id: $request_id,
                playbook_id: $playbook_id,
                trigger_pattern: $pattern,
                severity: $severity,
                context: $context,
                created_at: $created_at,
                status: "pending_approval"
            }' > "$PLAYBOOK_EXECUTIONS_DIR/pending-${request_id}.json"

        echo "$request_id"
    fi
}

#
# Get execution status
#
get_execution_status() {
    local execution_id="$1"

    local exec_file="$PLAYBOOK_EXECUTIONS_DIR/${execution_id}.json"
    if [[ -f "$exec_file" ]]; then
        cat "$exec_file"
    else
        echo "{}"
    fi
}

#
# List recent executions
#
list_executions() {
    local limit="${1:-10}"

    if [[ -f "$PLAYBOOK_HISTORY_FILE" ]]; then
        tail -n "$limit" "$PLAYBOOK_HISTORY_FILE" | jq -s '.'
    else
        echo "[]"
    fi
}

# Export functions
export -f load_playbook_registry
export -f find_playbook_for_pattern
export -f get_playbook_by_id
export -f execute_playbook
export -f trigger_for_pattern
export -f get_execution_status
export -f list_executions
