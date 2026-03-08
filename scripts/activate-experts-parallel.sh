#!/bin/bash
# Parallel Expert Activation Script
# Activates multiple master agents in parallel based on MoE routing decisions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOE_ROUTER="$PROJECT_ROOT/coordination/masters/coordinator/lib/moe-router.sh"
HANDOFFS_DIR="$PROJECT_ROOT/coordination/masters/coordinator/handoffs"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

##############################################################################
# activate_master: Spawn a master agent for a specific expert
# Args:
#   $1: expert_name (development|security|inventory)
#   $2: task_id
#   $3: handoff_file
#   $4: is_primary (true|false)
##############################################################################
activate_master() {
    local expert="$1"
    local task_id="$2"
    local handoff_file="$3"
    local is_primary="$4"

    local role="SECONDARY"
    if [ "$is_primary" == "true" ]; then
        role="PRIMARY"
    fi

    echo -e "${BLUE}[$role]${NC} Activating $expert master for task $task_id..."

    # Create handoff with routing metadata
    local handoff_with_metadata=$(jq \
        --arg role "$role" \
        --arg expert "$expert" \
        '. + {routing: {role: $role, expert: $expert}}' \
        "$handoff_file")

    # Write to expert-specific handoff directory
    local expert_handoff="$HANDOFFS_DIR/to-${expert}-${task_id}.json"
    echo "$handoff_with_metadata" > "$expert_handoff"

    echo -e "${GREEN}✓${NC} Created handoff for $expert: $expert_handoff"

    # In a real system, this would trigger the master agent
    # For now, just log the activation
    case $expert in
        development)
            echo "  → Would trigger: ./scripts/run-development-master.sh"
            ;;
        security)
            echo "  → Would trigger: ./scripts/run-security-master.sh"
            ;;
        inventory)
            echo "  → Would trigger: ./scripts/run-inventory-master.sh"
            ;;
    esac
}

##############################################################################
# activate_experts_from_routing: Activate all experts from MoE routing decision
# Args:
#   $1: routing_decision JSON string
#   $2: handoff_file path
##############################################################################
activate_experts_from_routing() {
    local routing_decision="$1"
    local handoff_file="$2"

    # Extract routing info
    local task_id=$(echo "$routing_decision" | jq -r '.task_id')
    local primary_expert=$(echo "$routing_decision" | jq -r '.decision.primary_expert')
    local strategy=$(echo "$routing_decision" | jq -r '.decision.strategy')
    local parallel_experts=$(echo "$routing_decision" | jq -r '.decision.parallel_experts[]' 2>/dev/null || echo "")

    echo "========================================"
    echo "MoE Parallel Expert Activation"
    echo "========================================"
    echo "Task ID: $task_id"
    echo "Strategy: $strategy"
    echo "Primary Expert: $primary_expert"
    echo "----------------------------------------"

    # Activate primary expert
    activate_master "$primary_expert" "$task_id" "$handoff_file" "true" &
    local primary_pid=$!

    # Activate parallel experts (if any)
    local parallel_pids=()
    if [ -n "$parallel_experts" ]; then
        echo -e "${YELLOW}Parallel Experts Detected${NC}"
        while IFS= read -r expert; do
            if [ -n "$expert" ] && [ "$expert" != "null" ]; then
                activate_master "$expert" "$task_id" "$handoff_file" "false" &
                parallel_pids+=($!)
            fi
        done <<< "$parallel_experts"
    fi

    # Wait for all activations to complete
    wait $primary_pid
    for pid in "${parallel_pids[@]}"; do
        wait $pid 2>/dev/null || true
    done

    echo "========================================"
    echo -e "${GREEN}All experts activated successfully${NC}"
    echo "========================================"
}

##############################################################################
# Main execution
##############################################################################
if [ $# -lt 2 ]; then
    echo "Usage: $0 <task_id> <task_description> [handoff_file]"
    echo ""
    echo "Examples:"
    echo "  $0 task-001 'Fix CVE vulnerability in auth module'"
    echo "  $0 task-002 'Implement new API endpoint' /path/to/handoff.json"
    exit 1
fi

task_id="$1"
task_description="$2"
handoff_file="${3:-$HANDOFFS_DIR/default-handoff-${task_id}.json}"

# If handoff file doesn't exist, create a default one
if [ ! -f "$handoff_file" ]; then
    echo "Creating default handoff file..."
    jq -n \
        --arg task_id "$task_id" \
        --arg description "$task_description" \
        --arg timestamp "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
        '{
            task_id: $task_id,
            description: $description,
            timestamp: $timestamp,
            priority: "normal",
            context: {
                requirements: $description
            }
        }' > "$handoff_file"
fi

# Run MoE routing
echo "Running MoE routing analysis..."
routing_decision=$("$MOE_ROUTER" "$task_id" "$task_description")

# Display routing decision
echo ""
echo "$routing_decision" | jq '{
    strategy: .routing_strategy,
    primary: .decision.primary_expert,
    confidence: .decision.primary_confidence,
    parallel: .decision.parallel_experts,
    scores: .decision.scores
}'
echo ""

# Activate experts based on routing
activate_experts_from_routing "$routing_decision" "$handoff_file"
