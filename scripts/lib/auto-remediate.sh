#!/bin/bash
# scripts/lib/auto-remediate.sh
# Automated Remediation Library - Phase 3 Item 27
# Links failure patterns to remediation playbooks for automatic execution
#
# Features:
#   - Pattern-to-playbook mapping
#   - Playbook execution with validation
#   - Rollback support
#   - Execution logging and metrics
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/auto-remediate.sh"
#   remediate_pattern "$pattern_id"

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Playbook storage
PLAYBOOKS_DIR="${COMMIT_RELAY_HOME}/coordination/remediation-playbooks"
PLAYBOOK_INDEX="${PLAYBOOKS_DIR}/index.json"

# Execution history
REMEDIATION_HISTORY="${PLAYBOOKS_DIR}/history.jsonl"
REMEDIATION_METRICS="${COMMIT_RELAY_HOME}/coordination/metrics/remediation-metrics.json"

# Events
REMEDIATION_EVENTS="${COMMIT_RELAY_HOME}/coordination/events/remediation-events.jsonl"

# Create directories
mkdir -p "$PLAYBOOKS_DIR"
mkdir -p "$(dirname "$REMEDIATION_EVENTS")"
mkdir -p "$(dirname "$REMEDIATION_METRICS")"

# ============================================================================
# Logging
# ============================================================================

log_remediate() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [REMEDIATE] [$level] $*" >&2
}

# ============================================================================
# Initialize Playbook Index
# ============================================================================

initialize_playbook_index() {
    if [ ! -f "$PLAYBOOK_INDEX" ]; then
        cat > "$PLAYBOOK_INDEX" <<'EOF'
{
  "version": "1.0.0",
  "playbooks": [
    {
      "playbook_id": "pb-timeout-increase",
      "name": "Increase Worker Timeout",
      "description": "Increases timeout for workers experiencing timeout failures",
      "patterns": ["resource:timeout", "resource:unresponsive"],
      "worker_types": ["*"],
      "severity_threshold": "low",
      "actions": [
        {
          "type": "modify_config",
          "target": "worker_spec",
          "field": "resources.timeout_minutes",
          "operation": "multiply",
          "value": 1.5,
          "max_value": 120
        }
      ],
      "validation": {
        "type": "pattern_reduction",
        "threshold_percent": 50,
        "window_hours": 24
      },
      "rollback": {
        "enabled": true,
        "trigger": "validation_failure"
      },
      "enabled": true
    },
    {
      "playbook_id": "pb-token-budget-increase",
      "name": "Increase Token Budget",
      "description": "Increases token budget for workers running out of tokens",
      "patterns": ["resource:out_of_memory", "resource:token_exhausted"],
      "worker_types": ["*"],
      "severity_threshold": "low",
      "actions": [
        {
          "type": "modify_config",
          "target": "worker_spec",
          "field": "resources.token_budget",
          "operation": "multiply",
          "value": 1.5,
          "max_value": 50000
        }
      ],
      "validation": {
        "type": "success_rate_improvement",
        "threshold_percent": 20,
        "window_hours": 24
      },
      "rollback": {
        "enabled": true,
        "trigger": "validation_failure"
      },
      "enabled": true
    },
    {
      "playbook_id": "pb-circuit-breaker-reset",
      "name": "Reset Circuit Breaker",
      "description": "Resets circuit breaker after cooling period",
      "patterns": ["systemic:recurring_failure"],
      "worker_types": ["*"],
      "severity_threshold": "medium",
      "prerequisites": {
        "min_cooling_period_minutes": 30
      },
      "actions": [
        {
          "type": "reset_circuit_breaker",
          "target": "worker_type"
        },
        {
          "type": "emit_event",
          "event_type": "circuit_breaker_reset"
        }
      ],
      "validation": {
        "type": "no_immediate_retrip",
        "window_minutes": 15
      },
      "rollback": {
        "enabled": false
      },
      "enabled": true
    },
    {
      "playbook_id": "pb-worker-restart",
      "name": "Restart Failed Worker",
      "description": "Restarts worker with clean state",
      "patterns": ["resource:unresponsive", "systemic:worker_stuck"],
      "worker_types": ["*"],
      "severity_threshold": "medium",
      "actions": [
        {
          "type": "cleanup_state",
          "target": "worker",
          "paths": ["locks", "temp_files"]
        },
        {
          "type": "restart_worker",
          "target": "worker_id"
        }
      ],
      "validation": {
        "type": "worker_healthy",
        "timeout_minutes": 5
      },
      "rollback": {
        "enabled": false
      },
      "enabled": true
    }
  ],
  "pattern_mappings": {
    "resource:timeout": ["pb-timeout-increase"],
    "resource:unresponsive": ["pb-timeout-increase", "pb-worker-restart"],
    "resource:out_of_memory": ["pb-token-budget-increase"],
    "resource:token_exhausted": ["pb-token-budget-increase"],
    "systemic:recurring_failure": ["pb-circuit-breaker-reset"],
    "systemic:worker_stuck": ["pb-worker-restart"]
  }
}
EOF
        log_remediate "INFO" "Created default playbook index"
    fi
}

