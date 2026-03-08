#!/bin/bash
# Sparse Worker Pool Manager - MoE-Inspired Resource Management
# Like MoE activating 1B/7B parameters, only spin up necessary workers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_SPECS_DIR="$PROJECT_ROOT/coordination/worker-specs/active"
POOL_STATE_FILE="$PROJECT_ROOT/coordination/memory/working/pool-state.json"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# MoE-Inspired Configuration (like 1B/7B = ~14% activation)
MAX_WORKER_CAPACITY=64        # Total "parameter" capacity
MIN_ACTIVATION_RATE=10        # Minimum 10% active (6-7 workers)
LIGHT_LOAD_RATE=80            # Light load: 80% (50 workers - increased for governance phases)
MEDIUM_LOAD_RATE=85           # Medium load: 85%
HEAVY_LOAD_RATE=95            # Heavy load: 95%
BUFFER_WORKERS=2              # Extra buffer for spikes

##############################################################################
# get_queue_size: Count pending tasks
##############################################################################
get_queue_size() {
    local queue_file="$PROJECT_ROOT/coordination/task-queue.json"
    if [ -f "$queue_file" ]; then
        jq '[.tasks[] | select(.status == "pending")] | length' "$queue_file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

##############################################################################
# get_active_workers: Count currently active workers
##############################################################################
get_active_workers() {
    if [ -d "$WORKER_SPECS_DIR" ]; then
        find "$WORKER_SPECS_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

##############################################################################
# calculate_activation_rate: Determine optimal worker activation percentage
# Returns: activation percentage (0-100)
##############################################################################
calculate_activation_rate() {
    local queue_size=$1
    local current_workers=$2

    # Calculate load factor
    local load_factor=0
    if [ $MAX_WORKER_CAPACITY -gt 0 ]; then
        load_factor=$((queue_size * 100 / MAX_WORKER_CAPACITY))
    fi

    # Determine activation rate based on load
    local activation_rate=$MIN_ACTIVATION_RATE

    if [ $load_factor -lt 20 ]; then
        # Light load: sparse activation (like MoE 1B/7B)
        activation_rate=$LIGHT_LOAD_RATE
    elif [ $load_factor -lt 50 ]; then
        # Medium load: moderate activation
        activation_rate=$MEDIUM_LOAD_RATE
    elif [ $load_factor -lt 80 ]; then
        # Heavy load: high activation
        activation_rate=$HEAVY_LOAD_RATE
    else
        # Critical load: maximum activation
        activation_rate=100
    fi

    echo $activation_rate
}

##############################################################################
# calculate_target_workers: Compute optimal worker count
##############################################################################
calculate_target_workers() {
    local queue_size=$1
    local activation_rate=$2

    # Base calculation: activate percentage of capacity
    local base_workers=$(( MAX_WORKER_CAPACITY * activation_rate / 100 ))

    # Ensure we have enough for the queue + buffer
    local queue_based_workers=$(( queue_size + BUFFER_WORKERS ))

    # Take the maximum of the two
    local target_workers=$base_workers
    if [ $queue_based_workers -gt $base_workers ]; then
        target_workers=$queue_based_workers
    fi

    # Apply min/max constraints
    local min_workers=$(( MAX_WORKER_CAPACITY * MIN_ACTIVATION_RATE / 100 ))
    if [ $target_workers -lt $min_workers ]; then
        target_workers=$min_workers
    fi
    if [ $target_workers -gt $MAX_WORKER_CAPACITY ]; then
        target_workers=$MAX_WORKER_CAPACITY
    fi

    echo $target_workers
}

##############################################################################
# update_pool_state: Save current pool metrics
##############################################################################
update_pool_state() {
    local queue_size=$1
    local current_workers=$2
    local target_workers=$3
    local activation_rate=$4

    mkdir -p "$(dirname "$POOL_STATE_FILE")"

    local equiv_params=$(echo "scale=2; $current_workers * 7 / $MAX_WORKER_CAPACITY" | bc)

    jq -n \
        --arg timestamp "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
        --argjson queue "$queue_size" \
        --argjson current "$current_workers" \
        --argjson target "$target_workers" \
        --argjson activation "$activation_rate" \
        --argjson capacity "$MAX_WORKER_CAPACITY" \
        --arg active_params "${current_workers} workers (like ${equiv_params}B params)" \
        --arg activation_pct "${activation_rate}%" \
        '{
            timestamp: $timestamp,
            pool_metrics: {
                queue_size: $queue,
                active_workers: $current,
                target_workers: $target,
                max_capacity: $capacity,
                activation_rate: $activation,
                utilization: (($current * 100.0 / $capacity) | floor),
                efficiency: (if $queue > 0 then (($current * 100.0 / $queue) | floor) else 100 end)
            },
            moe_analogy: {
                total_params: "64 workers (like 7B params)",
                active_params: $active_params,
                activation_percentage: $activation_pct
            }
        }' > "$POOL_STATE_FILE"

    # Emit pool state update event
    local event_script="$PROJECT_ROOT/scripts/emit-event.sh"
    if [ -f "$event_script" ]; then
        local event_data=$(jq -nc \
            --argjson current "$current_workers" \
            --argjson target "$target_workers" \
            --argjson activation "$activation_rate" \
            --argjson capacity "$MAX_WORKER_CAPACITY" \
            '{current_workers: $current, target_workers: $target, activation_rate: $activation, max_capacity: $capacity}')
        "$event_script" "moe_pool_updated" "$event_data" "sparse-pool-manager" 2>/dev/null || true
    fi
}

##############################################################################
# scale_worker_pool: Adjust worker count based on load
##############################################################################
scale_worker_pool() {
    local queue_size=$(get_queue_size)
    local current_workers=$(get_active_workers)

    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    Sparse Worker Pool Manager (MoE-Inspired)        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "📊 Current Metrics:"
    echo "   Queue Size: $queue_size tasks"
    echo "   Active Workers: $current_workers / $MAX_WORKER_CAPACITY"
    echo "   Utilization: $(( current_workers * 100 / MAX_WORKER_CAPACITY ))%"
    echo ""

    # Calculate optimal activation
    local activation_rate=$(calculate_activation_rate $queue_size $current_workers)
    local target_workers=$(calculate_target_workers $queue_size $activation_rate)
    local delta=$(( target_workers - current_workers ))

    echo "🎯 MoE Sparse Activation Analysis:"
    echo "   Activation Rate: ${activation_rate}%"
    echo "   Target Workers: $target_workers"
    echo "   Delta: ${delta:+$delta}"
    echo ""

    # MoE Analogy
    local equiv_params=$(echo "scale=2; $current_workers * 7 / $MAX_WORKER_CAPACITY" | bc)
    local target_equiv=$(echo "scale=2; $target_workers * 7 / $MAX_WORKER_CAPACITY" | bc)
    echo "💡 MoE Analogy (if 64 workers = 7B params):"
    echo "   Current: ${current_workers} workers ≈ ${equiv_params}B active params"
    echo "   Target:  ${target_workers} workers ≈ ${target_equiv}B active params"
    echo ""

    # Update state
    update_pool_state $queue_size $current_workers $target_workers $activation_rate

    # Scaling decision
    if [ $delta -gt 0 ]; then
        echo -e "${GREEN}▲ SCALE UP${NC}: Adding $delta workers"
        echo "   Reason: Queue demands higher activation rate"
        # In real system: spawn $delta workers
        echo "   → Would spawn: $delta new workers"
    elif [ $delta -lt 0 ]; then
        echo -e "${YELLOW}▼ SCALE DOWN${NC}: Removing ${delta#-} workers"
        echo "   Reason: Sparse activation - reducing to optimal"
        # In real system: gracefully terminate ${delta#-} workers
        echo "   → Would terminate: ${delta#-} idle workers"
    else
        echo -e "${BLUE}✓ OPTIMAL${NC}: Worker pool at target capacity"
        echo "   Reason: Current workers match activation needs"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show efficiency metrics
    if [ -f "$POOL_STATE_FILE" ]; then
        echo "📈 Pool Efficiency Metrics:"
        jq -r '
            "   Utilization: \(.pool_metrics.utilization)%",
            "   Efficiency: \(.pool_metrics.efficiency)%",
            "   Sparse Activation: \(.pool_metrics.activation_rate)%"
        ' "$POOL_STATE_FILE"
    fi

    return 0
}

##############################################################################
# get_pool_recommendations: Provide scaling recommendations
##############################################################################
get_pool_recommendations() {
    local queue_size=$(get_queue_size)
    local current_workers=$(get_active_workers)
    local activation_rate=$(calculate_activation_rate $queue_size $current_workers)

    echo "💡 Recommendations:"

    if [ $activation_rate -eq $LIGHT_LOAD_RATE ]; then
        echo "   ✓ Light load detected"
        echo "   → Maintain sparse activation (~14% like MoE 1B/7B)"
        echo "   → Optimal for resource efficiency"
    elif [ $activation_rate -eq $MEDIUM_LOAD_RATE ]; then
        echo "   ⚠ Medium load detected"
        echo "   → Moderate activation (~35%)"
        echo "   → Balance between throughput and efficiency"
    elif [ $activation_rate -eq $HEAVY_LOAD_RATE ]; then
        echo "   ⚠️ Heavy load detected"
        echo "   → High activation (~70%)"
        echo "   → Prioritizing throughput"
    else
        echo "   🚨 Critical load detected"
        echo "   → Maximum activation (100%)"
        echo "   → Consider increasing MAX_WORKER_CAPACITY"
    fi
}

##############################################################################
# Main execution
##############################################################################
if [ "${1:-}" == "--monitor" ]; then
    # Continuous monitoring mode
    echo "Starting sparse pool manager in monitor mode..."
    while true; do
        clear
        scale_worker_pool
        get_pool_recommendations
        echo ""
        echo "Next check in 30 seconds... (Ctrl+C to stop)"
        sleep 30
    done
else
    # Single run
    scale_worker_pool
    get_pool_recommendations
fi
