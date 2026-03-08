#!/usr/bin/env bash
#
# Agent Registration Library
# Part of Q2 Week 21-22: Agent Registry & Catalog
#
# Provides agent registration, lifecycle management, and health tracking
#

set -euo pipefail

# Only set if not already defined
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

# Registry directories (allow override for testing)
REGISTRY_DIR="${REGISTRY_DIR:-coordination/agentstudio/registry}"

# These will be set by init_registry
ACTIVE_DIR="${REGISTRY_DIR}/active"
IDLE_DIR="${REGISTRY_DIR}/idle"
RETIRED_DIR="${REGISTRY_DIR}/retired"
INDEX_DIR="${REGISTRY_DIR}/indices"

# Initialize registry structure
init_registry() {
    # Recalculate paths based on current REGISTRY_DIR
    ACTIVE_DIR="$REGISTRY_DIR/active"
    IDLE_DIR="$REGISTRY_DIR/idle"
    RETIRED_DIR="$REGISTRY_DIR/retired"
    INDEX_DIR="$REGISTRY_DIR/indices"

    # Export for use in other functions
    export ACTIVE_DIR IDLE_DIR RETIRED_DIR INDEX_DIR

    mkdir -p "$ACTIVE_DIR" "$IDLE_DIR" "$RETIRED_DIR" "$INDEX_DIR"

    # Create capability index
    if [[ ! -f "$INDEX_DIR/by-capability.json" ]]; then
        echo '{}' > "$INDEX_DIR/by-capability.json"
    fi

    # Create class index
    if [[ ! -f "$INDEX_DIR/by-class.json" ]]; then
        echo '{}' > "$INDEX_DIR/by-class.json"
    fi

    # Create status index
    if [[ ! -f "$INDEX_DIR/by-status.json" ]]; then
        echo '{"active": [], "idle": [], "busy": [], "error": [], "retired": []}' > "$INDEX_DIR/by-status.json"
    fi
}

#
# Get current timestamp in milliseconds
#
get_timestamp_ms() {
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        # macOS fallback
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

#
# Generate agent ID
#
generate_agent_id() {
    local agent_class="$1"
    local suffix=$(openssl rand -hex 4)
    echo "${agent_class}-${suffix}"
}

#
# Register a new agent
#
# Usage: register_agent <agent_class> <name> <version> <capabilities_json>
#
register_agent() {
    local agent_class="$1"
    local name="$2"
    local version="$3"
    local capabilities_json="${4:-[]}"
    local description="${5:-}"

    init_registry

    # Generate agent ID
    local agent_id=$(generate_agent_id "$agent_class")
    local timestamp=$(get_timestamp_ms)

    # Determine agent type from class
    local agent_type="utility"
    case "$agent_class" in
        *-master|commit-relay)
            agent_type="master"
            ;;
        *-worker)
            agent_type="worker"
            ;;
        critic|learner|problem-generator)
            agent_type="learning"
            ;;
        *-daemon|*-monitor|*-detector|*-aggregator|*-streamer|*-cleanup)
            agent_type="daemon"
            ;;
    esac

    # Create agent registration
    local agent_file="$ACTIVE_DIR/${agent_id}.json"

    cat > "$agent_file" <<EOF
{
  "agent_id": "$agent_id",
  "agent_type": "$agent_type",
  "agent_class": "$agent_class",
  "name": "$name",
  "description": "$description",
  "version": "$version",
  "status": "active",
  "capabilities": $capabilities_json,
  "configuration": {
    "max_concurrent_tasks": 1,
    "timeout_seconds": 300,
    "retry_attempts": 3,
    "priority": "medium",
    "auto_restart": true
  },
  "performance": {
    "tasks_completed": 0,
    "tasks_failed": 0,
    "success_rate": 0.0,
    "average_execution_time_ms": 0,
    "total_tokens_used": 0,
    "uptime_seconds": 0
  },
  "metadata": {
    "owner": "system",
    "tags": [],
    "dependencies": []
  },
  "registered_at": $timestamp,
  "last_seen_at": $timestamp,
  "updated_at": $timestamp,
  "health": {
    "status": "healthy",
    "last_check_at": $timestamp,
    "error_count": 0,
    "consecutive_failures": 0,
    "message": "Agent registered successfully"
  }
}
EOF

    # Update indices
    update_indices "$agent_id" "$agent_file"

    echo "$agent_id"
}

