#!/bin/bash
# scripts/lib/learning-agent/problem-generator.sh
# Learning Agent: Problem Generator Component
# Week 6: Q1 Implementation - Problem Generator & Exploration
#
# Purpose: Generate exploratory tasks to discover new patterns
# Part of the ASI (Artificial Superintelligence) learning cycle
#
# Functions:
# - generate_exploratory_task(): Create novel tasks for exploration
# - identify_gaps(): Find knowledge gaps in the system
# - balance_exploration(): Manage explore/exploit tradeoff (10%/90%)
# - track_exploration_outcomes(): Learn from exploration results
#
# Exploration Strategy: Epsilon-greedy (10% exploration, 90% exploitation)

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Load dependencies
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Configuration
EXPLORATION_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/exploration"
TRAINING_EXAMPLES_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-examples"
PATTERNS_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/learned-patterns"
TASK_QUEUE_FILE="$COMMIT_RELAY_HOME/coordination/task-queue.json"
EXPLORATION_RATE=0.10  # 10% of tasks are exploratory

# Ensure directories exist
mkdir -p "$EXPLORATION_DIR"

#------------------------------------------------------------------------------
# generate_exploratory_task()
# Create a novel task to discover new patterns
#
# Args:
#   $1 - exploration_type: "variation", "untested", "combination", "random"
#
# Returns:
#   Exploratory task specification (JSON)
#------------------------------------------------------------------------------
generate_exploratory_task() {
    local exploration_type="${1:-variation}"

    log_info "[ProblemGen] Generating exploratory task: $exploration_type"

    local task_spec=""

    case "$exploration_type" in
        variation)
            task_spec=$(generate_task_variation)
            ;;
        untested)
            task_spec=$(generate_untested_combination)
            ;;
        combination)
            task_spec=$(generate_strategy_combination)
            ;;
        random)
            task_spec=$(generate_random_exploration)
            ;;
        *)
            log_error "[ProblemGen] Unknown exploration type: $exploration_type"
            return 1
            ;;
    esac

    # Add exploration metadata
    local exploratory_task=$(echo "$task_spec" | jq \
        --arg exp_type "$exploration_type" \
        --arg exp_id "explore-$(date +%s)-$(uuidgen | cut -d- -f1)" \
        --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '. + {
            exploration_metadata: {
                is_exploratory: true,
                exploration_type: $exp_type,
                exploration_id: $exp_id,
                created_at: $created_at
            }
        }')

    log_info "[ProblemGen] Exploratory task generated: $(echo "$exploratory_task" | jq -r '.exploration_metadata.exploration_id')"

    # Track exploration
    track_exploration_created "$exploratory_task"

    echo "$exploratory_task"
}

#------------------------------------------------------------------------------
# generate_task_variation()
# Generate a variation of a successful task
#
# Returns:
#   Task specification (JSON)
#------------------------------------------------------------------------------
generate_task_variation() {
    log_info "[ProblemGen] Generating task variation from successful examples"

    # Find a successful training example
    local positive_examples="$TRAINING_EXAMPLES_DIR/positive-examples.jsonl"

    if [ ! -f "$positive_examples" ] || [ ! -s "$positive_examples" ]; then
        log_warn "[ProblemGen] No positive examples found, generating random task"
        generate_random_exploration
        return
    fi

    # Select a high-scoring example randomly
    local example=$(cat "$positive_examples" | \
        jq -s 'map(select(.overall_score >= 80)) | .[] | select(length > 0)' | \
        shuf -n 1)

    if [ -z "$example" ]; then
        log_warn "[ProblemGen] No high-scoring examples found"
        generate_random_exploration
        return
    fi

    # Extract context and vary it
    local task_type=$(echo "$example" | jq -r '.context.task_type')
    local complexity=$(echo "$example" | jq -r '.context.complexity')
    local original_strategy=$(echo "$example" | jq -r '.action.strategy_used')

    # Vary the strategy while keeping context similar
    local alternative_strategies=("incremental" "test-driven" "refactor-first" "minimal-viable" "comprehensive")
    local new_strategy="${alternative_strategies[$((RANDOM % ${#alternative_strategies[@]}))]}"

    # Ensure we pick a different strategy
    while [ "$new_strategy" = "$original_strategy" ]; do
        new_strategy="${alternative_strategies[$((RANDOM % ${#alternative_strategies[@]}))]}"
    done

    # Create task spec
    local task_spec=$(jq -n \
        --arg task_type "$task_type" \
        --arg complexity "$complexity" \
        --arg strategy "$new_strategy" \
        --arg description "Exploratory variation: $task_type with $new_strategy strategy" \
        '{
            task_type: $task_type,
            strategy: $strategy,
            complexity: $complexity,
            description: $description,
            priority: "low",
            exploration_rationale: "Testing alternative strategy for known task type"
        }')

    echo "$task_spec"
}

