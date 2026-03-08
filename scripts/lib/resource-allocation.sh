#!/bin/bash
# scripts/lib/resource-allocation.sh
# Context-Aware Resource Allocation - Phase 4 Item 24
#
# Purpose:
# - Dynamic token budget based on task complexity
# - Analyze task description to estimate resource needs
# - Adjust allocations based on historical performance
# - Prevent over/under-allocation
#
# Usage:
#   source scripts/lib/resource-allocation.sh
#   allocation=$(allocate_resources "$task_json")

set -eo pipefail

# Prevent re-sourcing
if [ -n "${RESOURCE_ALLOCATION_LOADED:-}" ]; then
    return 0
fi
RESOURCE_ALLOCATION_LOADED=1

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Allocation history and config
ALLOCATION_HISTORY="$COMMIT_RELAY_HOME/coordination/metrics/allocation-history.jsonl"
ALLOCATION_CONFIG="$COMMIT_RELAY_HOME/coordination/config/resource-allocation.json"

# Ensure directories exist
mkdir -p "$(dirname "$ALLOCATION_HISTORY")"
mkdir -p "$(dirname "$ALLOCATION_CONFIG")"

# Default allocation profiles
declare -A BASE_ALLOCATIONS=(
    ["simple"]=5000
    ["medium"]=12000
    ["complex"]=25000
    ["very-complex"]=50000
)

# Task type multipliers
declare -A TYPE_MULTIPLIERS=(
    ["implementation"]=1.5
    ["feature-development"]=1.5
    ["security-scan"]=1.2
    ["analysis"]=1.3
    ["bug-fix"]=1.0
    ["security-fix"]=1.2
    ["documentation"]=0.8
    ["catalog"]=1.0
    ["refactoring"]=1.3
    ["testing"]=1.1
)

# Priority multipliers
declare -A PRIORITY_MULTIPLIERS=(
    ["critical"]=1.3
    ["high"]=1.2
    ["medium"]=1.0
    ["low"]=0.9
)

