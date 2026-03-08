#!/bin/bash
# scripts/lib/task-allocator.sh
# Task Allocator Library - Phase 3 Item 24
# Context-aware resource allocation with dynamic token budget based on task complexity
#
# Features:
#   - Task complexity estimation from description
#   - Dynamic token budget calculation
#   - Resource allocation based on task type and history
#   - Integration with worker spec builder
#
# Usage:
#   source "$COMMIT_RELAY_HOME/scripts/lib/task-allocator.sh"
#   allocation=$(allocate_resources --task-description "Implement auth system" --task-type "feature")

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Allocation policy
ALLOCATION_POLICY_FILE="${COMMIT_RELAY_HOME}/coordination/config/task-allocation-policy.json"

# Historical data
ALLOCATION_HISTORY_FILE="${COMMIT_RELAY_HOME}/coordination/metrics/task-allocation-history.jsonl"

# Create directories
mkdir -p "$(dirname "$ALLOCATION_HISTORY_FILE")"

# Default allocation values
DEFAULT_BASE_TOKENS=5000
DEFAULT_MAX_TOKENS=50000
DEFAULT_TIMEOUT_MINUTES=30

# ============================================================================
# Logging
# ============================================================================

log_allocator() {
    local level="$1"
    shift
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] [ALLOCATOR] [$level] $*" >&2
}

# ============================================================================
# Initialize Default Policy
# ============================================================================

initialize_allocation_policy() {
    if [ ! -f "$ALLOCATION_POLICY_FILE" ]; then
        mkdir -p "$(dirname "$ALLOCATION_POLICY_FILE")"
        cat > "$ALLOCATION_POLICY_FILE" <<'EOF'
{
  "version": "1.0.0",
  "base_allocation": {
    "tokens": 5000,
    "timeout_minutes": 30
  },
  "complexity_multipliers": {
    "simple": 1.0,
    "moderate": 1.5,
    "complex": 2.5,
    "very_complex": 4.0
  },
  "task_type_modifiers": {
    "feature": {"token_multiplier": 2.0, "timeout_multiplier": 2.0},
    "bug_fix": {"token_multiplier": 1.2, "timeout_multiplier": 1.5},
    "refactor": {"token_multiplier": 1.5, "timeout_multiplier": 1.5},
    "test": {"token_multiplier": 1.0, "timeout_multiplier": 1.2},
    "documentation": {"token_multiplier": 0.8, "timeout_multiplier": 1.0},
    "research": {"token_multiplier": 1.5, "timeout_multiplier": 2.0}
  },
  "complexity_indicators": {
    "high_complexity_keywords": [
      "integrate", "migration", "architecture", "security", "performance",
      "distributed", "concurrent", "async", "database", "api", "authentication",
      "authorization", "encryption", "optimization", "refactor entire"
    ],
    "moderate_complexity_keywords": [
      "implement", "create", "add feature", "update", "modify", "extend",
      "component", "service", "handler", "controller", "model"
    ],
    "low_complexity_keywords": [
      "fix typo", "update comment", "rename", "simple", "minor", "small",
      "adjust", "tweak", "formatting"
    ]
  },
  "file_count_modifiers": {
    "1-3": 1.0,
    "4-7": 1.3,
    "8-15": 1.8,
    "16+": 2.5
  },
  "limits": {
    "min_tokens": 2000,
    "max_tokens": 50000,
    "min_timeout_minutes": 10,
    "max_timeout_minutes": 120
  }
}
EOF
        log_allocator "INFO" "Created default allocation policy"
    fi
}

# Initialize on load
initialize_allocation_policy

# ============================================================================
# Complexity Analysis
# ============================================================================

# Estimate task complexity from description
estimate_complexity() {
    local description="$1"
    local description_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

    local complexity="moderate"
    local score=0

    # Load complexity indicators from policy
    local high_keywords=$(jq -r '.complexity_indicators.high_complexity_keywords[]' "$ALLOCATION_POLICY_FILE")
    local moderate_keywords=$(jq -r '.complexity_indicators.moderate_complexity_keywords[]' "$ALLOCATION_POLICY_FILE")
    local low_keywords=$(jq -r '.complexity_indicators.low_complexity_keywords[]' "$ALLOCATION_POLICY_FILE")

    # Check for high complexity indicators
    while IFS= read -r keyword; do
        if echo "$description_lower" | grep -qi "$keyword"; then
            score=$((score + 3))
        fi
    done <<< "$high_keywords"

    # Check for moderate complexity indicators
    while IFS= read -r keyword; do
        if echo "$description_lower" | grep -qi "$keyword"; then
            score=$((score + 1))
        fi
    done <<< "$moderate_keywords"

    # Check for low complexity indicators
    while IFS= read -r keyword; do
        if echo "$description_lower" | grep -qi "$keyword"; then
            score=$((score - 2))
        fi
    done <<< "$low_keywords"

    # Word count as complexity indicator
    local word_count=$(echo "$description" | wc -w | tr -d ' ')
    if [ "$word_count" -gt 100 ]; then
        score=$((score + 2))
    elif [ "$word_count" -gt 50 ]; then
        score=$((score + 1))
    fi

    # Map score to complexity level
    if [ "$score" -le 0 ]; then
        complexity="simple"
    elif [ "$score" -le 3 ]; then
        complexity="moderate"
    elif [ "$score" -le 7 ]; then
        complexity="complex"
    else
        complexity="very_complex"
    fi

    jq -nc \
        --arg complexity "$complexity" \
        --argjson score "$score" \
        --argjson word_count "$word_count" \
        '{
            complexity: $complexity,
            score: $score,
            word_count: $word_count
        }'
}

