#!/bin/bash
# Multi-Step Planning with Replanning
# Phase 5 Item #57: Re-evaluate plan on step failure, adjust remaining steps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Plan directory
PLANS_DIR="$COMMIT_RELAY_HOME/coordination/plans"
mkdir -p "$PLANS_DIR"

# Create a multi-step plan
create_plan() {
    local task_id="$1"
    local description="$2"
    local steps="$3"

    local plan_id="plan-${task_id}-$(date +%s)"
    local plan_file="$PLANS_DIR/${plan_id}.json"

    jq -n \
        --arg plan_id "$plan_id" \
        --arg task_id "$task_id" \
        --arg description "$description" \
        --argjson steps "$steps" \
        --arg created "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            plan_id: $plan_id,
            task_id: $task_id,
            description: $description,
            status: "active",
            version: 1,
            created_at: $created,
            steps: $steps,
            current_step: 0,
            history: []
        }' > "$plan_file"

    echo "$plan_id"
}

# Execute next step
execute_step() {
    local plan_id="$1"
    local plan_file="$PLANS_DIR/${plan_id}.json"

    if [ ! -f "$plan_file" ]; then
        log_error "Plan not found: $plan_id"
        return 1
    fi

    local current=$(jq -r '.current_step' "$plan_file")
    local total=$(jq '.steps | length' "$plan_file")

    if [ "$current" -ge "$total" ]; then
        log_info "Plan complete"
        jq '.status = "completed"' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
        return 0
    fi

    local step=$(jq ".steps[$current]" "$plan_file")
    log_info "Executing step $((current + 1))/$total: $(echo "$step" | jq -r '.action')"

    echo "$step"
}

# Report step result and trigger replanning if needed
report_step_result() {
    local plan_id="$1"
    local success="$2"
    local result="${3:-}"

    local plan_file="$PLANS_DIR/${plan_id}.json"

    if [ ! -f "$plan_file" ]; then
        log_error "Plan not found: $plan_id"
        return 1
    fi

    local current=$(jq -r '.current_step' "$plan_file")
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Record result in history
    local history_entry=$(jq -n \
        --argjson step "$current" \
        --argjson success "$success" \
        --arg result "$result" \
        --arg ts "$timestamp" \
        '{step: $step, success: $success, result: $result, timestamp: $ts}')

    jq --argjson entry "$history_entry" '.history += [$entry]' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"

    if [ "$success" = "true" ]; then
        # Advance to next step
        jq '.current_step += 1' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
        log_info "Step completed successfully"
    else
        # Trigger replanning
        log_warn "Step failed, initiating replanning..."
        replan "$plan_id" "$result"
    fi
}

# Replan after failure
replan() {
    local plan_id="$1"
    local failure_reason="${2:-unknown}"

    local plan_file="$PLANS_DIR/${plan_id}.json"
    local current=$(jq -r '.current_step' "$plan_file")
    local version=$(jq -r '.version' "$plan_file")

    log_info "Replanning from step $current due to: $failure_reason"

    # Get remaining steps
    local remaining=$(jq ".steps[$current:]" "$plan_file")
    local remaining_count=$(echo "$remaining" | jq 'length')

    if [ "$remaining_count" -le 1 ]; then
        log_warn "No steps remaining to replan, marking as failed"
        jq '.status = "failed"' "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"
        return 1
    fi

    # Generate alternative approach for failed step
    local failed_step=$(jq ".steps[$current]" "$plan_file")
    local failed_action=$(echo "$failed_step" | jq -r '.action')

    # Create retry step with different approach
    local retry_step=$(echo "$failed_step" | jq \
        --arg reason "$failure_reason" \
        '. + {
            retry: true,
            previous_failure: $reason,
            alternative_approach: "retry_with_fallback"
        }')

    # Update plan with retry
    jq --argjson retry "$retry_step" --argjson idx "$current" \
        '.steps[$idx] = $retry | .version += 1 | .replanned_at = now | todate' \
        "$plan_file" > "${plan_file}.tmp" && mv "${plan_file}.tmp" "$plan_file"

    log_info "Plan updated to version $((version + 1)) with retry strategy"
}

# Get plan status
get_plan_status() {
    local plan_id="$1"
    local plan_file="$PLANS_DIR/${plan_id}.json"

    if [ ! -f "$plan_file" ]; then
        echo '{"error": "Plan not found"}'
        return 1
    fi

    jq '{
        plan_id: .plan_id,
        status: .status,
        current_step: .current_step,
        total_steps: (.steps | length),
        version: .version,
        success_rate: (if (.history | length) > 0 then ([.history[] | select(.success == true)] | length) / (.history | length) * 100 else 0 end)
    }' "$plan_file"
}

# Export functions
export -f create_plan
export -f execute_step
export -f report_step_result
export -f replan
export -f get_plan_status

# CLI
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        create)
            create_plan "$2" "$3" "$4"
            ;;
        execute)
            execute_step "$2"
            ;;
        report)
            report_step_result "$2" "$3" "${4:-}"
            ;;
        replan)
            replan "$2" "${3:-manual}"
            ;;
        status)
            get_plan_status "$2"
            ;;
        *)
            echo "Multi-Step Planner with Replanning"
            echo "Usage: multi-step-planner.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  create <task_id> <description> <steps_json>"
            echo "  execute <plan_id>"
            echo "  report <plan_id> <success:bool> [result]"
            echo "  replan <plan_id> [reason]"
            echo "  status <plan_id>"
            ;;
    esac
fi