##############################################################################
# allocate_resources: Main function to allocate resources for a task
#
# Arguments:
#   $1 - Task specification JSON
#
# Returns:
#   JSON object with resource allocation
##############################################################################
allocate_resources() {
    local task_spec="$1"

    # Parse task information
    local task_id=$(echo "$task_spec" | jq -r '.id // .task_id // "unknown"')
    local task_type=$(echo "$task_spec" | jq -r '.type // "general"')
    local task_priority=$(echo "$task_spec" | jq -r '.priority // "medium"')
    local task_description=$(echo "$task_spec" | jq -r '.description // .title // ""')

    # Analyze task complexity
    local complexity=$(analyze_resource_complexity "$task_spec")

    # Get base allocation
    local base_tokens=${BASE_ALLOCATIONS[$complexity]:-12000}

    # Apply multipliers
    local type_mult=${TYPE_MULTIPLIERS[$task_type]:-1.0}
    local priority_mult=${PRIORITY_MULTIPLIERS[$task_priority]:-1.0}

    # Calculate initial allocation
    local initial_tokens=$(echo "$base_tokens * $type_mult * $priority_mult" | bc | cut -d. -f1)

    # Apply historical adjustment
    local historical_factor=$(get_historical_factor "$task_type" "$complexity")
    local adjusted_tokens=$(echo "$initial_tokens * $historical_factor" | bc | cut -d. -f1)

    # Apply bounds
    local min_tokens=2000
    local max_tokens=100000

    if [ "$adjusted_tokens" -lt "$min_tokens" ]; then
        adjusted_tokens=$min_tokens
    elif [ "$adjusted_tokens" -gt "$max_tokens" ]; then
        adjusted_tokens=$max_tokens
    fi

    # Calculate time budget (rough estimate: 100 tokens/second)
    local time_budget_seconds=$((adjusted_tokens / 100))
    local time_budget_minutes=$((time_budget_seconds / 60))

    # Generate allocation ID
    local alloc_id="alloc-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build allocation result
    local allocation=$(cat <<EOF
{
  "allocation_id": "$alloc_id",
  "task_id": "$task_id",
  "created_at": "$timestamp",
  "complexity": "$complexity",
  "resources": {
    "token_budget": $adjusted_tokens,
    "time_budget_seconds": $time_budget_seconds,
    "time_budget_minutes": $time_budget_minutes,
    "memory_mb": $(calculate_memory_allocation "$adjusted_tokens"),
    "priority_level": "$task_priority"
  },
  "calculation": {
    "base_tokens": $base_tokens,
    "type_multiplier": $type_mult,
    "priority_multiplier": $priority_mult,
    "historical_factor": $historical_factor,
    "initial_estimate": $initial_tokens,
    "final_allocation": $adjusted_tokens
  },
  "constraints": {
    "min_tokens": $min_tokens,
    "max_tokens": $max_tokens,
    "can_extend": true,
    "extension_limit": $(echo "$adjusted_tokens * 1.5" | bc | cut -d. -f1)
  },
  "metadata": {
    "allocator_version": "1.0.0",
    "task_type": "$task_type",
    "description_length": ${#task_description}
  }
}
EOF
)

    # Log allocation
    echo "$allocation" >> "$ALLOCATION_HISTORY"

    # Output result
    echo "$allocation"
}

##############################################################################
# analyze_resource_complexity: Determine complexity for resource allocation
##############################################################################
analyze_resource_complexity() {
    local task_spec="$1"
    local score=0

    # Factor 1: Description analysis
    local description=$(echo "$task_spec" | jq -r '.description // .title // ""')
    local desc_length=${#description}

    # Length scoring
    if [ "$desc_length" -gt 500 ]; then
        score=$((score + 4))
    elif [ "$desc_length" -gt 200 ]; then
        score=$((score + 3))
    elif [ "$desc_length" -gt 100 ]; then
        score=$((score + 2))
    elif [ "$desc_length" -gt 50 ]; then
        score=$((score + 1))
    fi

    # Keyword analysis for complexity indicators
    if echo "$description" | grep -qi "multiple\|several\|complex\|integrate\|refactor"; then
        score=$((score + 2))
    fi

    if echo "$description" | grep -qi "security\|audit\|compliance\|performance"; then
        score=$((score + 1))
    fi

    if echo "$description" | grep -qi "simple\|quick\|minor\|small"; then
        score=$((score - 1))
    fi

    # Factor 2: File scope
    local file_count=$(echo "$task_spec" | jq -r '.context.files // [] | length')
    if [ "$file_count" -gt 20 ]; then
        score=$((score + 4))
    elif [ "$file_count" -gt 10 ]; then
        score=$((score + 3))
    elif [ "$file_count" -gt 5 ]; then
        score=$((score + 2))
    elif [ "$file_count" -gt 0 ]; then
        score=$((score + 1))
    fi

    # Factor 3: Requirements count
    local req_count=$(echo "$task_spec" | jq -r '.context.requirements // [] | length')
    score=$((score + req_count / 3))

    # Factor 4: Dependencies
    local dep_count=$(echo "$task_spec" | jq -r '.context.dependencies // [] | length')
    score=$((score + dep_count / 5))

    # Ensure score is non-negative
    if [ "$score" -lt 0 ]; then
        score=0
    fi

    # Convert to complexity level
    if [ "$score" -ge 10 ]; then
        echo "very-complex"
    elif [ "$score" -ge 6 ]; then
        echo "complex"
    elif [ "$score" -ge 3 ]; then
        echo "medium"
    else
        echo "simple"
    fi
}

##############################################################################
# get_historical_factor: Get adjustment factor from historical data
##############################################################################
get_historical_factor() {
    local task_type="$1"
    local complexity="$2"

    # Check if we have historical data
    if [ ! -f "$ALLOCATION_HISTORY" ]; then
        echo "1.0"
        return
    fi

    # Get recent allocations of same type/complexity
    local recent_data=$(tail -100 "$ALLOCATION_HISTORY" 2>/dev/null | \
        jq -s --arg type "$task_type" --arg comp "$complexity" \
        '[.[] | select(.metadata.task_type == $type and .complexity == $comp)]')

    local count=$(echo "$recent_data" | jq 'length')

    if [ "$count" -lt 3 ]; then
        # Not enough data, use default
        echo "1.0"
        return
    fi

    # Calculate average utilization (would need actual usage data)
    # For now, return a slight optimization factor
    echo "0.95"
}

##############################################################################
# calculate_memory_allocation: Calculate memory based on token budget
##############################################################################
calculate_memory_allocation() {
    local token_budget="$1"

    # Rough estimate: 1MB per 1000 tokens
    local memory_mb=$((token_budget / 1000))

    # Minimum 256MB, maximum 4GB
    if [ "$memory_mb" -lt 256 ]; then
        memory_mb=256
    elif [ "$memory_mb" -gt 4096 ]; then
        memory_mb=4096
    fi

    echo "$memory_mb"
}

##############################################################################
# request_extension: Request additional resources for a task
##############################################################################
request_extension() {
    local allocation_id="$1"
    local reason="$2"
    local requested_tokens="${3:-0}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Find original allocation
    local original=$(grep "\"allocation_id\": \"$allocation_id\"" "$ALLOCATION_HISTORY" 2>/dev/null | tail -1)

    if [ -z "$original" ]; then
        echo "ERROR: Allocation not found: $allocation_id" >&2
        return 1
    fi

    local current_budget=$(echo "$original" | jq -r '.resources.token_budget')
    local extension_limit=$(echo "$original" | jq -r '.constraints.extension_limit')

    # Calculate extension
    if [ "$requested_tokens" -eq 0 ]; then
        # Default: 25% extension
        requested_tokens=$((current_budget / 4))
    fi

    local new_budget=$((current_budget + requested_tokens))

    # Check against limit
    if [ "$new_budget" -gt "$extension_limit" ]; then
        new_budget=$extension_limit
        requested_tokens=$((extension_limit - current_budget))
    fi

    # Log extension
    local extension=$(cat <<EOF
{
  "type": "extension",
  "allocation_id": "$allocation_id",
  "timestamp": "$timestamp",
  "original_budget": $current_budget,
  "requested_tokens": $requested_tokens,
  "new_budget": $new_budget,
  "reason": "$reason",
  "approved": true
}
EOF
)

    echo "$extension" >> "$ALLOCATION_HISTORY"

    # Return new allocation
    echo "$extension"
}

##############################################################################
# record_usage: Record actual resource usage for learning
##############################################################################
record_usage() {
    local allocation_id="$1"
    local actual_tokens="$2"
    local actual_time_seconds="$3"
    local outcome="${4:-success}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Find original allocation
    local original=$(grep "\"allocation_id\": \"$allocation_id\"" "$ALLOCATION_HISTORY" 2>/dev/null | tail -1)

    if [ -z "$original" ]; then
        echo "ERROR: Allocation not found: $allocation_id" >&2
        return 1
    fi

    local budgeted_tokens=$(echo "$original" | jq -r '.resources.token_budget')
    local utilization=$(echo "scale=2; $actual_tokens * 100 / $budgeted_tokens" | bc)

    # Log usage
    local usage=$(cat <<EOF
{
  "type": "usage",
  "allocation_id": "$allocation_id",
  "timestamp": "$timestamp",
  "budgeted_tokens": $budgeted_tokens,
  "actual_tokens": $actual_tokens,
  "actual_time_seconds": $actual_time_seconds,
  "utilization_percent": $utilization,
  "outcome": "$outcome",
  "efficiency": $(calculate_efficiency "$budgeted_tokens" "$actual_tokens" "$outcome")
}
EOF
)

    echo "$usage" >> "$ALLOCATION_HISTORY"

    echo "$usage"
}

##############################################################################
# calculate_efficiency: Calculate allocation efficiency score
##############################################################################
calculate_efficiency() {
    local budgeted="$1"
    local actual="$2"
    local outcome="$3"

    # Efficiency based on how close actual was to budgeted
    local utilization=$(echo "scale=4; $actual / $budgeted" | bc)

    # Optimal is around 80-90% utilization
    local efficiency
    if [ "$(echo "$utilization >= 0.8 && $utilization <= 0.95" | bc)" -eq 1 ]; then
        efficiency="1.0"
    elif [ "$(echo "$utilization >= 0.7 && $utilization < 0.8" | bc)" -eq 1 ]; then
        efficiency="0.9"
    elif [ "$(echo "$utilization >= 0.95 && $utilization <= 1.0" | bc)" -eq 1 ]; then
        efficiency="0.85"
    elif [ "$(echo "$utilization > 1.0" | bc)" -eq 1 ]; then
        efficiency="0.7"  # Went over budget
    else
        efficiency="0.75"  # Under-utilized
    fi

    # Penalize failures
    if [ "$outcome" = "failure" ]; then
        efficiency=$(echo "scale=2; $efficiency * 0.5" | bc)
    fi

    echo "$efficiency"
}

##############################################################################
# get_allocation_stats: Get allocation statistics
##############################################################################
get_allocation_stats() {
    local period="${1:-24h}"

    if [ ! -f "$ALLOCATION_HISTORY" ]; then
        echo '{"error":"No allocation history"}'
        return 1
    fi

    # Get recent allocations
    local stats=$(tail -1000 "$ALLOCATION_HISTORY" | jq -s '
        [.[] | select(.type != "extension" and .type != "usage")] as $allocs |
        [.[] | select(.type == "usage")] as $usage |
        {
            total_allocations: ($allocs | length),
            total_tokens_allocated: ([$allocs[].resources.token_budget] | add // 0),
            avg_tokens_per_task: (if ($allocs | length) > 0 then ([$allocs[].resources.token_budget] | add) / ($allocs | length) else 0 end),
            complexity_distribution: ($allocs | group_by(.complexity) | map({(.[0].complexity): length}) | add),
            usage_records: ($usage | length),
            avg_utilization: (if ($usage | length) > 0 then ([$usage[].utilization_percent] | add) / ($usage | length) else 0 end),
            avg_efficiency: (if ($usage | length) > 0 then ([$usage[].efficiency] | add) / ($usage | length) else 0 end)
        }')

    echo "$stats"
}

##############################################################################
# optimize_allocation: Get optimized allocation based on history
##############################################################################
optimize_allocation() {
    local task_type="$1"
    local complexity="$2"

    # Get stats for this task type and complexity
    if [ ! -f "$ALLOCATION_HISTORY" ]; then
        allocate_resources '{"type":"'$task_type'","complexity":"'$complexity'"}'
        return
    fi

    # Analyze historical patterns
    local optimized=$(tail -500 "$ALLOCATION_HISTORY" | jq -s \
        --arg type "$task_type" \
        --arg comp "$complexity" \
        '[.[] | select(.type == "usage" and .metadata.task_type == $type)] |
         if length > 5 then
           (([.[].actual_tokens] | add) / length) * 1.1
         else
           null
         end')

    if [ "$optimized" != "null" ] && [ -n "$optimized" ]; then
        echo "$optimized" | cut -d. -f1
    else
        echo "${BASE_ALLOCATIONS[$complexity]:-12000}"
    fi
}

# Export functions
export -f allocate_resources
export -f analyze_resource_complexity
export -f request_extension
export -f record_usage
export -f get_allocation_stats
export -f optimize_allocation

# Log that library is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[RESOURCE-ALLOC] Resource allocation library loaded" >&2
fi