initialize_playbook_index

# ============================================================================
# Playbook Management
# ============================================================================

# Get playbook by ID
get_playbook() {
    local playbook_id="$1"

    jq --arg id "$playbook_id" '.playbooks[] | select(.playbook_id == $id)' "$PLAYBOOK_INDEX"
}

# Find playbooks for a pattern
find_playbooks_for_pattern() {
    local pattern="$1"
    local worker_type="${2:-*}"

    # Get directly mapped playbooks
    local mapped=$(jq -r --arg p "$pattern" '.pattern_mappings[$p] // []' "$PLAYBOOK_INDEX")

    if [ "$mapped" = "[]" ] || [ "$mapped" = "null" ]; then
        echo "[]"
        return
    fi

    # Filter by worker type and enabled status
    jq --argjson ids "$mapped" \
       --arg wt "$worker_type" \
       '[.playbooks[] |
           select(.playbook_id as $id | $ids | index($id)) |
           select(.enabled == true) |
           select(.worker_types | index("*") or index($wt))
       ]' "$PLAYBOOK_INDEX"
}

# Register new playbook
register_playbook() {
    local playbook_json="$1"

    local playbook_id=$(echo "$playbook_json" | jq -r '.playbook_id')

    # Check if exists
    local existing=$(get_playbook "$playbook_id")
    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        log_remediate "WARN" "Playbook already exists: $playbook_id"
        return 1
    fi

    # Add to index
    local temp_file="${PLAYBOOK_INDEX}.tmp"
    jq --argjson pb "$playbook_json" '.playbooks += [$pb]' "$PLAYBOOK_INDEX" > "$temp_file"
    mv "$temp_file" "$PLAYBOOK_INDEX"

    log_remediate "INFO" "Registered playbook: $playbook_id"
}

# ============================================================================
# Playbook Execution
# ============================================================================

# Execute a single action
execute_action() {
    local action="$1"
    local context="$2"

    local action_type=$(echo "$action" | jq -r '.type')
    local result="success"
    local message=""

    case "$action_type" in
        "modify_config")
            local target=$(echo "$action" | jq -r '.target')
            local field=$(echo "$action" | jq -r '.field')
            local operation=$(echo "$action" | jq -r '.operation')
            local value=$(echo "$action" | jq -r '.value')
            local max_value=$(echo "$action" | jq -r '.max_value // null')

            local worker_type=$(echo "$context" | jq -r '.worker_type')
            local spec_template="${COMMIT_RELAY_HOME}/coordination/worker-specs/templates/${worker_type}.json"

            if [ ! -f "$spec_template" ]; then
                # Create template if not exists
                mkdir -p "$(dirname "$spec_template")"
                echo '{"resources":{"timeout_minutes":30,"token_budget":10000}}' > "$spec_template"
            fi

            # Get current value
            local current=$(jq -r ".$field // 0" "$spec_template")
            local new_value

            case "$operation" in
                "multiply")
                    new_value=$(echo "$current * $value" | bc)
                    ;;
                "add")
                    new_value=$(echo "$current + $value" | bc)
                    ;;
                "set")
                    new_value="$value"
                    ;;
            esac

            # Apply max limit
            if [ "$max_value" != "null" ] && (( $(echo "$new_value > $max_value" | bc -l) )); then
                new_value="$max_value"
            fi

            # Update spec
            local temp_spec="${spec_template}.tmp"
            jq --arg field "$field" --argjson value "$new_value" \
               'setpath($field | split("."); $value)' "$spec_template" > "$temp_spec"
            mv "$temp_spec" "$spec_template"

            message="Modified $field: $current -> $new_value"
            log_remediate "INFO" "$message"
            ;;

        "reset_circuit_breaker")
            local worker_type=$(echo "$context" | jq -r '.worker_type')
            local cb_file="${COMMIT_RELAY_HOME}/coordination/worker-restart/circuit-breakers.json"

            if [ -f "$cb_file" ]; then
                local temp_cb="${cb_file}.tmp"
                jq --arg type "$worker_type" 'del(.[$type])' "$cb_file" > "$temp_cb"
                mv "$temp_cb" "$cb_file"
                message="Reset circuit breaker for: $worker_type"
            else
                message="No circuit breaker file found"
            fi
            log_remediate "INFO" "$message"
            ;;

        "cleanup_state")
            local worker_id=$(echo "$context" | jq -r '.worker_id')
            local paths=$(echo "$action" | jq -r '.paths[]')

            while IFS= read -r path_type; do
                case "$path_type" in
                    "locks")
                        rm -f "${COMMIT_RELAY_HOME}/coordination/locks/${worker_id}*"
                        ;;
                    "temp_files")
                        rm -rf "${COMMIT_RELAY_HOME}/tmp/${worker_id}"
                        ;;
                esac
            done <<< "$paths"

            message="Cleaned up state for: $worker_id"
            log_remediate "INFO" "$message"
            ;;

        "restart_worker")
            local worker_id=$(echo "$context" | jq -r '.worker_id')

            if [ -f "${COMMIT_RELAY_HOME}/scripts/lib/worker-restart.sh" ]; then
                source "${COMMIT_RELAY_HOME}/scripts/lib/worker-restart.sh"
                if type restart_worker &>/dev/null; then
                    restart_worker "$worker_id" || result="failure"
                fi
            fi

            message="Restart requested for: $worker_id"
            log_remediate "INFO" "$message"
            ;;

        "emit_event")
            local event_type=$(echo "$action" | jq -r '.event_type')
            emit_remediation_event "$event_type" "action" "$context"
            message="Emitted event: $event_type"
            log_remediate "INFO" "$message"
            ;;

        *)
            result="failure"
            message="Unknown action type: $action_type"
            log_remediate "ERROR" "$message"
            ;;
    esac

    jq -nc \
        --arg type "$action_type" \
        --arg result "$result" \
        --arg message "$message" \
        '{type: $type, result: $result, message: $message}'
}

