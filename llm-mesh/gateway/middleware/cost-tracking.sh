#!/bin/bash
# Cost Tracking Shell Interface
# Provides bash interface to Node.js cost tracking modules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORDINATION_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")/coordination"
METRICS_DIR="$COORDINATION_DIR/metrics"
CONFIG_DIR="$COORDINATION_DIR/config"

# Paths
COST_LOG="$METRICS_DIR/llm-costs.jsonl"
BUDGET_USAGE="$METRICS_DIR/budget-usage.json"
BUDGET_CONFIG="$CONFIG_DIR/token-budgets.json"

##############################################################################
# Pricing table (per million tokens)
##############################################################################
declare -A INPUT_PRICES=(
    ["claude-3-haiku"]="0.25"
    ["claude-haiku"]="0.25"
    ["claude-sonnet-4"]="3.0"
    ["claude-3-sonnet"]="3.0"
    ["claude-opus-4"]="15.0"
    ["gpt-4-turbo"]="10.0"
    ["gpt-4o"]="5.0"
    ["gpt-3.5-turbo"]="0.5"
)

declare -A OUTPUT_PRICES=(
    ["claude-3-haiku"]="1.25"
    ["claude-haiku"]="1.25"
    ["claude-sonnet-4"]="15.0"
    ["claude-3-sonnet"]="15.0"
    ["claude-opus-4"]="75.0"
    ["gpt-4-turbo"]="30.0"
    ["gpt-4o"]="15.0"
    ["gpt-3.5-turbo"]="1.5"
)

