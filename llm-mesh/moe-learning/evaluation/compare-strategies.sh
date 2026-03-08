#!/bin/bash
# Routing Strategy A/B Comparison Tool
# Compare two different routing configurations or algorithms

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Paths
EVAL_HARNESS="$SCRIPT_DIR/eval-router.sh"
ROUTING_PATTERNS="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base/routing-patterns.json"
RESULTS_DIR="$COMMIT_RELAY_HOME/coordination/evaluation/results"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

##############################################################################
# backup_config: Backup current routing configuration
##############################################################################
backup_config() {
    local backup_name="${1:-baseline}"
    local backup_dir="$RESULTS_DIR/configs"
    mkdir -p "$backup_dir"

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$backup_dir/routing-patterns-$backup_name-$timestamp.json"

    cp "$ROUTING_PATTERNS" "$backup_file"
    echo "$backup_file"
}

##############################################################################
# restore_config: Restore routing configuration from backup
##############################################################################
restore_config() {
    local backup_file="$1"

    if [ ! -f "$backup_file" ]; then
        echo "Error: Backup file not found: $backup_file" >&2
        return 1
    fi

    cp "$backup_file" "$ROUTING_PATTERNS"
    echo "Restored configuration from: $backup_file"
}

##############################################################################
# run_strategy: Run evaluation with a specific strategy
##############################################################################
run_strategy() {
    local strategy_name="$1"
    local config_file="$2"

    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Running Strategy: $strategy_name${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
    echo ""

    # Backup current config
    local original_config=$(backup_config "temp-original")

    # Apply strategy config
    if [ -f "$config_file" ]; then
        cp "$config_file" "$ROUTING_PATTERNS"
        echo "Applied configuration: $config_file"
    else
        echo "Using current configuration (no file provided)"
    fi

    # Run evaluation
    local eval_output=$(mktemp)
    bash "$EVAL_HARNESS" run 2>&1 | tee "$eval_output"

    # Extract summary file path
    local summary_file=$(grep "Summary:" "$eval_output" | awk '{print $2}')

    # Restore original config
    restore_config "$original_config" > /dev/null
    rm -f "$original_config"
    rm -f "$eval_output"

    echo "$summary_file"
}

##############################################################################
# compare_strategies: Compare two routing strategies
##############################################################################
compare_strategies() {
    local strategy_a_name="$1"
    local strategy_a_config="$2"
    local strategy_b_name="$3"
    local strategy_b_config="$4"

    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  A/B Strategy Comparison                       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Strategy A: $strategy_a_name"
    echo "Strategy B: $strategy_b_name"
    echo ""

    # Run strategy A
    echo ""
    local summary_a=$(run_strategy "$strategy_a_name" "$strategy_a_config")

    echo ""
    echo ""

    # Run strategy B
    echo ""
    local summary_b=$(run_strategy "$strategy_b_name" "$strategy_b_config")

    echo ""
    echo ""

    # Load summaries
    if [ ! -f "$summary_a" ] || [ ! -f "$summary_b" ]; then
        echo -e "${RED}Error: Could not load evaluation summaries${NC}"
        return 1
    fi

    local metrics_a=$(cat "$summary_a")
    local metrics_b=$(cat "$summary_b")

    # Extract metrics
    local accuracy_a=$(echo "$metrics_a" | jq -r '.metrics.avg_routing_accuracy')
    local accuracy_b=$(echo "$metrics_b" | jq -r '.metrics.avg_routing_accuracy')
    local calibration_a=$(echo "$metrics_a" | jq -r '.metrics.avg_confidence_calibration')
    local calibration_b=$(echo "$metrics_b" | jq -r '.metrics.avg_confidence_calibration')
    local optimal_rate_a=$(echo "$metrics_a" | jq -r '.results.optimal_rate_percent')
    local optimal_rate_b=$(echo "$metrics_b" | jq -r '.results.optimal_rate_percent')
    local expert_match_a=$(echo "$metrics_a" | jq -r '.results.expert_match_rate_percent')
    local expert_match_b=$(echo "$metrics_b" | jq -r '.results.expert_match_rate_percent')

    # Calculate deltas
    local accuracy_delta=$(echo "$accuracy_b - $accuracy_a" | bc)
    local calibration_delta=$(echo "$calibration_b - $calibration_a" | bc)
    local optimal_delta=$(echo "$optimal_rate_b - $optimal_rate_a" | bc)
    local expert_delta=$(echo "$expert_match_b - $expert_match_a" | bc)

    # Print comparison
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Comparison Results                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
    echo ""

    printf "%-30s %15s %15s %15s\n" "Metric" "Strategy A" "Strategy B" "Delta"
    printf "%-30s %15s %15s %15s\n" "$(printf '%.0s─' {1..30})" "$(printf '%.0s─' {1..15})" "$(printf '%.0s─' {1..15})" "$(printf '%.0s─' {1..15})"

    printf "%-30s %15.2f %15.2f " "Routing Accuracy" "$accuracy_a" "$accuracy_b"
    format_delta "$accuracy_delta"

    printf "%-30s %15.2f %15.2f " "Confidence Calibration" "$calibration_a" "$calibration_b"
    format_delta "$calibration_delta"

    printf "%-30s %15.2f%% %15.2f%% " "Optimal Rate" "$optimal_rate_a" "$optimal_rate_b"
    format_delta "$optimal_delta"

    printf "%-30s %15.2f%% %15.2f%% " "Expert Match Rate" "$expert_match_a" "$expert_match_b"
    format_delta "$expert_delta"

    echo ""
    echo ""

    # Determine winner
    local a_wins=0
    local b_wins=0

    (( $(echo "$accuracy_delta > 0" | bc -l) )) && ((b_wins++)) || ((a_wins++))
    (( $(echo "$calibration_delta > 0" | bc -l) )) && ((b_wins++)) || ((a_wins++))
    (( $(echo "$optimal_delta > 0" | bc -l) )) && ((b_wins++)) || ((a_wins++))
    (( $(echo "$expert_delta > 0" | bc -l) )) && ((b_wins++)) || ((a_wins++))

    if [ $b_wins -gt $a_wins ]; then
        echo -e "${GREEN}Winner: Strategy B ($strategy_b_name)${NC}"
        echo "Wins $b_wins out of 4 metrics"
    elif [ $a_wins -gt $b_wins ]; then
        echo -e "${GREEN}Winner: Strategy A ($strategy_a_name)${NC}"
        echo "Wins $a_wins out of 4 metrics"
    else
        echo -e "${YELLOW}Tie: Both strategies perform equally${NC}"
    fi

    echo ""
    echo "Strategy A summary: $summary_a"
    echo "Strategy B summary: $summary_b"

    # Generate comparison summary
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local comparison_file="$RESULTS_DIR/comparison-$timestamp.json"

    jq -n \
        --arg timestamp "$timestamp" \
        --arg strategy_a "$strategy_a_name" \
        --arg strategy_b "$strategy_b_name" \
        --argjson metrics_a "$metrics_a" \
        --argjson metrics_b "$metrics_b" \
        --arg accuracy_delta "$accuracy_delta" \
        --arg calibration_delta "$calibration_delta" \
        --arg optimal_delta "$optimal_delta" \
        --arg expert_delta "$expert_delta" \
        --argjson a_wins "$a_wins" \
        --argjson b_wins "$b_wins" \
        '{
            comparison: {
                timestamp: $timestamp,
                strategy_a: {
                    name: $strategy_a,
                    metrics: $metrics_a
                },
                strategy_b: {
                    name: $strategy_b,
                    metrics: $metrics_b
                }
            },
            deltas: {
                accuracy: ($accuracy_delta | tonumber),
                calibration: ($calibration_delta | tonumber),
                optimal_rate: ($optimal_delta | tonumber),
                expert_match: ($expert_delta | tonumber)
            },
            winner: (if $b_wins > $a_wins then $strategy_b elif $a_wins > $b_wins then $strategy_a else "tie" end),
            score: {
                strategy_a_wins: $a_wins,
                strategy_b_wins: $b_wins
            }
        }' > "$comparison_file"

    echo "Comparison saved to: $comparison_file"
}

##############################################################################
# format_delta: Format delta with color coding
##############################################################################
format_delta() {
    local delta="$1"
    local delta_float=$(echo "$delta" | bc)

    if (( $(echo "$delta > 0.5" | bc -l) )); then
        printf "${GREEN}+%.2f${NC}\n" "$delta_float"
    elif (( $(echo "$delta < -0.5" | bc -l) )); then
        printf "${RED}%.2f${NC}\n" "$delta_float"
    else
        printf "${YELLOW}%.2f${NC}\n" "$delta_float"
    fi
}

##############################################################################
# Main execution
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <strategy_a_name> <strategy_a_config> <strategy_b_name> <strategy_b_config>"
        echo ""
        echo "Example:"
        echo "  $0 baseline routing-patterns.json experimental routing-patterns-new.json"
        echo ""
        echo "To compare current config vs a new config:"
        echo "  $0 current \"\" experimental routing-patterns-new.json"
        exit 1
    fi

    strategy_a_name="${1:-current}"
    strategy_a_config="${2:-}"
    strategy_b_name="${3:-experimental}"
    strategy_b_config="${4:-}"

    compare_strategies "$strategy_a_name" "$strategy_a_config" "$strategy_b_name" "$strategy_b_config"
fi
