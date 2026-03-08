#!/bin/bash
# Evaluation Harness for MoE Router
# Runs routing algorithm against golden dataset and evaluates quality with LM-as-Judge

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Paths
GOLDEN_DATASET="$COMMIT_RELAY_HOME/coordination/evaluation/golden-routing-decisions.jsonl"
JUDGE_PROMPT="$COMMIT_RELAY_HOME/coordination/evaluation/prompts/judge-routing-quality.md"
RESULTS_DIR="$COMMIT_RELAY_HOME/coordination/evaluation/results"
MOE_ROUTER="$COMMIT_RELAY_HOME/coordination/masters/coordinator/lib/moe-router.sh"

# LLM Configuration
LLM_API_KEY="${ANTHROPIC_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-claude-sonnet-4-5-20250929}"

# Ensure directories exist
mkdir -p "$RESULTS_DIR"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

##############################################################################
# call_llm_judge: Call Claude to evaluate a routing decision
# Args:
#   $1: routing_evaluation_data (JSON with task, expected, actual routing)
# Returns: JSON evaluation
##############################################################################
call_llm_judge() {
    local eval_data="$1"

    if [ -z "$LLM_API_KEY" ]; then
        echo "Error: ANTHROPIC_API_KEY not set. Cannot run LM-as-Judge evaluation." >&2
        return 1
    fi

    # Read judge prompt
    local judge_prompt=$(cat "$JUDGE_PROMPT")

    # Build full prompt with evaluation data
    local full_prompt=$(cat <<EOF
$judge_prompt

---

# Routing Decision to Evaluate

$eval_data

Please evaluate this routing decision according to the criteria above.
EOF
)

    # Call Claude API
    local response=$(curl -s https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: $LLM_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "{
            \"model\": \"$LLM_MODEL\",
            \"max_tokens\": 2048,
            \"temperature\": 0.3,
            \"messages\": [{
                \"role\": \"user\",
                \"content\": $(echo "$full_prompt" | jq -Rs .)
            }]
        }" 2>/dev/null)

    # Extract content and parse JSON
    local content=$(echo "$response" | jq -r '.content[0].text' 2>/dev/null)

    if [ -z "$content" ] || [ "$content" = "null" ]; then
        echo "Error: Failed to get response from Claude API" >&2
        echo "$response" >&2
        return 1
    fi

    # Extract JSON from response (handle markdown code blocks)
    local json_content=$(echo "$content" | sed -n '/^```json/,/^```/p' | sed '1d;$d')
    if [ -z "$json_content" ]; then
        # Try without code blocks
        json_content="$content"
    fi

    echo "$json_content"
}

##############################################################################
# route_task: Run MoE router on a task description
# Args:
#   $1: task_description
# Returns: JSON with routing decision
##############################################################################
route_task() {
    local task_description="$1"
    local task_id="eval-task-$(date +%s)-$RANDOM"

    # Create temporary task file
    local temp_task=$(mktemp)
    cat > "$temp_task" <<EOF
{
    "task_id": "$task_id",
    "description": "$task_description",
    "type": "evaluation"
}
EOF

    # Run router (source it to use its functions)
    source "$MOE_ROUTER"

    # Call routing function
    local routing_result=$(route_task_moe "$task_id" "$task_description" 2>/dev/null || echo '{}')

    # Clean up
    rm -f "$temp_task"

    echo "$routing_result"
}

