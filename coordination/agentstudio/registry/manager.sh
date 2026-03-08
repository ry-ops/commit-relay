#!/usr/bin/env bash
#
# Agent Registry Manager
# Part of Agentstudio Infrastructure
#
# Provides functions to manage the agent registry including:
# - CRUD operations on agents
# - Status management
# - Metrics tracking
# - Agent discovery
#
# Usage:
#   source coordination/agentstudio/registry/manager.sh
#   list_agents
#   get_agent "development-master"
#   update_agent_status "development-master" "active"

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

readonly REGISTRY_FILE="$SCRIPT_DIR/agents.json"
readonly REGISTRY_LOCK="/tmp/commit-relay-registry.lock"
readonly ACTIVE_DIR="$SCRIPT_DIR/active"
readonly IDLE_DIR="$SCRIPT_DIR/idle"
readonly RETIRED_DIR="$SCRIPT_DIR/retired"
readonly INDICES_DIR="$SCRIPT_DIR/indices"

# Ensure directories exist
mkdir -p "$ACTIVE_DIR" "$IDLE_DIR" "$RETIRED_DIR" "$INDICES_DIR"

#------------------------------------------------------------------------------
# Lock Management
#------------------------------------------------------------------------------

acquire_registry_lock() {
    local max_wait=30
    local wait_count=0

    while [ -f "$REGISTRY_LOCK" ]; do
        sleep 0.1
        wait_count=$((wait_count + 1))
        if [ $wait_count -gt $((max_wait * 10)) ]; then
            echo "ERROR: Could not acquire registry lock" >&2
            return 1
        fi
    done

    echo $$ > "$REGISTRY_LOCK"
}

release_registry_lock() {
    rm -f "$REGISTRY_LOCK"
}

#------------------------------------------------------------------------------
# Read Operations
#------------------------------------------------------------------------------

# List all agents
list_agents() {
    local filter="${1:-all}"  # all, active, idle, retired

    case "$filter" in
        all)
            jq -r '.agents | keys[]' "$REGISTRY_FILE"
            ;;
        active)
            jq -r '.agents | to_entries | map(select(.value.status == "active")) | .[].key' "$REGISTRY_FILE"
            ;;
        idle)
            jq -r '.agents | to_entries | map(select(.value.status == "idle")) | .[].key' "$REGISTRY_FILE"
            ;;
        retired)
            jq -r '.agents | to_entries | map(select(.value.status == "retired")) | .[].key' "$REGISTRY_FILE"
            ;;
        *)
            jq -r ".agents | to_entries | map(select(.value.type == \"$filter\")) | .[].key" "$REGISTRY_FILE"
            ;;
    esac
}

# Get agent by ID
get_agent() {
    local agent_id="$1"

    jq --arg id "$agent_id" '.agents[$id]' "$REGISTRY_FILE"
}

# Get agent status
get_agent_status() {
    local agent_id="$1"

    jq -r --arg id "$agent_id" '.agents[$id].status // "unknown"' "$REGISTRY_FILE"
}

# Get agents by type
get_agents_by_type() {
    local agent_type="$1"

    jq --arg type "$agent_type" '[.agents | to_entries | map(select(.value.type == $type)) | .[].value]' "$REGISTRY_FILE"
}

# Get agents by category
get_agents_by_category() {
    local category="$1"

    jq --arg cat "$category" '[.agents | to_entries | map(select(.value.category == $cat)) | .[].value]' "$REGISTRY_FILE"
}

# Get agent capabilities
get_agent_capabilities() {
    local agent_id="$1"

    jq -r --arg id "$agent_id" '.agents[$id].capabilities[]' "$REGISTRY_FILE"
}

# Get agent integrations
get_agent_integrations() {
    local agent_id="$1"

    jq -r --arg id "$agent_id" '.agents[$id].integrations[]' "$REGISTRY_FILE"
}

