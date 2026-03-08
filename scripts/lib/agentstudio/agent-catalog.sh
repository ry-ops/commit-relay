#!/usr/bin/env bash
#
# Agent Catalog Library
# Part of Q2 Week 21-22: Agent Registry & Catalog
#
# Provides agent discovery, search, and capability matching
#

set -euo pipefail

# Only set if not already defined
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

# Source registration library
CATALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CATALOG_LIB_DIR/agent-register.sh"

#
# List all agents with optional status filter
#
# Usage: list_agents [status]
#
list_agents() {
    local status_filter="${1:-}"

    init_registry

    local agents="[]"

    # Determine which directories to search
    local search_dirs=()
    case "$status_filter" in
        active|busy|starting|stopping|error)
            search_dirs=("$ACTIVE_DIR")
            ;;
        idle)
            search_dirs=("$IDLE_DIR")
            ;;
        retired)
            search_dirs=("$RETIRED_DIR")
            ;;
        "")
            search_dirs=("$ACTIVE_DIR" "$IDLE_DIR" "$RETIRED_DIR")
            ;;
        *)
            echo "Error: Invalid status filter: $status_filter" >&2
            return 1
            ;;
    esac

    # Collect agents from each directory
    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local dir_agents=$(find "$dir" -name "*.json" -type f 2>/dev/null || echo "")

            if [[ -n "$dir_agents" ]]; then
                while IFS= read -r agent_file; do
                    if [[ -f "$agent_file" ]]; then
                        local agent_data=$(cat "$agent_file")

                        # Apply status filter if specified
                        if [[ -n "$status_filter" ]]; then
                            local agent_status=$(echo "$agent_data" | jq -r '.status')
                            if [[ "$agent_status" != "$status_filter" ]]; then
                                continue
                            fi
                        fi

                        agents=$(echo "$agents" | jq ". + [$agent_data]" 2>/dev/null || echo "$agents")
                    fi
                done <<< "$dir_agents"
            fi
        fi
    done

    echo "$agents"
}

#
# Find agents by class
#
# Usage: find_by_class <agent_class>
#
find_by_class() {
    local agent_class="$1"

    init_registry

    # Use class index for fast lookup
    if [[ -f "$INDEX_DIR/by-class.json" ]]; then
        local agent_ids=$(cat "$INDEX_DIR/by-class.json" | jq -r --arg class "$agent_class" '.[$class] // []')

        # Build array of agents
        local agents_json=""
        while IFS= read -r agent_id; do
            if [[ -n "$agent_id" && "$agent_id" != "null" ]]; then
                local agent_data=$(get_agent "$agent_id" 2>/dev/null || echo "")
                if [[ -n "$agent_data" && "$agent_data" != *"error"* ]]; then
                    agents_json="${agents_json}${agent_data}"$'\n'
                fi
            fi
        done < <(echo "$agent_ids" | jq -r '.[]')

        # Convert to JSON array
        if [[ -n "$agents_json" ]]; then
            echo "$agents_json" | jq -s '.'
        else
            echo "[]"
        fi
    else
        echo "[]"
    fi
}

#
# Find agents by capability
#
# Usage: find_by_capability <capability_id>
#
find_by_capability() {
    local capability_id="$1"

    init_registry

    # Use capability index for fast lookup
    if [[ -f "$INDEX_DIR/by-capability.json" ]]; then
        local agent_ids=$(cat "$INDEX_DIR/by-capability.json" | jq -r --arg cap "$capability_id" '.[$cap] // []')

        # Build array of agents
        local agents_json=""
        while IFS= read -r agent_id; do
            if [[ -n "$agent_id" && "$agent_id" != "null" ]]; then
                local agent_data=$(get_agent "$agent_id" 2>/dev/null || echo "")
                if [[ -n "$agent_data" && "$agent_data" != *"error"* ]]; then
                    agents_json="${agents_json}${agent_data}"$'\n'
                fi
            fi
        done < <(echo "$agent_ids" | jq -r '.[]')

        # Convert to JSON array
        if [[ -n "$agents_json" ]]; then
            echo "$agents_json" | jq -s '.'
        else
            echo "[]"
        fi
    else
        echo "[]"
    fi
}

#
# Search agents by multiple criteria
#
# Usage: search_agents <criteria_json>
# Example: search_agents '{"status": "active", "agent_type": "master"}'
#
search_agents() {
    local criteria="$1"

    # Get all agents
    local all_agents=$(list_agents)

    # Apply filters from criteria
    local filtered="$all_agents"

    # Status filter
    local status=$(echo "$criteria" | jq -r '.status // empty')
    if [[ -n "$status" ]]; then
        filtered=$(echo "$filtered" | jq --arg status "$status" 'map(select(.status == $status))')
    fi

    # Agent type filter
    local agent_type=$(echo "$criteria" | jq -r '.agent_type // empty')
    if [[ -n "$agent_type" ]]; then
        filtered=$(echo "$filtered" | jq --arg type "$agent_type" 'map(select(.agent_type == $type))')
    fi

    # Agent class filter
    local agent_class=$(echo "$criteria" | jq -r '.agent_class // empty')
    if [[ -n "$agent_class" ]]; then
        filtered=$(echo "$filtered" | jq --arg class "$agent_class" 'map(select(.agent_class == $class))')
    fi

    # Health status filter
    local health_status=$(echo "$criteria" | jq -r '.health_status // empty')
    if [[ -n "$health_status" ]]; then
        filtered=$(echo "$filtered" | jq --arg health "$health_status" 'map(select(.health.status == $health))')
    fi

    # Tags filter (any match)
    local tags=$(echo "$criteria" | jq -r '.tags // empty')
    if [[ -n "$tags" && "$tags" != "null" ]]; then
        filtered=$(echo "$filtered" | jq --argjson tags "$tags" 'map(select(.metadata.tags as $agent_tags | $tags | map(. as $tag | $agent_tags | index($tag)) | any))')
    fi

    # Minimum success rate filter
    local min_success_rate=$(echo "$criteria" | jq -r '.min_success_rate // empty')
    if [[ -n "$min_success_rate" ]]; then
        filtered=$(echo "$filtered" | jq --arg rate "$min_success_rate" 'map(select(.performance.success_rate >= ($rate | tonumber)))')
    fi

    echo "$filtered"
}