#------------------------------------------------------------------------------
# generate_untested_combination()
# Generate task with untested context combination
#
# Returns:
#   Task specification (JSON)
#------------------------------------------------------------------------------
generate_untested_combination() {
    log_info "[ProblemGen] Generating untested combination"

    # Identify task types and complexities we've seen
    local training_file="$TRAINING_EXAMPLES_DIR/training-examples.jsonl"

    if [ ! -f "$training_file" ] || [ ! -s "$training_file" ]; then
        generate_random_exploration
        return
    fi

    # Get tested combinations
    local tested_combinations=$(cat "$training_file" | \
        jq -r '[.context.task_type, .context.complexity] | @csv' | \
        sort -u)

    # Define possible values
    local task_types=("feature" "bugfix" "refactor" "test" "docs" "infrastructure")
    local complexities=("simple" "moderate" "complex")

    # Find an untested combination
    local found_untested=false
    local attempts=0
    local max_attempts=20

    while [ "$found_untested" = false ] && [ $attempts -lt $max_attempts ]; do
        local task_type="${task_types[$((RANDOM % ${#task_types[@]}))]}"
        local complexity="${complexities[$((RANDOM % ${#complexities[@]}))]}"
        local combination="\"$task_type\",\"$complexity\""

        if ! echo "$tested_combinations" | grep -q "$combination"; then
            found_untested=true

            local task_spec=$(jq -n \
                --arg task_type "$task_type" \
                --arg complexity "$complexity" \
                --arg description "Exploratory: untested $complexity $task_type task" \
                '{
                    task_type: $task_type,
                    complexity: $complexity,
                    description: $description,
                    priority: "low",
                    exploration_rationale: "Testing never-before-seen task type and complexity combination"
                }')

            echo "$task_spec"
            return
        fi

        attempts=$((attempts + 1))
    done

    # Fallback to random if all combinations tested
    log_info "[ProblemGen] All combinations tested, generating random variation"
    generate_task_variation
}

#------------------------------------------------------------------------------
# generate_strategy_combination()
# Generate task with novel strategy combination
#
# Returns:
#   Task specification (JSON)
#------------------------------------------------------------------------------
generate_strategy_combination() {
    log_info "[ProblemGen] Generating strategy combination"

    # Randomly select task context
    local task_types=("feature" "bugfix" "refactor" "test" "docs")
    local complexities=("simple" "moderate" "complex")
    local strategies=("incremental" "test-driven" "refactor-first" "minimal-viable" "comprehensive" "experimental")

    local task_type="${task_types[$((RANDOM % ${#task_types[@]}))]}"
    local complexity="${complexities[$((RANDOM % ${#complexities[@]}))]}"
    local strategy="${strategies[$((RANDOM % ${#strategies[@]}))]}"

    # Create task spec
    local task_spec=$(jq -n \
        --arg task_type "$task_type" \
        --arg complexity "$complexity" \
        --arg strategy "$strategy" \
        --arg description "Exploratory: $strategy approach to $complexity $task_type" \
        '{
            task_type: $task_type,
            strategy: $strategy,
            complexity: $complexity,
            description: $description,
            priority: "low",
            exploration_rationale: "Testing strategy effectiveness in this context"
        }')

    echo "$task_spec"
}