##############################################################################
# estimate_tokens: Rough token estimation from text
##############################################################################
estimate_tokens() {
    local text="$1"
    local model="${2:-gpt-3.5-turbo}"

    # Rough estimate: ~4 characters per token
    local char_count=${#text}
    local tokens=$((char_count / 4))

    # Apply Claude adjustment if needed
    if [[ "$model" == *"claude"* ]]; then
        tokens=$(echo "$tokens * 0.9" | bc | cut -d. -f1)
    fi

    echo "$tokens"
}

##############################################################################
# calculate_cost: Calculate cost for API call
##############################################################################
calculate_cost() {
    local model="$1"
    local input_tokens="$2"
    local output_tokens="$3"

    # Get prices (default to 1.0/3.0 if unknown)
    local input_price="${INPUT_PRICES[$model]:-1.0}"
    local output_price="${OUTPUT_PRICES[$model]:-3.0}"

    # Calculate cost (price per million tokens)
    local cost=$(echo "scale=6; ($input_tokens * $input_price / 1000000) + ($output_tokens * $output_price / 1000000)" | bc)

    echo "$cost"
}

##############################################################################
# log_cost: Log cost entry to JSONL
##############################################################################
log_cost() {
    local task_id="${1:-anonymous}"
    local task_type="${2:-unknown}"
    local model="$3"
    local input_tokens="$4"
    local output_tokens="$5"
    local latency_ms="${6:-0}"
    local success="${7:-true}"

    # Calculate cost
    local cost=$(calculate_cost "$model" "$input_tokens" "$output_tokens")
    local total_tokens=$((input_tokens + output_tokens))

    # Determine provider
    local provider="unknown"
    if [[ "$model" == *"claude"* ]]; then
        provider="anthropic"
    elif [[ "$model" == *"gpt"* ]]; then
        provider="openai"
    fi

    # Create log entry
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local entry=$(jq -n \
        --arg ts "$timestamp" \
        --arg tid "$task_id" \
        --arg tt "$task_type" \
        --arg m "$model" \
        --arg p "$provider" \
        --argjson it "$input_tokens" \
        --argjson ot "$output_tokens" \
        --argjson tot "$total_tokens" \
        --argjson c "$cost" \
        --argjson lat "$latency_ms" \
        --argjson suc "$success" \
        '{
            timestamp: $ts,
            task_id: $tid,
            task_type: $tt,
            model: $m,
            provider: $p,
            tokens: {
                input: $it,
                output: $ot,
                total: $tot
            },
            cost: $c,
            latency_ms: $lat,
            success: $suc
        }')

    # Ensure directory exists
    mkdir -p "$METRICS_DIR"

    # Append to log file
    echo "$entry" >> "$COST_LOG"

    echo "$cost"
}

##############################################################################
# check_budget: Check if budget allows estimated usage
##############################################################################
check_budget() {
    local task_id="${1:-anonymous}"
    local estimated_tokens="${2:-1000}"

    # Load budget config
    if [ ! -f "$BUDGET_CONFIG" ]; then
        echo "true"  # Allow if no config
        return 0
    fi

    local task_budget=$(jq -r '.defaults.task.tokens' "$BUDGET_CONFIG")
    local daily_budget=$(jq -r '.defaults.daily.tokens' "$BUDGET_CONFIG")

    # Load current usage
    local task_used=0
    local daily_used=0

    if [ -f "$BUDGET_USAGE" ]; then
        task_used=$(jq -r --arg tid "$task_id" '.tasks[$tid].tokens // 0' "$BUDGET_USAGE")
        daily_used=$(jq -r '.daily.tokens // 0' "$BUDGET_USAGE")
    fi

    # Check limits
    local task_remaining=$((task_budget - task_used))
    local daily_remaining=$((daily_budget - daily_used))

    if [ "$estimated_tokens" -gt "$task_remaining" ]; then
        echo "false:task_exceeded:${task_used}/${task_budget}"
        return 1
    fi

    if [ "$estimated_tokens" -gt "$daily_remaining" ]; then
        echo "false:daily_exceeded:${daily_used}/${daily_budget}"
        return 1
    fi

    echo "true"
    return 0
}

##############################################################################
# record_usage: Record token usage against budgets
##############################################################################
record_usage() {
    local task_id="${1:-anonymous}"
    local tokens="$2"
    local cost="$3"

    local today=$(date +"%Y-%m-%d")

    # Initialize usage file if needed
    if [ ! -f "$BUDGET_USAGE" ]; then
        echo '{
            "tasks": {},
            "sessions": {},
            "daily": {
                "date": "'"$today"'",
                "tokens": 0,
                "cost": 0,
                "calls": 0
            }
        }' > "$BUDGET_USAGE"
    fi

    # Read current usage
    local usage=$(cat "$BUDGET_USAGE")

    # Check if we need to reset daily
    local current_date=$(echo "$usage" | jq -r '.daily.date')
    if [ "$current_date" != "$today" ]; then
        usage=$(echo "$usage" | jq --arg d "$today" '.daily = {date: $d, tokens: 0, cost: 0, calls: 0}')
    fi

    # Update task usage
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    usage=$(echo "$usage" | jq \
        --arg tid "$task_id" \
        --argjson tok "$tokens" \
        --argjson c "$cost" \
        --arg ts "$timestamp" \
        '
        .tasks[$tid] = (
            (.tasks[$tid] // {tokens: 0, cost: 0, calls: 0, created: $ts}) |
            .tokens += $tok |
            .cost += $c |
            .calls += 1 |
            .lastUsed = $ts
        ) |
        .daily.tokens += $tok |
        .daily.cost += $c |
        .daily.calls += 1
        ')

    # Save updated usage
    echo "$usage" > "$BUDGET_USAGE"
}

##############################################################################
# get_daily_summary: Get today's cost summary
##############################################################################
get_daily_summary() {
    if [ ! -f "$COST_LOG" ]; then
        echo '{"total_cost": 0, "total_tokens": 0, "call_count": 0}'
        return
    fi

    local today=$(date +"%Y-%m-%d")

    # Parse log and aggregate today's entries
    grep "\"timestamp\":\"$today" "$COST_LOG" 2>/dev/null | jq -s '
        {
            total_cost: (map(.cost) | add // 0),
            total_tokens: (map(.tokens.total) | add // 0),
            call_count: length,
            by_model: (group_by(.model) | map({
                (.[0].model): {
                    cost: (map(.cost) | add),
                    tokens: (map(.tokens.total) | add),
                    calls: length
                }
            }) | add)
        }
    ' 2>/dev/null || echo '{"total_cost": 0, "total_tokens": 0, "call_count": 0}'
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-help}" in
        estimate)
            # estimate <text> [model]
            estimate_tokens "${2:-}" "${3:-gpt-3.5-turbo}"
            ;;
        cost)
            # cost <model> <input_tokens> <output_tokens>
            calculate_cost "$2" "$3" "$4"
            ;;
        log)
            # log <task_id> <task_type> <model> <input_tokens> <output_tokens> [latency_ms] [success]
            log_cost "$2" "$3" "$4" "$5" "$6" "${7:-0}" "${8:-true}"
            ;;
        check)
            # check <task_id> <estimated_tokens>
            check_budget "$2" "$3"
            ;;
        record)
            # record <task_id> <tokens> <cost>
            record_usage "$2" "$3" "$4"
            ;;
        summary)
            # summary
            get_daily_summary
            ;;
        help|--help|-h)
            cat <<EOF
Cost Tracking Shell Interface

Usage: $0 <command> [args]

Commands:
  estimate <text> [model]
      Estimate tokens for text

  cost <model> <input_tokens> <output_tokens>
      Calculate cost for API call

  log <task_id> <task_type> <model> <input_tokens> <output_tokens> [latency_ms] [success]
      Log cost entry to JSONL

  check <task_id> <estimated_tokens>
      Check if budget allows usage

  record <task_id> <tokens> <cost>
      Record usage against budgets

  summary
      Get daily cost summary

Examples:
  $0 estimate "Hello world" claude-sonnet-4
  $0 cost claude-sonnet-4 1000 500
  $0 log task-001 routing claude-sonnet-4 1000 500 1234 true
  $0 check task-001 5000
  $0 summary
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
fi