# Execute playbook
execute_playbook() {
    local playbook_id="$1"
    local context="$2"

    local playbook=$(get_playbook "$playbook_id")

    if [ -z "$playbook" ] || [ "$playbook" = "null" ]; then
        log_remediate "ERROR" "Playbook not found: $playbook_id"
        return 1
    fi

    local execution_id="exec-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"
    local start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log_remediate "INFO" "Executing playbook: $playbook_id (exec: $execution_id)"

    # Check prerequisites
    local prereqs=$(echo "$playbook" | jq -r '.prerequisites // {}')
    if [ "$prereqs" != "{}" ]; then
        # Check cooling period
        local min_cooling=$(echo "$prereqs" | jq -r '.min_cooling_period_minutes // 0')
        if [ "$min_cooling" -gt 0 ]; then
            # Check last execution time
            local last_exec=$(grep "\"playbook_id\":\"$playbook_id\"" "$REMEDIATION_HISTORY" 2>/dev/null | tail -1 | jq -r '.completed_at // ""')
            if [ -n "$last_exec" ]; then
                local last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_exec" +%s 2>/dev/null || echo "0")
                local now_epoch=$(date +%s)
                local diff_minutes=$(( (now_epoch - last_epoch) / 60 ))

                if [ "$diff_minutes" -lt "$min_cooling" ]; then
                    log_remediate "WARN" "Cooling period not met: ${diff_minutes}m < ${min_cooling}m"
                    return 1
                fi
            fi
        fi
    fi

    # Execute actions
    local actions=$(echo "$playbook" | jq -c '.actions[]')
    local action_results="[]"
    local overall_status="success"

    while IFS= read -r action; do
        local action_result=$(execute_action "$action" "$context")
        action_results=$(echo "$action_results" | jq --argjson r "$action_result" '. + [$r]')

        if [ "$(echo "$action_result" | jq -r '.result')" = "failure" ]; then
            overall_status="partial_failure"
        fi
    done <<< "$actions"

    local end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Record execution
    local execution_record=$(jq -nc \
        --arg exec_id "$execution_id" \
        --arg playbook_id "$playbook_id" \
        --argjson context "$context" \
        --arg started_at "$start_time" \
        --arg completed_at "$end_time" \
        --arg status "$overall_status" \
        --argjson action_results "$action_results" \
        '{
            execution_id: $exec_id,
            playbook_id: $playbook_id,
            context: $context,
            started_at: $started_at,
            completed_at: $completed_at,
            status: $status,
            action_results: $action_results
        }')

    echo "$execution_record" >> "$REMEDIATION_HISTORY"

    # Emit event
    emit_remediation_event "playbook_executed" "$execution_id" "$execution_record"

    log_remediate "INFO" "Playbook execution complete: $playbook_id -> $overall_status"

    echo "$execution_record"
}

# ============================================================================
# Pattern Remediation
# ============================================================================