#
# Update agent status
#
# Usage: update_agent_status <agent_id> <new_status>
#
update_agent_status() {
    local agent_id="$1"
    local new_status="$2"

    init_registry

    local agent_file=$(find_agent_file "$agent_id")

    if [[ -z "$agent_file" ]]; then
        echo "Error: Agent $agent_id not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    # Update status and timestamp
    local updated=$(cat "$agent_file" | jq \
        --arg status "$new_status" \
        --arg ts "$timestamp" \
        '.status = $status | .updated_at = ($ts | tonumber) | .last_seen_at = ($ts | tonumber)')

    echo "$updated" > "$agent_file"

    # Move file if status requires it
    local new_dir=""
    case "$new_status" in
        active|busy|starting|stopping|error)
            new_dir="$ACTIVE_DIR"
            ;;
        idle)
            new_dir="$IDLE_DIR"
            ;;
        retired)
            new_dir="$RETIRED_DIR"
            # Add retired_at timestamp
            local retired_updated=$(cat "$agent_file" | jq \
                --arg ts "$timestamp" \
                '.retired_at = ($ts | tonumber)')
            echo "$retired_updated" > "$agent_file"
            ;;
    esac

    if [[ -n "$new_dir" && "$agent_file" != "$new_dir/${agent_id}.json" ]]; then
        mv "$agent_file" "$new_dir/${agent_id}.json"
        agent_file="$new_dir/${agent_id}.json"
    fi

    # Update indices
    update_indices "$agent_id" "$agent_file"
}

#
# Record agent heartbeat
#
# Usage: agent_heartbeat <agent_id>
#
agent_heartbeat() {
    local agent_id="$1"

    init_registry

    local agent_file=$(find_agent_file "$agent_id")

    if [[ -z "$agent_file" ]]; then
        echo "Error: Agent $agent_id not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    # Update last_seen_at
    local updated=$(cat "$agent_file" | jq \
        --arg ts "$timestamp" \
        '.last_seen_at = ($ts | tonumber)')

    echo "$updated" > "$agent_file"
}