#------------------------------------------------------------------------------
# generate_random_exploration()
# Generate completely random exploratory task
#
# Returns:
#   Task specification (JSON)
#------------------------------------------------------------------------------
generate_random_exploration() {
    log_info "[ProblemGen] Generating random exploration"

    local task_types=("feature" "bugfix" "refactor" "test" "docs" "infrastructure" "optimization")
    local complexities=("simple" "moderate" "complex")
    local strategies=("incremental" "test-driven" "refactor-first" "minimal-viable" "comprehensive" "experimental" "research")

    local task_type="${task_types[$((RANDOM % ${#task_types[@]}))]}"
    local complexity="${complexities[$((RANDOM % ${#complexities[@]}))]}"
    local strategy="${strategies[$((RANDOM % ${#strategies[@]}))]}"

    local task_spec=$(jq -n \
        --arg task_type "$task_type" \
        --arg complexity "$complexity" \
        --arg strategy "$strategy" \
        --arg description "Random exploration: $complexity $task_type with $strategy" \
        '{
            task_type: $task_type,
            strategy: $strategy,
            complexity: $complexity,
            description: $description,
            priority: "low",
            exploration_rationale: "Random exploration for discovery"
        }')

    echo "$task_spec"
}

#------------------------------------------------------------------------------
# identify_gaps()
# Find knowledge gaps in the system
#
# Returns:
#   JSON array of identified gaps
#------------------------------------------------------------------------------
identify_gaps() {
    log_info "[ProblemGen] Identifying knowledge gaps"

    local gaps=()

    # Gap 1: Task types never attempted
    local untested_task_types=$(identify_untested_task_types)
    if [ -n "$untested_task_types" ]; then
        gaps+=("$untested_task_types")
    fi

    # Gap 2: Strategies rarely used
    local underused_strategies=$(identify_underused_strategies)
    if [ -n "$underused_strategies" ]; then
        gaps+=("$underused_strategies")
    fi

    # Gap 3: Context situations not encountered
    local unexplored_contexts=$(identify_unexplored_contexts)
    if [ -n "$unexplored_contexts" ]; then
        gaps+=("$unexplored_contexts")
    fi

    # Combine gaps
    local gaps_json=$(printf '%s\n' "${gaps[@]}" | jq -s '.')

    log_info "[ProblemGen] Identified ${#gaps[@]} knowledge gaps"

    echo "$gaps_json"
}

#------------------------------------------------------------------------------
# identify_untested_task_types()
# Find task types with no or few examples
#
# Returns:
#   JSON describing untested task types
#------------------------------------------------------------------------------
identify_untested_task_types() {
    local training_file="$TRAINING_EXAMPLES_DIR/training-examples.jsonl"

    if [ ! -f "$training_file" ] || [ ! -s "$training_file" ]; then
        echo '{"gap_type": "untested_task_types", "count": 0, "details": []}'
        return
    fi

    # Count examples per task type
    local task_type_counts=$(cat "$training_file" | \
        jq -s 'group_by(.context.task_type) | map({task_type: .[0].context.task_type, count: length})')

    # Find task types with < 5 examples
    local rare_types=$(echo "$task_type_counts" | jq 'map(select(.count < 5))')

    local gap=$(jq -n \
        --argjson rare "$rare_types" \
        '{
            gap_type: "untested_task_types",
            count: ($rare | length),
            details: $rare
        }')

    echo "$gap"
}

#------------------------------------------------------------------------------
# identify_underused_strategies()
# Find strategies used infrequently
#
# Returns:
#   JSON describing underused strategies
#------------------------------------------------------------------------------
identify_underused_strategies() {
    local training_file="$TRAINING_EXAMPLES_DIR/training-examples.jsonl"

    if [ ! -f "$training_file" ] || [ ! -s "$training_file" ]; then
        echo '{"gap_type": "underused_strategies", "count": 0, "details": []}'
        return
    fi

    # Count examples per strategy
    local strategy_counts=$(cat "$training_file" | \
        jq -s 'group_by(.action.strategy_used) | map({strategy: .[0].action.strategy_used, count: length})')

    # Find strategies with < 5 examples
    local rare_strategies=$(echo "$strategy_counts" | jq 'map(select(.count < 5))')

    local gap=$(jq -n \
        --argjson rare "$rare_strategies" \
        '{
            gap_type: "underused_strategies",
            count: ($rare | length),
            details: $rare
        }')

    echo "$gap"
}