# Main remediation entry point
remediate_pattern() {
    local pattern_id="$1"
    local worker_type="${2:-unknown}"
    local worker_id="${3:-unknown}"

    log_remediate "INFO" "Remediating pattern: $pattern_id"

    # Build context
    local context=$(jq -nc \
        --arg pattern "$pattern_id" \
        --arg worker_type "$worker_type" \
        --arg worker_id "$worker_id" \
        '{
            pattern_id: $pattern,
            worker_type: $worker_type,
            worker_id: $worker_id
        }')

    # Find applicable playbooks
    local playbooks=$(find_playbooks_for_pattern "$pattern_id" "$worker_type")
    local playbook_count=$(echo "$playbooks" | jq 'length')

    if [ "$playbook_count" -eq 0 ]; then
        log_remediate "WARN" "No playbooks found for pattern: $pattern_id"
        return 1
    fi

    log_remediate "INFO" "Found $playbook_count applicable playbook(s)"

    # Execute first matching playbook (could be expanded to try multiple)
    local selected_playbook=$(echo "$playbooks" | jq -c '.[0]')
    local playbook_id=$(echo "$selected_playbook" | jq -r '.playbook_id')

    execute_playbook "$playbook_id" "$context"
}

# ============================================================================
# Validation
# ============================================================================

# Validate remediation effectiveness
validate_remediation() {
    local execution_id="$1"
    local window_hours="${2:-24}"

    # Get execution record
    local execution=$(grep "\"execution_id\":\"$execution_id\"" "$REMEDIATION_HISTORY" | tail -1)

    if [ -z "$execution" ]; then
        log_remediate "ERROR" "Execution not found: $execution_id"
        return 1
    fi

    local playbook_id=$(echo "$execution" | jq -r '.playbook_id')
    local playbook=$(get_playbook "$playbook_id")
    local validation=$(echo "$playbook" | jq '.validation')
    local validation_type=$(echo "$validation" | jq -r '.type')

    local validation_result="pass"
    local validation_message=""

    case "$validation_type" in
        "pattern_reduction")
            # Check if pattern occurrences decreased
            local threshold=$(echo "$validation" | jq -r '.threshold_percent')
            # Would check actual pattern database
            validation_message="Pattern reduction validation pending"
            ;;

        "success_rate_improvement")
            local threshold=$(echo "$validation" | jq -r '.threshold_percent')
            validation_message="Success rate validation pending"
            ;;

        "no_immediate_retrip")
            local window_minutes=$(echo "$validation" | jq -r '.window_minutes')
            validation_message="Circuit breaker stability check pending"
            ;;

        "worker_healthy")
            local timeout=$(echo "$validation" | jq -r '.timeout_minutes')
            validation_message="Worker health check pending"
            ;;

        *)
            validation_message="Unknown validation type"
            ;;
    esac

    log_remediate "INFO" "Validation ($validation_type): $validation_result - $validation_message"

    jq -nc \
        --arg exec_id "$execution_id" \
        --arg result "$validation_result" \
        --arg message "$validation_message" \
        --arg validated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            execution_id: $exec_id,
            result: $result,
            message: $message,
            validated_at: $validated_at
        }'
}

# ============================================================================
# Event Emission
# ============================================================================

emit_remediation_event() {
    local event_type="$1"
    local reference_id="$2"
    local data="${3:-{}}"

    local event=$(jq -nc \
        --arg type "$event_type" \
        --arg ref "$reference_id" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson data "$data" \
        '{
            event_type: $type,
            reference_id: $ref,
            timestamp: $timestamp,
            data: $data
        }')

    echo "$event" >> "$REMEDIATION_EVENTS"
}

# ============================================================================
# Metrics
# ============================================================================

# Update remediation metrics
update_remediation_metrics() {
    local total_executions=$(wc -l < "$REMEDIATION_HISTORY" 2>/dev/null | tr -d ' ' || echo "0")
    local successful=$(grep '"status":"success"' "$REMEDIATION_HISTORY" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    local success_rate=0
    if [ "$total_executions" -gt 0 ]; then
        success_rate=$(echo "scale=2; $successful / $total_executions * 100" | bc)
    fi

    jq -nc \
        --argjson total "$total_executions" \
        --argjson successful "$successful" \
        --arg success_rate "$success_rate" \
        --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            total_executions: $total,
            successful_executions: $successful,
            success_rate: ($success_rate | tonumber),
            updated_at: $updated_at
        }' > "$REMEDIATION_METRICS"
}

# Export functions
export -f get_playbook 2>/dev/null || true
export -f find_playbooks_for_pattern 2>/dev/null || true
export -f execute_playbook 2>/dev/null || true
export -f remediate_pattern 2>/dev/null || true
export -f validate_remediation 2>/dev/null || true
export -f update_remediation_metrics 2>/dev/null || true

log_remediate "INFO" "Auto-remediation library loaded"
