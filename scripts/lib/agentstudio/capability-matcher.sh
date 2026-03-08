#!/usr/bin/env bash
#
# Capability Matching System
# Part of Q2 Week 21-22: Agent Registry & Catalog
#
# Advanced capability matching with scoring and ranking
#

set -euo pipefail

# Only set if not already defined
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

# Source catalog library
MATCHER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MATCHER_LIB_DIR/agent-catalog.sh"

#
# Calculate capability match score
#
# Scoring factors:
# - Required capabilities match: 40%
# - Performance (success rate): 30%
# - Availability (active/idle): 15%
# - Health status: 10%
# - Task load: 5%
#
calculate_match_score() {
    local agent_data="$1"
    local required_caps="$2"
    local context="${3:-{}}"  # Optional context for scoring adjustments

    # Extract agent data
    local agent_caps=$(echo "$agent_data" | jq -r '.capabilities[].capability_id')
    local status=$(echo "$agent_data" | jq -r '.status')
    local health=$(echo "$agent_data" | jq -r '.health.status')
    local success_rate=$(echo "$agent_data" | jq -r '.performance.success_rate // 0')
    local tasks_completed=$(echo "$agent_data" | jq -r '.performance.tasks_completed // 0')

    # 1. Capability match score (40 points max)
    local required_count=$(echo "$required_caps" | jq 'length')
    local matched_count=0

    while IFS= read -r req_cap; do
        if [[ -n "$req_cap" ]]; then
            if echo "$agent_caps" | grep -q "^${req_cap}$"; then
                matched_count=$((matched_count + 1))
            fi
        fi
    done <<< "$(echo "$required_caps" | jq -r '.[]')"

    local capability_score=0
    if [[ $required_count -gt 0 ]]; then
        capability_score=$(echo "scale=2; ($matched_count / $required_count) * 40" | bc)
    fi

    # 2. Performance score (30 points max)
    local performance_score=$(echo "scale=2; $success_rate * 30" | bc)

    # Bonus for experience (task count)
    if [[ $tasks_completed -gt 100 ]]; then
        performance_score=$(echo "scale=2; $performance_score + 3" | bc)
    elif [[ $tasks_completed -gt 50 ]]; then
        performance_score=$(echo "scale=2; $performance_score + 2" | bc)
    elif [[ $tasks_completed -gt 10 ]]; then
        performance_score=$(echo "scale=2; $performance_score + 1" | bc)
    fi

    # 3. Availability score (15 points max)
    local availability_score=0
    case "$status" in
        active) availability_score=15 ;;
        idle) availability_score=15 ;;
        busy) availability_score=8 ;;
        starting) availability_score=5 ;;
        *) availability_score=0 ;;
    esac

    # 4. Health score (10 points max)
    local health_score=0
    case "$health" in
        healthy) health_score=10 ;;
        degraded) health_score=5 ;;
        *) health_score=0 ;;
    esac

    # 5. Load score (5 points max) - prefer less loaded agents
    # Simplified: just give max points if not busy
    local load_score=5
    if [[ "$status" == "busy" ]]; then
        load_score=2
    fi

    # Total score
    local total_score=$(echo "scale=2; $capability_score + $performance_score + $availability_score + $health_score + $load_score" | bc)

    echo "$total_score"
}

#
# Rank agents by capability match
#
# Returns scored and ranked list of agents
#
rank_agents() {
    local agents="$1"
    local required_caps="$2"
    local context="${3:-{}}"

    # Score each agent
    local scored_agents="[]"

    echo "$agents" | jq -c '.[]' | while IFS= read -r agent_data; do
        local agent_id=$(echo "$agent_data" | jq -r '.agent_id')
        local score=$(calculate_match_score "$agent_data" "$required_caps" "$context")

        local scored=$(echo "$agent_data" | jq \
            --arg score "$score" \
            '. + {match_score: ($score | tonumber)}')

        echo "$scored"
    done | jq -s 'sort_by(-.match_score)'
}

