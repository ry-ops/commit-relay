#!/bin/bash
# Aggregator Master - MoE Merge Function
# Collects and merges results from multiple specialist masters

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
MERGE_LOG="$SCRIPT_DIR/merge-log.jsonl"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Ensure directories exist
mkdir -p "$RESULTS_DIR"
mkdir -p "$(dirname "$MERGE_LOG")"

##############################################################################
# collect_expert_results: Gather results from all experts for a task
# Args:
#   $1: task_id
# Returns: JSON array of expert results
##############################################################################
collect_expert_results() {
    local task_id="$1"
    local results=()

    echo -e "${BLUE}Collecting results for task: $task_id${NC}"

    # Look for result files from each expert
    local result_files=$(find "$PROJECT_ROOT/coordination/masters" -name "*${task_id}*result*.json" 2>/dev/null || echo "")

    if [ -z "$result_files" ]; then
        echo -e "${YELLOW}No results found yet for task $task_id${NC}"
        echo "[]"
        return
    fi

    # Collect all results into JSON array
    local results_json="["
    local first=true

    while IFS= read -r result_file; do
        if [ -f "$result_file" ]; then
            if [ "$first" = false ]; then
                results_json+=","
            fi
            results_json+=$(cat "$result_file")
            first=false
            echo -e "${GREEN}  ✓${NC} Collected: $(basename "$result_file")"
        fi
    done <<< "$result_files"

    results_json+="]"
    echo "$results_json"
}

##############################################################################
# merge_strategy_voting: Vote on best solution from multiple experts
# Args:
#   $1: results JSON array
# Returns: Merged result
##############################################################################
merge_strategy_voting() {
    local results="$1"

    echo -e "${MAGENTA}Strategy: VOTING${NC}"

    # Count votes for each approach
    # For now, simple implementation: highest confidence wins
    local best_result=$(echo "$results" | jq 'max_by(.confidence // 0)')

    echo "$best_result" | jq '. + {merge_strategy: "voting", aggregator: "aggregator-master"}'
}