# Get agent metrics
get_agent_metrics() {
    local agent_id="$1"

    jq --arg id "$agent_id" '.agents[$id].metrics' "$REGISTRY_FILE"
}

# Search agents by capability
search_by_capability() {
    local capability="$1"

    jq --arg cap "$capability" '[.agents | to_entries | map(select(.value.capabilities | contains([$cap]))) | .[].value]' "$REGISTRY_FILE"
}

#------------------------------------------------------------------------------
# Write Operations
#------------------------------------------------------------------------------

# Update agent status
update_agent_status() {
    local agent_id="$1"
    local new_status="$2"

    acquire_registry_lock || return 1
    trap release_registry_lock EXIT

    local temp_file=$(mktemp)
    jq --arg id "$agent_id" \
       --arg status "$new_status" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.agents[$id].status = $status |
        .agents[$id].updated_at = $timestamp |
        .updated_at = $timestamp' \
       "$REGISTRY_FILE" > "$temp_file"

    mv "$temp_file" "$REGISTRY_FILE"
    release_registry_lock

    # Update index files
    update_status_index "$agent_id" "$new_status"

    echo "Updated $agent_id status to $new_status"
}

# Update agent metrics
update_agent_metrics() {
    local agent_id="$1"
    local metrics_json="$2"

    acquire_registry_lock || return 1
    trap release_registry_lock EXIT

    local temp_file=$(mktemp)
    jq --arg id "$agent_id" \
       --argjson metrics "$metrics_json" \
       --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.agents[$id].metrics = (.agents[$id].metrics + $metrics) |
        .agents[$id].updated_at = $timestamp |
        .updated_at = $timestamp' \
       "$REGISTRY_FILE" > "$temp_file"

    mv "$temp_file" "$REGISTRY_FILE"
    release_registry_lock

    echo "Updated metrics for $agent_id"
}

# Create new agent
create_agent() {
    local agent_json="$1"

    # Validate required fields
    local agent_id=$(echo "$agent_json" | jq -r '.id // empty')
    if [ -z "$agent_id" ]; then
        echo "ERROR: Agent ID is required" >&2
        return 1
    fi

    # Check if agent already exists
    local existing=$(jq -r --arg id "$agent_id" '.agents[$id] // empty' "$REGISTRY_FILE")
    if [ -n "$existing" ]; then
        echo "ERROR: Agent $agent_id already exists" >&2
        return 1
    fi

    acquire_registry_lock || return 1
    trap release_registry_lock EXIT

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Add timestamps if not present
    local enhanced_agent=$(echo "$agent_json" | jq \
        --arg timestamp "$timestamp" \
        '. + {
            created_at: ($timestamp),
            updated_at: ($timestamp),
            status: (.status // "idle")
        }')

    local temp_file=$(mktemp)
    jq --arg id "$agent_id" \
       --argjson agent "$enhanced_agent" \
       --arg timestamp "$timestamp" \
       '.agents[$id] = $agent |
        .updated_at = $timestamp' \
       "$REGISTRY_FILE" > "$temp_file"

    mv "$temp_file" "$REGISTRY_FILE"
    release_registry_lock

    # Update indices
    update_status_index "$agent_id" "idle"

    echo "Created agent: $agent_id"
}

# Update existing agent
update_agent() {
    local agent_id="$1"
    local updates_json="$2"

    # Check if agent exists
    local existing=$(jq -r --arg id "$agent_id" '.agents[$id] // empty' "$REGISTRY_FILE")
    if [ -z "$existing" ]; then
        echo "ERROR: Agent $agent_id not found" >&2
        return 1
    fi

    acquire_registry_lock || return 1
    trap release_registry_lock EXIT

    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local temp_file=$(mktemp)
    jq --arg id "$agent_id" \
       --argjson updates "$updates_json" \
       --arg timestamp "$timestamp" \
       '.agents[$id] = (.agents[$id] + $updates + {updated_at: $timestamp}) |
        .updated_at = $timestamp' \
       "$REGISTRY_FILE" > "$temp_file"

    mv "$temp_file" "$REGISTRY_FILE"
    release_registry_lock

    echo "Updated agent: $agent_id"
}

# Delete agent (moves to retired)
delete_agent() {
    local agent_id="$1"

    update_agent_status "$agent_id" "retired"

    # Archive agent data
    local agent_data=$(get_agent "$agent_id")
    echo "$agent_data" > "$RETIRED_DIR/${agent_id}.json"

    echo "Retired agent: $agent_id"
}

#------------------------------------------------------------------------------
# Index Management
#------------------------------------------------------------------------------

# Update status index
update_status_index() {
    local agent_id="$1"
    local new_status="$2"

    # Remove from old status dirs
    rm -f "$ACTIVE_DIR/$agent_id" "$IDLE_DIR/$agent_id"

    # Add to new status dir
    case "$new_status" in
        active)
            touch "$ACTIVE_DIR/$agent_id"
            ;;
        idle)
            touch "$IDLE_DIR/$agent_id"
            ;;
        retired)
            # Already handled in delete_agent
            ;;
    esac
}