# Estimate file count from description
estimate_file_count() {
    local description="$1"
    local description_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')

    local file_count=1

    # Look for explicit file mentions
    if echo "$description" | grep -qoE '[0-9]+ files?'; then
        file_count=$(echo "$description" | grep -oE '[0-9]+ files?' | grep -oE '[0-9]+' | head -1)
    fi

    # Infer from keywords
    if echo "$description_lower" | grep -qi "entire\|all\|throughout\|codebase\|project-wide"; then
        file_count=$((file_count + 10))
    elif echo "$description_lower" | grep -qi "multiple\|several\|various"; then
        file_count=$((file_count + 4))
    elif echo "$description_lower" | grep -qi "few\|couple"; then
        file_count=$((file_count + 2))
    fi

    echo "$file_count"
}

# ============================================================================
# Resource Calculation
# ============================================================================

# Calculate token budget based on complexity and task type
calculate_token_budget() {
    local complexity="$1"
    local task_type="$2"
    local file_count="$3"

    # Get base tokens
    local base_tokens=$(jq -r '.base_allocation.tokens' "$ALLOCATION_POLICY_FILE")

    # Get complexity multiplier
    local complexity_mult=$(jq -r --arg c "$complexity" '.complexity_multipliers[$c] // 1.5' "$ALLOCATION_POLICY_FILE")

    # Get task type multiplier
    local type_mult=$(jq -r --arg t "$task_type" '.task_type_modifiers[$t].token_multiplier // 1.0' "$ALLOCATION_POLICY_FILE")

    # Get file count modifier
    local file_mult=1.0
    if [ "$file_count" -ge 16 ]; then
        file_mult=$(jq -r '.file_count_modifiers["16+"]' "$ALLOCATION_POLICY_FILE")
    elif [ "$file_count" -ge 8 ]; then
        file_mult=$(jq -r '.file_count_modifiers["8-15"]' "$ALLOCATION_POLICY_FILE")
    elif [ "$file_count" -ge 4 ]; then
        file_mult=$(jq -r '.file_count_modifiers["4-7"]' "$ALLOCATION_POLICY_FILE")
    else
        file_mult=$(jq -r '.file_count_modifiers["1-3"]' "$ALLOCATION_POLICY_FILE")
    fi

    # Calculate total
    local total=$(echo "$base_tokens * $complexity_mult * $type_mult * $file_mult" | bc)
    local total_int=${total%.*}

    # Apply limits
    local min_tokens=$(jq -r '.limits.min_tokens' "$ALLOCATION_POLICY_FILE")
    local max_tokens=$(jq -r '.limits.max_tokens' "$ALLOCATION_POLICY_FILE")

    if [ "$total_int" -lt "$min_tokens" ]; then
        total_int=$min_tokens
    elif [ "$total_int" -gt "$max_tokens" ]; then
        total_int=$max_tokens
    fi

    echo "$total_int"
}

# Calculate timeout based on complexity and task type
calculate_timeout() {
    local complexity="$1"
    local task_type="$2"

    # Get base timeout
    local base_timeout=$(jq -r '.base_allocation.timeout_minutes' "$ALLOCATION_POLICY_FILE")

    # Get complexity multiplier
    local complexity_mult=$(jq -r --arg c "$complexity" '.complexity_multipliers[$c] // 1.5' "$ALLOCATION_POLICY_FILE")

    # Get task type multiplier
    local type_mult=$(jq -r --arg t "$task_type" '.task_type_modifiers[$t].timeout_multiplier // 1.0' "$ALLOCATION_POLICY_FILE")

    # Calculate total
    local total=$(echo "$base_timeout * $complexity_mult * $type_mult" | bc)
    local total_int=${total%.*}

    # Apply limits
    local min_timeout=$(jq -r '.limits.min_timeout_minutes' "$ALLOCATION_POLICY_FILE")
    local max_timeout=$(jq -r '.limits.max_timeout_minutes' "$ALLOCATION_POLICY_FILE")

    if [ "$total_int" -lt "$min_timeout" ]; then
        total_int=$min_timeout
    elif [ "$total_int" -gt "$max_timeout" ]; then
        total_int=$max_timeout
    fi

    echo "$total_int"
}