##############################################################################
# merge_strategy_weighted: Weight results by expert confidence
# Args:
#   $1: results JSON array
# Returns: Merged result
##############################################################################
merge_strategy_weighted() {
    local results="$1"

    echo -e "${MAGENTA}Strategy: WEIGHTED${NC}"

    # Combine recommendations weighted by confidence
    local merged=$(echo "$results" | jq '{
        task_id: .[0].task_id,
        status: "aggregated",
        experts: [.[] | {expert: .expert, confidence: (.confidence // 0), recommendations: .recommendations}],
        primary_recommendation: (max_by(.confidence // 0).recommendations),
        confidence: (map(.confidence // 0) | add / length),
        merge_strategy: "weighted",
        aggregator: "aggregator-master"
    }')

    echo "$merged"
}

##############################################################################
# merge_strategy_sequential: Results flow from one expert to next
# Args:
#   $1: results JSON array
# Returns: Merged result
##############################################################################
merge_strategy_sequential() {
    local results="$1"

    echo -e "${MAGENTA}Strategy: SEQUENTIAL${NC}"

    # Combine results in order, each building on the previous
    local merged=$(echo "$results" | jq '{
        task_id: .[0].task_id,
        status: "aggregated",
        pipeline: [.[] | {expert: .expert, output: .recommendations}],
        final_output: .[-1].recommendations,
        merge_strategy: "sequential",
        aggregator: "aggregator-master"
    }')

    echo "$merged"
}

##############################################################################
# merge_strategy_parallel: Independent results aggregated
# Args:
#   $1: results JSON array
# Returns: Merged result
##############################################################################
merge_strategy_parallel() {
    local results="$1"

    echo -e "${MAGENTA}Strategy: PARALLEL${NC}"

    # Collect all independent results
    local merged=$(echo "$results" | jq '{
        task_id: .[0].task_id,
        status: "aggregated",
        results: [.[] | {expert: .expert, output: .recommendations, confidence: (.confidence // 0)}],
        summary: {
            total_experts: (. | length),
            avg_confidence: (map(.confidence // 0) | add / length)
        },
        merge_strategy: "parallel",
        aggregator: "aggregator-master"
    }')

    echo "$merged"
}

##############################################################################
# merge_expert_results: Main merge function - like MoE merge layer
# Args:
#   $1: task_id
#   $2: strategy (voting|weighted|sequential|parallel)
##############################################################################
merge_expert_results() {
    local task_id="$1"
    local strategy="${2:-auto}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "========================================"
    echo "MoE Aggregator - Merging Expert Results"
    echo "========================================"
    echo "Task ID: $task_id"
    echo "Timestamp: $timestamp"
    echo "Strategy: $strategy"
    echo "----------------------------------------"

    # Collect results from all experts
    local results=$(collect_expert_results "$task_id")
    local num_results=$(echo "$results" | jq 'length')

    echo "Results collected: $num_results"
    echo ""

    if [ "$num_results" -eq 0 ]; then
        echo -e "${YELLOW}No results to merge${NC}"
        return 1
    fi

    # Auto-detect strategy if not specified
    if [ "$strategy" == "auto" ]; then
        if [ "$num_results" -eq 1 ]; then
            strategy="single"
        else
            # Check if results have sequential dependency
            local has_dependency=$(echo "$results" | jq '[.[] | .depends_on] | any')
            if [ "$has_dependency" == "true" ]; then
                strategy="sequential"
            else
                strategy="parallel"
            fi
        fi
        echo -e "${BLUE}Auto-detected strategy: $strategy${NC}"
    fi

    # Apply merge strategy
    local merged_result=""
    case $strategy in
        voting)
            merged_result=$(merge_strategy_voting "$results")
            ;;
        weighted)
            merged_result=$(merge_strategy_weighted "$results")
            ;;
        sequential)
            merged_result=$(merge_strategy_sequential "$results")
            ;;
        parallel)
            merged_result=$(merge_strategy_parallel "$results")
            ;;
        single)
            merged_result=$(echo "$results" | jq '.[0] + {merge_strategy: "single", aggregator: "aggregator-master"}')
            ;;
        *)
            echo -e "${YELLOW}Unknown strategy: $strategy, using parallel${NC}"
            merged_result=$(merge_strategy_parallel "$results")
            ;;
    esac

    # Save merged result
    local output_file="$RESULTS_DIR/${task_id}-merged-$(date +%s).json"
    echo "$merged_result" > "$output_file"

    # Log merge operation
    local log_entry=$(jq -n \
        --arg task_id "$task_id" \
        --arg timestamp "$timestamp" \
        --arg strategy "$strategy" \
        --argjson num_results "$num_results" \
        '{
            task_id: $task_id,
            timestamp: $timestamp,
            operation: "merge",
            strategy: $strategy,
            num_results: $num_results,
            output_file: "'$output_file'"
        }')
    echo "$log_entry" >> "$MERGE_LOG"

    echo "========================================"
    echo -e "${GREEN}Merge Complete${NC}"
    echo "Output: $output_file"
    echo "========================================"
    echo ""

    # Display merged result
    echo "$merged_result" | jq '.'
}

##############################################################################
# Main execution
##############################################################################
if [ $# -lt 1 ]; then
    echo "Usage: $0 <task_id> [strategy]"
    echo ""
    echo "Strategies:"
    echo "  auto       - Auto-detect based on results (default)"
    echo "  voting     - Vote on best solution"
    echo "  weighted   - Weight by confidence"
    echo "  sequential - Pipeline results"
    echo "  parallel   - Independent aggregation"
    echo ""
    echo "Example:"
    echo "  $0 task-001 weighted"
    exit 1
fi

task_id="$1"
strategy="${2:-auto}"

merge_expert_results "$task_id" "$strategy"