#------------------------------------------------------------------------------
# identify_unexplored_contexts()
# Find context combinations not explored
#
# Returns:
#   JSON describing unexplored contexts
#------------------------------------------------------------------------------
identify_unexplored_contexts() {
    # Placeholder: in production, would analyze context space coverage
    local gap=$(jq -n '{
        gap_type: "unexplored_contexts",
        count: 0,
        details: "Context space analysis not yet implemented"
    }')

    echo "$gap"
}

#------------------------------------------------------------------------------
# balance_exploration()
# Determine if next task should be exploratory (epsilon-greedy)
#
# Args:
#   $1 - recent_tasks_count: Number of recent tasks to consider (default: 10)
#
# Returns:
#   "explore" or "exploit"
#------------------------------------------------------------------------------
balance_exploration() {
    local recent_count="${1:-10}"

    log_info "[ProblemGen] Balancing exploration (target: ${EXPLORATION_RATE})"

    # Count recent exploratory tasks
    local exploration_log="$EXPLORATION_DIR/exploration-log.jsonl"

    if [ ! -f "$exploration_log" ]; then
        # No exploration yet, explore!
        echo "explore"
        return
    fi

    # Get recent tasks
    local recent_tasks=$(tail -n "$recent_count" "$exploration_log" 2>/dev/null || echo "")

    if [ -z "$recent_tasks" ]; then
        echo "explore"
        return
    fi

    # Count exploratory vs exploitative
    local total_recent=$(echo "$recent_tasks" | wc -l | tr -d ' ')
    local exploratory_recent=$(echo "$recent_tasks" | grep -c '"is_exploratory":true' || echo "0")

    # Calculate current exploration rate
    local current_rate=$(echo "scale=2; $exploratory_recent / $total_recent" | bc)

    log_info "[ProblemGen] Recent exploration rate: $current_rate (target: $EXPLORATION_RATE)"

    # Epsilon-greedy: if below target, explore; otherwise random with epsilon probability
    if (( $(echo "$current_rate < $EXPLORATION_RATE" | bc -l) )); then
        echo "explore"
    else
        # Random draw: 10% chance to explore
        local random=$(echo "scale=2; $RANDOM / 32767" | bc)
        if (( $(echo "$random < $EXPLORATION_RATE" | bc -l) )); then
            echo "explore"
        else
            echo "exploit"
        fi
    fi
}

#------------------------------------------------------------------------------
# track_exploration_created()
# Record exploratory task creation
#
# Args:
#   $1 - exploratory_task_json
#------------------------------------------------------------------------------
track_exploration_created() {
    local task_json="$1"

    local exploration_id=$(echo "$task_json" | jq -r '.exploration_metadata.exploration_id')
    local exploration_type=$(echo "$task_json" | jq -r '.exploration_metadata.exploration_type')

    local log_entry=$(jq -n \
        --arg exp_id "$exploration_id" \
        --arg exp_type "$exploration_type" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg status "created" \
        '{
            exploration_id: $exp_id,
            exploration_type: $exp_type,
            timestamp: $timestamp,
            status: $status,
            is_exploratory: true
        }')

    echo "$log_entry" >> "$EXPLORATION_DIR/exploration-log.jsonl"
}