#
# Update agent performance metrics
#
# Usage: update_performance <agent_id> <tasks_completed> <tasks_failed> <execution_time_ms> <tokens_used>
#
update_performance() {
    local agent_id="$1"
    local tasks_completed="${2:-0}"
    local tasks_failed="${3:-0}"
    local execution_time_ms="${4:-0}"
    local tokens_used="${5:-0}"

    init_registry

    local agent_file=$(find_agent_file "$agent_id")

    if [[ -z "$agent_file" ]]; then
        echo "Error: Agent $agent_id not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    # Calculate new metrics
    local current_data=$(cat "$agent_file")
    local prev_completed=$(echo "$current_data" | jq -r '.performance.tasks_completed // 0')
    local prev_failed=$(echo "$current_data" | jq -r '.performance.tasks_failed // 0')
    local prev_tokens=$(echo "$current_data" | jq -r '.performance.total_tokens_used // 0')
    local prev_avg_time=$(echo "$current_data" | jq -r '.performance.average_execution_time_ms // 0')

    local new_completed=$((prev_completed + tasks_completed))
    local new_failed=$((prev_failed + tasks_failed))
    local new_tokens=$((prev_tokens + tokens_used))
    local total_tasks=$((new_completed + new_failed))

    local success_rate="0"
    if [[ $total_tasks -gt 0 ]]; then
        success_rate=$(echo "scale=4; $new_completed / $total_tasks" | bc)
    fi

    # Calculate new average execution time
    local avg_time="$execution_time_ms"
    if [[ $prev_completed -gt 0 && $tasks_completed -gt 0 ]]; then
        avg_time=$(echo "scale=2; ($prev_avg_time * $prev_completed + $execution_time_ms * $tasks_completed) / $new_completed" | bc)
    elif [[ $prev_completed -gt 0 ]]; then
        avg_time="$prev_avg_time"
    fi

    # Update performance data
    local updated=$(echo "$current_data" | jq \
        --arg completed "$new_completed" \
        --arg failed "$new_failed" \
        --arg success_rate "$success_rate" \
        --arg avg_time "$avg_time" \
        --arg tokens "$new_tokens" \
        --arg ts "$timestamp" \
        '.performance.tasks_completed = ($completed | tonumber) |
         .performance.tasks_failed = ($failed | tonumber) |
         .performance.success_rate = ($success_rate | tonumber) |
         .performance.average_execution_time_ms = ($avg_time | tonumber) |
         .performance.total_tokens_used = ($tokens | tonumber) |
         .performance.last_task_timestamp = ($ts | tonumber) |
         .updated_at = ($ts | tonumber)')

    echo "$updated" > "$agent_file"
}

#
# Update agent health
#
# Usage: update_health <agent_id> <health_status> <message> <error_count>
#
update_health() {
    local agent_id="$1"
    local health_status="$2"
    local message="${3:-}"
    local error_count="${4:-0}"

    init_registry

    local agent_file=$(find_agent_file "$agent_id")

    if [[ -z "$agent_file" ]]; then
        echo "Error: Agent $agent_id not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    # Calculate consecutive failures
    local current_data=$(cat "$agent_file")
    local prev_status=$(echo "$current_data" | jq -r '.health.status // "unknown"')
    local prev_failures=$(echo "$current_data" | jq -r '.health.consecutive_failures // 0')

    local consecutive_failures="$prev_failures"
    if [[ "$health_status" == "unhealthy" ]]; then
        consecutive_failures=$((prev_failures + 1))
    elif [[ "$health_status" == "healthy" ]]; then
        consecutive_failures=0
    fi

    # Update health data
    local updated=$(echo "$current_data" | jq \
        --arg status "$health_status" \
        --arg msg "$message" \
        --arg errors "$error_count" \
        --arg failures "$consecutive_failures" \
        --arg ts "$timestamp" \
        '.health.status = $status |
         .health.message = $msg |
         .health.error_count = ($errors | tonumber) |
         .health.consecutive_failures = ($failures | tonumber) |
         .health.last_check_at = ($ts | tonumber) |
         .updated_at = ($ts | tonumber)')

    echo "$updated" > "$agent_file"
}

#
# Update agent configuration
#
# Usage: update_configuration <agent_id> <config_json>
#
update_configuration() {
    local agent_id="$1"
    local config_json="$2"

    init_registry

    local agent_file=$(find_agent_file "$agent_id")

    if [[ -z "$agent_file" ]]; then
        echo "Error: Agent $agent_id not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    # Merge configuration
    local updated=$(cat "$agent_file" | jq \
        --argjson config "$config_json" \
        --arg ts "$timestamp" \
        '.configuration = (.configuration + $config) | .updated_at = ($ts | tonumber)')

    echo "$updated" > "$agent_file"
}

#
# Find agent file across all directories
#
find_agent_file() {
    local agent_id="$1"

    # Check active
    if [[ -f "$ACTIVE_DIR/${agent_id}.json" ]]; then
        echo "$ACTIVE_DIR/${agent_id}.json"
        return 0
    fi

    # Check idle
    if [[ -f "$IDLE_DIR/${agent_id}.json" ]]; then
        echo "$IDLE_DIR/${agent_id}.json"
        return 0
    fi

    # Check retired
    if [[ -f "$RETIRED_DIR/${agent_id}.json" ]]; then
        echo "$RETIRED_DIR/${agent_id}.json"
        return 0
    fi

    return 1
}

#
# Get agent by ID
#
get_agent() {
    local agent_id="$1"

    init_registry

    local agent_file=$(find_agent_file "$agent_id")

    if [[ -z "$agent_file" ]]; then
        echo "{\"error\": \"Agent not found: $agent_id\"}"
        return 1
    fi

    cat "$agent_file"
}

#
# Update indices for agent
#
update_indices() {
    local agent_id="$1"
    local agent_file="$2"

    init_registry

    local agent_data=$(cat "$agent_file")
    local agent_class=$(echo "$agent_data" | jq -r '.agent_class')
    local status=$(echo "$agent_data" | jq -r '.status')
    local capabilities=$(echo "$agent_data" | jq -r '.capabilities[].capability_id' 2>/dev/null || echo "")

    # Update class index
    local class_index=$(cat "$INDEX_DIR/by-class.json")
    local class_agents=$(echo "$class_index" | jq -r --arg class "$agent_class" '.[$class] // []')

    # Add agent_id if not already in list
    if ! echo "$class_agents" | jq -e --arg id "$agent_id" 'index($id)' >/dev/null 2>&1; then
        class_index=$(echo "$class_index" | jq \
            --arg class "$agent_class" \
            --arg id "$agent_id" \
            '.[$class] = ((.[$class] // []) + [$id])')
        echo "$class_index" > "$INDEX_DIR/by-class.json"
    fi

    # Update capability index
    if [[ -n "$capabilities" ]]; then
        local cap_index=$(cat "$INDEX_DIR/by-capability.json")

        while IFS= read -r capability; do
            if [[ -n "$capability" ]]; then
                # Add agent_id to capability list
                if ! echo "$cap_index" | jq -e --arg cap "$capability" '.[$cap]' >/dev/null 2>&1; then
                    cap_index=$(echo "$cap_index" | jq --arg cap "$capability" '.[$cap] = []')
                fi

                cap_index=$(echo "$cap_index" | jq \
                    --arg cap "$capability" \
                    --arg id "$agent_id" \
                    '.[$cap] = ((.[$cap] // []) + [$id] | unique)')
            fi
        done <<< "$capabilities"

        echo "$cap_index" > "$INDEX_DIR/by-capability.json"
    fi

    # Update status index
    local status_index=$(cat "$INDEX_DIR/by-status.json")

    # Remove from all status lists
    for s in active idle busy error retired; do
        status_index=$(echo "$status_index" | jq \
            --arg status "$s" \
            --arg id "$agent_id" \
            '.[$status] = (.[$status] // [] | map(select(. != $id)))')
    done

    # Add to appropriate status list
    local index_status="active"
    case "$status" in
        idle) index_status="idle" ;;
        busy) index_status="busy" ;;
        error) index_status="error" ;;
        retired) index_status="retired" ;;
    esac

    status_index=$(echo "$status_index" | jq \
        --arg status "$index_status" \
        --arg id "$agent_id" \
        '.[$status] = ((.[$status] // []) + [$id] | unique)')

    echo "$status_index" > "$INDEX_DIR/by-status.json"
}

#
# Deregister/retire agent
#
deregister_agent() {
    local agent_id="$1"

    update_agent_status "$agent_id" "retired"
}

# Export functions for use in other scripts
export -f init_registry
export -f get_timestamp_ms
export -f generate_agent_id
export -f register_agent
export -f update_agent_status
export -f agent_heartbeat
export -f update_performance
export -f update_health
export -f update_configuration
export -f find_agent_file
export -f get_agent
export -f update_indices
export -f deregister_agent