#
# Find optimal agent for task
#
# Takes required capabilities and context, returns best-matched agent
#
find_optimal_agent() {
    local required_caps="$1"
    local context="${2:-{}}"

    # Get all agents with required capabilities
    local candidates=$(match_capabilities "$required_caps")

    if [[ "$(echo "$candidates" | jq 'length')" -eq 0 ]]; then
        echo "null"
        return 1
    fi

    # Filter to only active/idle and healthy agents
    candidates=$(echo "$candidates" | jq '
        map(select(
            (.status == "active" or .status == "idle") and
            .health.status == "healthy"
        ))')

    if [[ "$(echo "$candidates" | jq 'length')" -eq 0 ]]; then
        # No healthy agents, try degraded
        candidates=$(match_capabilities "$required_caps")
        candidates=$(echo "$candidates" | jq '
            map(select(
                (.status == "active" or .status == "idle") and
                .health.status == "degraded"
            ))')
    fi

    if [[ "$(echo "$candidates" | jq 'length')" -eq 0 ]]; then
        echo "null"
        return 1
    fi

    # Rank candidates
    local ranked=$(rank_agents "$candidates" "$required_caps" "$context")

    # Return top-ranked agent
    echo "$ranked" | jq '.[0]'
}

#
# Match multiple agents for parallel execution
#
# Returns N best agents for a task
#
find_optimal_agents() {
    local required_caps="$1"
    local count="${2:-3}"
    local context="${3:-{}}"

    # Get candidates
    local candidates=$(match_capabilities "$required_caps")

    if [[ "$(echo "$candidates" | jq 'length')" -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    # Filter to healthy agents
    candidates=$(echo "$candidates" | jq '
        map(select(
            (.status == "active" or .status == "idle" or .status == "busy") and
            (.health.status == "healthy" or .health.status == "degraded")
        ))')

    # Rank and take top N
    local ranked=$(rank_agents "$candidates" "$required_caps" "$context")

    echo "$ranked" | jq --arg count "$count" '.[:($count | tonumber)]'
}

#
# Check if agent has capability
#
agent_has_capability() {
    local agent_id="$1"
    local capability_id="$2"

    local agent=$(get_agent "$agent_id")

    if [[ "$agent" == *"error"* ]]; then
        return 1
    fi

    local has_cap=$(echo "$agent" | jq -e \
        --arg cap "$capability_id" \
        '.capabilities[] | select(.capability_id == $cap)' >/dev/null 2>&1 && echo "true" || echo "false")

    [[ "$has_cap" == "true" ]]
}

#
# Get capability details from agent
#
get_agent_capability() {
    local agent_id="$1"
    local capability_id="$2"

    local agent=$(get_agent "$agent_id")

    if [[ "$agent" == *"error"* ]]; then
        echo "null"
        return 1
    fi

    echo "$agent" | jq \
        --arg cap "$capability_id" \
        '.capabilities[] | select(.capability_id == $cap)'
}

#
# Suggest capabilities based on task description
#
# This is a simplified keyword-based suggester
#
suggest_capabilities() {
    local task_description="$1"

    local description_lower=$(echo "$task_description" | tr '[:upper:]' '[:lower:]')
    local suggested="[]"

    # Security keywords
    if echo "$description_lower" | grep -qE "security|vulnerability|scan|cve|audit"; then
        suggested=$(echo "$suggested" | jq '. + ["vulnerability_scanning", "security_audit"]')
    fi

    # Development keywords
    if echo "$description_lower" | grep -qE "implement|develop|code|feature|bug|fix"; then
        suggested=$(echo "$suggested" | jq '. + ["code_implementation", "bug_fixing"]')
    fi

    # Testing keywords
    if echo "$description_lower" | grep -qE "test|testing|qa|quality"; then
        suggested=$(echo "$suggested" | jq '. + ["test_execution", "quality_assurance"]')
    fi

    # Analysis keywords
    if echo "$description_lower" | grep -qE "analyze|analysis|review|examine"; then
        suggested=$(echo "$suggested" | jq '. + ["code_analysis", "code_review"]')
    fi

    # Deployment keywords
    if echo "$description_lower" | grep -qE "deploy|deployment|release|build|ci|cd"; then
        suggested=$(echo "$suggested" | jq '. + ["deployment", "build_automation"]')
    fi

    # Documentation keywords
    if echo "$description_lower" | grep -qE "document|documentation|readme|doc"; then
        suggested=$(echo "$suggested" | jq '. + ["documentation_generation"]')
    fi

    # Orchestration keywords
    if echo "$description_lower" | grep -qE "route|routing|coordinate|orchestrate"; then
        suggested=$(echo "$suggested" | jq '. + ["task_routing", "master_coordination"]')
    fi

    # Remove duplicates
    suggested=$(echo "$suggested" | jq 'unique')

    echo "$suggested"
}

#
# Validate capability match
#
# Checks if agent capabilities satisfy task requirements
#
validate_capability_match() {
    local agent_id="$1"
    local required_caps="$2"

    local agent=$(get_agent "$agent_id")

    if [[ "$agent" == *"error"* ]]; then
        echo '{"valid": false, "reason": "Agent not found"}'
        return 1
    fi

    local agent_cap_ids=$(echo "$agent" | jq -r '[.capabilities[].capability_id]')
    local missing="[]"

    echo "$required_caps" | jq -r '.[]' | while IFS= read -r req_cap; do
        if [[ -n "$req_cap" ]]; then
            local has=$(echo "$agent_cap_ids" | jq -e --arg cap "$req_cap" 'index($cap)' >/dev/null 2>&1 && echo "true" || echo "false")

            if [[ "$has" == "false" ]]; then
                echo "$req_cap"
            fi
        fi
    done | jq -R . | jq -s '.' | jq -r \
        'if length == 0 then
            {"valid": true, "missing_capabilities": []}
        else
            {"valid": false, "missing_capabilities": .}
        end'
}

# Export functions
export -f calculate_match_score
export -f rank_agents
export -f find_optimal_agent
export -f find_optimal_agents
export -f agent_has_capability
export -f get_agent_capability
export -f suggest_capabilities
export -f validate_capability_match