# ============================================================================
# Historical Learning
# ============================================================================

# Get average resource usage for similar tasks
get_historical_average() {
    local task_type="$1"
    local complexity="$2"

    if [ ! -f "$ALLOCATION_HISTORY_FILE" ]; then
        echo "{}"
        return
    fi

    # Find similar completed tasks
    local similar=$(grep "\"task_type\":\"$task_type\"" "$ALLOCATION_HISTORY_FILE" | \
                   grep "\"complexity\":\"$complexity\"" | \
                   grep "\"status\":\"completed\"" | \
                   tail -10)

    if [ -z "$similar" ]; then
        echo "{}"
        return
    fi

    # Calculate averages
    local avg_tokens=$(echo "$similar" | jq -s '[.[].actual_tokens_used] | add / length | floor')
    local avg_time=$(echo "$similar" | jq -s '[.[].actual_duration_minutes] | add / length | floor')

    jq -nc \
        --argjson tokens "${avg_tokens:-0}" \
        --argjson time "${avg_time:-0}" \
        '{
            avg_tokens_used: $tokens,
            avg_duration_minutes: $time
        }'
}

# ============================================================================
# Main Allocation Function
# ============================================================================

allocate_resources() {
    local task_description=""
    local task_type="feature"
    local task_id=""
    local explicit_files=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --task-description)
                task_description="$2"
                shift 2
                ;;
            --task-type)
                task_type="$2"
                shift 2
                ;;
            --task-id)
                task_id="$2"
                shift 2
                ;;
            --file-count)
                explicit_files="$2"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if [ -z "$task_description" ]; then
        echo "ERROR: --task-description is required" >&2
        return 1
    fi

    # Analyze complexity
    local complexity_analysis=$(estimate_complexity "$task_description")
    local complexity=$(echo "$complexity_analysis" | jq -r '.complexity')

    # Estimate or use explicit file count
    local file_count
    if [ -n "$explicit_files" ]; then
        file_count="$explicit_files"
    else
        file_count=$(estimate_file_count "$task_description")
    fi

    # Calculate resources
    local token_budget=$(calculate_token_budget "$complexity" "$task_type" "$file_count")
    local timeout_minutes=$(calculate_timeout "$complexity" "$task_type")

    # Get historical data
    local historical=$(get_historical_average "$task_type" "$complexity")

    # Build allocation result
    local allocation=$(jq -nc \
        --arg task_id "${task_id:-unspecified}" \
        --arg task_type "$task_type" \
        --argjson complexity_analysis "$complexity_analysis" \
        --argjson file_count "$file_count" \
        --argjson token_budget "$token_budget" \
        --argjson timeout_minutes "$timeout_minutes" \
        --argjson historical "$historical" \
        --arg allocated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            task_id: $task_id,
            task_type: $task_type,
            complexity_analysis: $complexity_analysis,
            estimated_file_count: $file_count,
            allocation: {
                token_budget: $token_budget,
                timeout_minutes: $timeout_minutes
            },
            historical_reference: $historical,
            allocated_at: $allocated_at
        }')

    log_allocator "INFO" "Allocated resources for task: $task_id (complexity: $complexity, tokens: $token_budget, timeout: ${timeout_minutes}m)"

    echo "$allocation"
}

# Record allocation outcome for learning
record_allocation_outcome() {
    local task_id="$1"
    local task_type="$2"
    local complexity="$3"
    local allocated_tokens="$4"
    local actual_tokens="$5"
    local allocated_time="$6"
    local actual_time="$7"
    local status="$8"

    local record=$(jq -nc \
        --arg task_id "$task_id" \
        --arg task_type "$task_type" \
        --arg complexity "$complexity" \
        --argjson allocated_tokens "$allocated_tokens" \
        --argjson actual_tokens_used "$actual_tokens" \
        --argjson allocated_timeout "$allocated_time" \
        --argjson actual_duration_minutes "$actual_time" \
        --arg status "$status" \
        --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            task_id: $task_id,
            task_type: $task_type,
            complexity: $complexity,
            allocated_tokens: $allocated_tokens,
            actual_tokens_used: $actual_tokens_used,
            allocated_timeout: $allocated_timeout,
            actual_duration_minutes: $actual_duration_minutes,
            status: $status,
            efficiency: (if $actual_tokens_used > 0 then ($actual_tokens_used / $allocated_tokens * 100 | floor) else 0 end),
            recorded_at: $recorded_at
        }')

    echo "$record" >> "$ALLOCATION_HISTORY_FILE"
    log_allocator "INFO" "Recorded outcome for task: $task_id"
}

# Export functions
export -f allocate_resources 2>/dev/null || true
export -f record_allocation_outcome 2>/dev/null || true
export -f estimate_complexity 2>/dev/null || true
export -f calculate_token_budget 2>/dev/null || true
export -f calculate_timeout 2>/dev/null || true

log_allocator "INFO" "Task allocator library loaded"