##############################################################################
# evaluate_single: Evaluate a single routing decision
# Args:
#   $1: golden_example (JSON from dataset)
# Returns: JSON evaluation result
##############################################################################
evaluate_single() {
    local golden_example="$1"

    # Extract golden data
    local eval_id=$(echo "$golden_example" | jq -r '.eval_id')
    local task_desc=$(echo "$golden_example" | jq -r '.task_description')
    local ideal_expert=$(echo "$golden_example" | jq -r '.ideal_expert')
    local ideal_confidence=$(echo "$golden_example" | jq -r '.ideal_confidence')

    echo -e "${BLUE}Evaluating $eval_id...${NC}" >&2
    echo "Task: $task_desc" >&2

    # Run router
    echo "  Running router..." >&2
    local routing_result=$(route_task "$task_desc")

    if [ -z "$routing_result" ] || [ "$routing_result" = "{}" ]; then
        echo -e "  ${RED}✗ Routing failed${NC}" >&2
        return 1
    fi

    # Extract actual routing
    local actual_expert=$(echo "$routing_result" | jq -r '.primary_expert // "unknown"')
    local actual_confidence=$(echo "$routing_result" | jq -r '.primary_confidence // 0')

    echo "  Routed to: $actual_expert (confidence: $actual_confidence)" >&2
    echo "  Expected: $ideal_expert (confidence: $ideal_confidence)" >&2

    # Build evaluation data for judge
    local eval_data=$(jq -n \
        --arg eval_id "$eval_id" \
        --arg task "$task_desc" \
        --arg ideal_expert "$ideal_expert" \
        --argjson ideal_conf "$ideal_confidence" \
        --arg actual_expert "$actual_expert" \
        --argjson actual_conf "$actual_confidence" \
        --argjson golden "$golden_example" \
        '{
            eval_id: $eval_id,
            task: {
                description: $task,
                characteristics: $golden.task_characteristics
            },
            expected: {
                expert: $ideal_expert,
                confidence: $ideal_conf,
                rationale: $golden.rationale
            },
            actual: {
                expert: $actual_expert,
                confidence: $actual_conf
            }
        }')

    # Call LM-as-Judge
    echo "  Calling LM-as-Judge..." >&2
    local judgment=$(call_llm_judge "$eval_data")

    if [ -z "$judgment" ]; then
        echo -e "  ${RED}✗ Judge evaluation failed${NC}" >&2
        return 1
    fi

    # Extract scores
    local routing_accuracy=$(echo "$judgment" | jq -r '.routing_accuracy // 0')
    local confidence_calibration=$(echo "$judgment" | jq -r '.confidence_calibration // 0')
    local is_optimal=$(echo "$judgment" | jq -r '.is_optimal // false')

    if [ "$is_optimal" = "true" ]; then
        echo -e "  ${GREEN}✓ Optimal routing${NC} (accuracy: $routing_accuracy, calibration: $confidence_calibration)" >&2
    else
        echo -e "  ${YELLOW}⚠ Suboptimal routing${NC} (accuracy: $routing_accuracy, calibration: $confidence_calibration)" >&2
    fi

    # Combine results
    local result=$(jq -n \
        --argjson golden "$golden_example" \
        --argjson routing "$routing_result" \
        --argjson judgment "$judgment" \
        '{
            eval_id: $golden.eval_id,
            golden: $golden,
            actual_routing: $routing,
            judgment: $judgment,
            timestamp: (now | todate)
        }')

    echo "$result"
}