# Rebuild all indices
rebuild_indices() {
    # Clear existing
    rm -f "$ACTIVE_DIR"/* "$IDLE_DIR"/* "$INDICES_DIR"/*

    # Rebuild from registry
    local agents=$(list_agents)

    for agent_id in $agents; do
        local status=$(get_agent_status "$agent_id")
        local agent_type=$(jq -r --arg id "$agent_id" '.agents[$id].type' "$REGISTRY_FILE")
        local category=$(jq -r --arg id "$agent_id" '.agents[$id].category' "$REGISTRY_FILE")

        # Status index
        update_status_index "$agent_id" "$status"

        # Type index
        echo "$agent_id" >> "$INDICES_DIR/by-type-${agent_type}.index"

        # Category index
        echo "$agent_id" >> "$INDICES_DIR/by-category-${category}.index"
    done

    echo "Rebuilt all indices"
}

#------------------------------------------------------------------------------
# Discovery and Routing
#------------------------------------------------------------------------------

# Find agent for capability
find_agent_for_capability() {
    local capability="$1"
    local prefer_active="${2:-true}"

    local agents=$(search_by_capability "$capability")
    local count=$(echo "$agents" | jq 'length')

    if [ "$count" -eq 0 ]; then
        echo ""
        return 1
    fi

    if [ "$prefer_active" = "true" ]; then
        # Return first active agent with capability
        echo "$agents" | jq -r 'map(select(.status == "active")) | .[0].id // empty'
    else
        # Return first agent with capability
        echo "$agents" | jq -r '.[0].id'
    fi
}

# Get all available agents for a task type
get_available_agents() {
    local task_type="$1"

    # Map task type to capability
    local capability=""
    case "$task_type" in
        implementation|feature)
            capability="feature_implementation"
            ;;
        bug|fix)
            capability="bug_fixing"
            ;;
        security|scan)
            capability="security_scanning"
            ;;
        documentation|docs)
            capability="documentation_management"
            ;;
        deploy|deployment)
            capability="deployment_automation"
            ;;
        *)
            capability="$task_type"
            ;;
    esac

    search_by_capability "$capability"
}

#------------------------------------------------------------------------------
# Health and Metrics
#------------------------------------------------------------------------------

# Get registry summary
get_registry_summary() {
    jq '{
        total_agents: (.agents | length),
        active: (.agents | to_entries | map(select(.value.status == "active")) | length),
        idle: (.agents | to_entries | map(select(.value.status == "idle")) | length),
        retired: (.agents | to_entries | map(select(.value.status == "retired")) | length),
        by_type: (.agents | to_entries | group_by(.value.type) | map({key: .[0].value.type, value: length}) | from_entries),
        by_category: (.agents | to_entries | group_by(.value.category) | map({key: .[0].value.category, value: length}) | from_entries),
        last_updated: .updated_at
    }' "$REGISTRY_FILE"
}

# Get agent health
get_agent_health() {
    local agent_id="$1"

    local agent=$(get_agent "$agent_id")
    local status=$(echo "$agent" | jq -r '.status')
    local metrics=$(echo "$agent" | jq '.metrics')

    jq -n \
        --arg agent_id "$agent_id" \
        --arg status "$status" \
        --argjson metrics "$metrics" \
        '{
            agent_id: $agent_id,
            status: $status,
            health: (if $status == "active" then "healthy" elif $status == "idle" then "standby" else "offline" end),
            metrics: $metrics,
            checked_at: (now | todate)
        }'
}

# Get all agent health
get_all_agent_health() {
    local agents=$(list_agents)
    local health_array="[]"

    for agent_id in $agents; do
        local health=$(get_agent_health "$agent_id")
        health_array=$(echo "$health_array" | jq --argjson h "$health" '. + [$h]')
    done

    echo "$health_array"
}

#------------------------------------------------------------------------------
# Template Operations
#------------------------------------------------------------------------------

# Create agent from template
create_agent_from_template() {
    local template_name="$1"
    local agent_id="$2"
    local customizations="${3:-{}}"

    local template_file="$COMMIT_RELAY_HOME/coordination/agentstudio/templates/${template_name}.json"

    if [ ! -f "$template_file" ]; then
        echo "ERROR: Template not found: $template_name" >&2
        return 1
    fi

    local template=$(cat "$template_file")
    local agent_json=$(echo "$template" | jq \
        --arg id "$agent_id" \
        --argjson custom "$customizations" \
        '. + $custom + {id: $id}')

    create_agent "$agent_json"
}

#------------------------------------------------------------------------------
# Export Functions
#------------------------------------------------------------------------------

export -f list_agents
export -f get_agent
export -f get_agent_status
export -f get_agents_by_type
export -f get_agents_by_category
export -f get_agent_capabilities
export -f get_agent_integrations
export -f get_agent_metrics
export -f search_by_capability
export -f update_agent_status
export -f update_agent_metrics
export -f create_agent
export -f update_agent
export -f delete_agent
export -f rebuild_indices
export -f find_agent_for_capability
export -f get_available_agents
export -f get_registry_summary
export -f get_agent_health
export -f get_all_agent_health
export -f create_agent_from_template

#------------------------------------------------------------------------------
# CLI Interface
#------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        list)
            list_agents "${2:-all}"
            ;;
        get)
            get_agent "$2"
            ;;
        status)
            get_agent_status "$2"
            ;;
        set-status)
            update_agent_status "$2" "$3"
            ;;
        metrics)
            get_agent_metrics "$2"
            ;;
        summary)
            get_registry_summary
            ;;
        health)
            if [ -n "${2:-}" ]; then
                get_agent_health "$2"
            else
                get_all_agent_health
            fi
            ;;
        rebuild-indices)
            rebuild_indices
            ;;
        capabilities)
            get_agent_capabilities "$2"
            ;;
        find)
            find_agent_for_capability "$2"
            ;;
        help|*)
            echo "Agent Registry Manager"
            echo ""
            echo "Usage: manager.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  list [filter]            List agents (all, active, idle, retired)"
            echo "  get <agent_id>           Get agent details"
            echo "  status <agent_id>        Get agent status"
            echo "  set-status <id> <status> Set agent status"
            echo "  metrics <agent_id>       Get agent metrics"
            echo "  summary                  Get registry summary"
            echo "  health [agent_id]        Get agent health (all if no ID)"
            echo "  rebuild-indices          Rebuild all indices"
            echo "  capabilities <agent_id>  List agent capabilities"
            echo "  find <capability>        Find agent with capability"
            ;;
    esac
fi