#------------------------------------------------------------------------------
# track_exploration_outcomes()
# Analyze and learn from exploration results
#
# Args:
#   $1 - since_timestamp: Only process explorations since this time (optional)
#
# Returns:
#   Exploration outcomes summary (JSON)
#------------------------------------------------------------------------------
track_exploration_outcomes() {
    local since_timestamp="${1:-}"

    log_info "[ProblemGen] Tracking exploration outcomes"

    local exploration_log="$EXPLORATION_DIR/exploration-log.jsonl"
    local training_examples="$TRAINING_EXAMPLES_DIR/training-examples.jsonl"

    if [ ! -f "$exploration_log" ] || [ ! -f "$training_examples" ]; then
        log_warn "[ProblemGen] Insufficient data for exploration outcome analysis"
        echo '{"sufficient_data": false}'
        return
    fi

    # Join exploration log with training examples (by task_id or worker_id)
    # Simplified: analyze all exploratory examples

    local exploratory_examples=$(cat "$training_examples" | \
        if [ -n "$since_timestamp" ]; then
            jq -c "select(.created_at >= \"$since_timestamp\")"
        else
            cat
        fi | \
        jq -s 'map(select(.context.exploration_metadata.is_exploratory == true))')

    local total_exploratory=$(echo "$exploratory_examples" | jq 'length')

    if [ "$total_exploratory" -eq 0 ]; then
        log_info "[ProblemGen] No completed exploratory tasks found"
        echo '{"sufficient_data": false, "total_exploratory": 0}'
        return
    fi

    # Calculate ROI of exploration
    local successful_discoveries=$(echo "$exploratory_examples" | \
        jq 'map(select(.overall_score >= 70)) | length')

    local discovery_rate=$(echo "scale=2; $successful_discoveries / $total_exploratory" | bc)

    # Compare to exploitation (non-exploratory) success rate
    local exploitative_examples=$(cat "$training_examples" | \
        jq -s 'map(select(.context.exploration_metadata.is_exploratory != true))')

    local total_exploitative=$(echo "$exploitative_examples" | jq 'length')
    local exploitative_successful=$(echo "$exploitative_examples" | \
        jq 'map(select(.overall_score >= 70)) | length')

    local exploit_success_rate=0
    if [ "$total_exploitative" -gt 0 ]; then
        exploit_success_rate=$(echo "scale=2; $exploitative_successful / $total_exploitative" | bc)
    fi

    # Calculate value of exploration
    local exploration_value=$(echo "scale=2; $discovery_rate - $exploit_success_rate" | bc)

    local outcomes=$(jq -n \
        --argjson total_exploratory "$total_exploratory" \
        --argjson successful_discoveries "$successful_discoveries" \
        --arg discovery_rate "$discovery_rate" \
        --argjson total_exploitative "$total_exploitative" \
        --argjson exploitative_successful "$exploitative_successful" \
        --arg exploit_success_rate "$exploit_success_rate" \
        --arg exploration_value "$exploration_value" \
        --arg analyzed_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            sufficient_data: true,
            exploratory: {
                total: $total_exploratory,
                successful: $successful_discoveries,
                success_rate: $discovery_rate
            },
            exploitative: {
                total: $total_exploitative,
                successful: $exploitative_successful,
                success_rate: $exploit_success_rate
            },
            exploration_value: $exploration_value,
            analysis: (
                if ($exploration_value | tonumber) > 0 then
                    "Exploration is discovering valuable patterns"
                elif ($exploration_value | tonumber) < -0.2 then
                    "Exploration ROI is low, consider adjusting rate"
                else
                    "Exploration ROI is neutral"
                end
            ),
            analyzed_at: $analyzed_at
        }')

    # Save outcomes
    echo "$outcomes" > "$EXPLORATION_DIR/exploration-outcomes-latest.json"

    local value=$(echo "$exploration_value" | awk '{printf "%.1f", $1 * 100}')
    log_info "[ProblemGen] Exploration value: ${value}% vs exploitation"

    echo "$outcomes"
}

#------------------------------------------------------------------------------
# Main execution (if called directly)
#------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-generate}" in
        generate)
            exploration_type="${2:-variation}"
            generate_exploratory_task "$exploration_type" | jq .
            ;;
        balance)
            decision=$(balance_exploration "${2:-10}")
            echo "Decision: $decision"
            ;;
        gaps)
            identify_gaps | jq .
            ;;
        outcomes)
            track_exploration_outcomes "${2:-}" | jq .
            ;;
        *)
            echo "Usage: problem-generator.sh {generate|balance|gaps|outcomes}"
            echo ""
            echo "Commands:"
            echo "  generate [type]  - Generate exploratory task"
            echo "                     types: variation, untested, combination, random"
            echo "  balance [n]      - Decide explore vs exploit (recent n tasks)"
            echo "  gaps             - Identify knowledge gaps"
            echo "  outcomes [since] - Analyze exploration outcomes"
            exit 1
            ;;
    esac
fi