##############################################################################
# run_evaluation: Run full evaluation suite
##############################################################################
run_evaluation() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  MoE Router Evaluation Harness                ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    # Check prerequisites
    if [ ! -f "$GOLDEN_DATASET" ]; then
        echo -e "${RED}Error: Golden dataset not found: $GOLDEN_DATASET${NC}"
        return 1
    fi

    if [ ! -f "$MOE_ROUTER" ]; then
        echo -e "${RED}Error: MoE router not found: $MOE_ROUTER${NC}"
        return 1
    fi

    if [ -z "$LLM_API_KEY" ]; then
        echo -e "${RED}Error: ANTHROPIC_API_KEY not set${NC}"
        echo "Set your API key: export ANTHROPIC_API_KEY=your-key"
        return 1
    fi

    # Count examples
    local total_examples=$(wc -l < "$GOLDEN_DATASET" | tr -d ' ')
    echo "Golden dataset: $total_examples examples"
    echo "Model: $LLM_MODEL"
    echo ""

    # Results storage
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local results_file="$RESULTS_DIR/eval-run-$timestamp.jsonl"
    local summary_file="$RESULTS_DIR/eval-summary-$timestamp.json"

    # Metrics
    local total_evaluated=0
    local total_optimal=0
    local sum_routing_accuracy=0
    local sum_confidence_calibration=0
    local expert_matches=0

    # Evaluate each example
    while IFS= read -r golden_example; do
        local result=$(evaluate_single "$golden_example")

        if [ -n "$result" ]; then
            echo "$result" >> "$results_file"

            # Update metrics
            ((total_evaluated++))

            local routing_accuracy=$(echo "$result" | jq -r '.judgment.routing_accuracy')
            local conf_calibration=$(echo "$result" | jq -r '.judgment.confidence_calibration')
            local is_optimal=$(echo "$result" | jq -r '.judgment.is_optimal')
            local actual_expert=$(echo "$result" | jq -r '.actual_routing.primary_expert')
            local ideal_expert=$(echo "$result" | jq -r '.golden.ideal_expert')

            sum_routing_accuracy=$(echo "$sum_routing_accuracy + $routing_accuracy" | bc)
            sum_confidence_calibration=$(echo "$sum_confidence_calibration + $conf_calibration" | bc)

            if [ "$is_optimal" = "true" ]; then
                ((total_optimal++))
            fi

            if [ "$actual_expert" = "$ideal_expert" ]; then
                ((expert_matches++))
            fi
        fi

        echo "" >&2
    done < "$GOLDEN_DATASET"

    # Calculate aggregate metrics
    local avg_routing_accuracy=$(echo "scale=2; $sum_routing_accuracy / $total_evaluated" | bc)
    local avg_conf_calibration=$(echo "scale=2; $sum_confidence_calibration / $total_evaluated" | bc)
    local expert_match_rate=$(echo "scale=2; ($expert_matches * 100) / $total_evaluated" | bc)
    local optimal_rate=$(echo "scale=2; ($total_optimal * 100) / $total_evaluated" | bc)

    # Generate summary
    local summary=$(jq -n \
        --arg timestamp "$timestamp" \
        --argjson total "$total_evaluated" \
        --argjson optimal "$total_optimal" \
        --argjson expert_matches "$expert_matches" \
        --arg avg_accuracy "$avg_routing_accuracy" \
        --arg avg_calibration "$avg_conf_calibration" \
        --arg expert_rate "$expert_match_rate" \
        --arg optimal_rate "$optimal_rate" \
        '{
            evaluation_run: {
                timestamp: $timestamp,
                model: env.LLM_MODEL,
                dataset_size: $total
            },
            results: {
                total_evaluated: $total,
                optimal_routings: $optimal,
                expert_matches: $expert_matches,
                optimal_rate_percent: $optimal_rate,
                expert_match_rate_percent: $expert_rate
            },
            metrics: {
                avg_routing_accuracy: ($avg_accuracy | tonumber),
                avg_confidence_calibration: ($avg_calibration | tonumber)
            },
            files: {
                detailed_results: $results_file,
                summary: $summary_file
            }
        }' --arg results_file "$results_file" --arg summary_file "$summary_file")

    echo "$summary" > "$summary_file"

    # Print summary
    echo -e "${BLUE}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Evaluation Summary                           ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Total Evaluated: $total_evaluated"
    echo "Optimal Routings: $total_optimal (${optimal_rate}%)"
    echo "Expert Matches: $expert_matches (${expert_match_rate}%)"
    echo ""
    echo "Avg Routing Accuracy: ${avg_routing_accuracy}/100"
    echo "Avg Confidence Calibration: ${avg_conf_calibration}/100"
    echo ""
    echo "Results saved to:"
    echo "  Details: $results_file"
    echo "  Summary: $summary_file"

    # Assessment
    echo ""
    if (( $(echo "$avg_routing_accuracy >= 85" | bc -l) )); then
        echo -e "${GREEN}✓ EXCELLENT routing quality${NC}"
    elif (( $(echo "$avg_routing_accuracy >= 70" | bc -l) )); then
        echo -e "${YELLOW}⚠ GOOD routing quality, room for improvement${NC}"
    else
        echo -e "${RED}✗ POOR routing quality, needs attention${NC}"
    fi
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-run}" in
        run)
            run_evaluation
            ;;
        single)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 single <eval_id>"
                exit 1
            fi
            eval_id="$2"
            golden_example=$(grep "\"eval_id\":\"$eval_id\"" "$GOLDEN_DATASET")
            if [ -z "$golden_example" ]; then
                echo "Error: eval_id not found: $eval_id"
                exit 1
            fi
            evaluate_single "$golden_example"
            ;;
        *)
            echo "Usage: $0 {run|single <eval_id>}"
            exit 1
            ;;
    esac
fi