#
# Find best agent for capability (by performance)
#
# Usage: find_best_for_capability <capability_id>
#
find_best_for_capability() {
    local capability_id="$1"

    # Find all agents with this capability
    local agents=$(find_by_capability "$capability_id")

    # Filter to only active/healthy agents
    agents=$(echo "$agents" | jq 'map(select(.status == "active" or .status == "idle") | select(.health.status == "healthy"))')

    # Sort by success rate (desc) then by task count (desc)
    local best=$(echo "$agents" | jq 'sort_by(-.performance.success_rate, -.performance.tasks_completed) | .[0] // null')

    echo "$best"
}

#
# Match agents to required capabilities
#
# Usage: match_capabilities <required_capabilities_json>
# Example: match_capabilities '["task_routing", "code_analysis"]'
#
match_capabilities() {
    local required_caps="$1"

    local all_agents=$(list_agents "active")

    # Filter agents that have ALL required capabilities
    local matched=$(echo "$all_agents" | jq --argjson required "$required_caps" '
        map(
            select(
                .capabilities as $agent_caps |
                $required |
                all(. as $req_cap | $agent_caps | map(.capability_id) | index($req_cap))
            )
        )')

    echo "$matched"
}

#
# Get agent statistics summary
#
get_catalog_stats() {
    init_registry

    local all_agents=$(list_agents)

    local stats=$(echo "$all_agents" | jq '{
        total_agents: length,
        by_type: (group_by(.agent_type) | map({
            type: .[0].agent_type,
            count: length
        })),
        by_status: (group_by(.status) | map({
            status: .[0].status,
            count: length
        })),
        by_health: (group_by(.health.status) | map({
            health: .[0].health.status,
            count: length
        })),
        total_tasks_completed: ([.[].performance.tasks_completed] | add // 0),
        total_tasks_failed: ([.[].performance.tasks_failed] | add // 0),
        overall_success_rate: (
            ([.[].performance.tasks_completed] | add // 0) /
            (([.[].performance.tasks_completed] | add // 0) + ([.[].performance.tasks_failed] | add // 0))
        ),
        total_tokens_used: ([.[].performance.total_tokens_used] | add // 0)
    }')

    echo "$stats"
}

#
# List all unique capabilities in catalog
#
list_all_capabilities() {
    init_registry

    if [[ -f "$INDEX_DIR/by-capability.json" ]]; then
        cat "$INDEX_DIR/by-capability.json" | jq -r 'keys[]' | sort
    else
        echo ""
    fi
}

#
# List all agent classes in catalog
#
list_all_classes() {
    init_registry

    if [[ -f "$INDEX_DIR/by-class.json" ]]; then
        cat "$INDEX_DIR/by-class.json" | jq -r 'keys[]' | sort
    else
        echo ""
    fi
}

#
# Export agent catalog to JSON
#
export_catalog() {
    local output_file="${1:-coordination/agentstudio/catalog-export.json}"

    local all_agents=$(list_agents)
    local stats=$(get_catalog_stats)
    local capabilities=$(list_all_capabilities | jq -R . | jq -s .)
    local classes=$(list_all_classes | jq -R . | jq -s .)

    local catalog=$(jq -n \
        --argjson agents "$all_agents" \
        --argjson stats "$stats" \
        --argjson capabilities "$capabilities" \
        --argjson classes "$classes" \
        '{
            exported_at: (now * 1000 | floor),
            version: "1.0.0",
            statistics: $stats,
            capabilities: $capabilities,
            classes: $classes,
            agents: $agents
        }')

    echo "$catalog" > "$output_file"
    echo "$output_file"
}

#
# Find stale agents (not seen recently)
#
# Usage: find_stale_agents <max_age_seconds>
#
find_stale_agents() {
    local max_age_seconds="${1:-3600}"  # Default 1 hour

    local all_agents=$(list_agents)
    local now=$(get_timestamp_ms)
    local max_age_ms=$((max_age_seconds * 1000))

    local stale=$(echo "$all_agents" | jq --arg now "$now" --arg max_age "$max_age_ms" '
        map(
            select(
                .last_seen_at as $last_seen |
                ($now | tonumber) - ($last_seen | tonumber) > ($max_age | tonumber)
            )
        )')

    echo "$stale"
}

# Export functions
export -f list_agents
export -f find_by_class
export -f find_by_capability
export -f search_agents
export -f find_best_for_capability
export -f match_capabilities
export -f get_catalog_stats
export -f list_all_capabilities
export -f list_all_classes
export -f export_catalog
export -f find_stale_agents
