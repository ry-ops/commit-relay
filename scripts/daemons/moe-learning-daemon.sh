#!/bin/bash
# scripts/daemons/moe-learning-daemon.sh
# Continuous MoE Learning Daemon
# Runs learning cycles hourly for rapid model adaptation
#
# Features:
#   - Extracts patterns from training examples every hour
#   - Updates MoE routing model weights
#   - Optimizes utility weights based on outcomes
#   - Tracks improvement metrics continuously
#   - Emits observability events for learning cycles

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load libraries
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
}

source "$COMMIT_RELAY_HOME/scripts/lib/learning-agent/learner.sh"

cd "$COMMIT_RELAY_HOME"

# Daemon configuration
DAEMON_NAME="commit-relay-moe-learning"
LEARNING_INTERVAL="${MOE_LEARNING_INTERVAL:-3600}"  # Default: 1 hour (3600 seconds)
MIN_EXAMPLES="${MOE_MIN_EXAMPLES:-3}"  # Minimum examples for pattern validity
PID_FILE="/tmp/${DAEMON_NAME}.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/moe-learning-daemon.log"
METRICS_DIR="$COMMIT_RELAY_HOME/coordination/metrics/learning"

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$METRICS_DIR"

# Redirect output to log file
exec >> "$LOG_FILE" 2>&1

log_daemon() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_daemon "ERROR: MoE learning daemon already running with PID $OLD_PID"
        exit 1
    else
        log_daemon "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_daemon "=========================================="
log_daemon "MoE Learning Daemon Starting"
log_daemon "=========================================="
log_daemon "PID: $$"
log_daemon "Learning interval: ${LEARNING_INTERVAL}s ($(( LEARNING_INTERVAL / 60 )) minutes)"
log_daemon "Min examples for patterns: $MIN_EXAMPLES"
log_daemon "Working directory: $COMMIT_RELAY_HOME"

# Cleanup on exit
cleanup() {
    log_daemon "MoE learning daemon stopping (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Metrics counters
TOTAL_CYCLES=0
SUCCESSFUL_CYCLES=0
FAILED_CYCLES=0

# ============================================================================
# Learning Cycle Execution
# ============================================================================

run_learning_cycle() {
    local cycle_start=$(date +%s)
    local cycle_id="cycle-$(date +%Y%m%d-%H%M%S)"

    log_daemon "[$cycle_id] Starting learning cycle..."

    # Check for sufficient training data
    local positive_file="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-examples/positive-examples.jsonl"
    local negative_file="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-examples/negative-examples.jsonl"

    local total_examples=0
    if [ -f "$positive_file" ]; then
        total_examples=$((total_examples + $(wc -l < "$positive_file" | tr -d ' ')))
    fi
    if [ -f "$negative_file" ]; then
        total_examples=$((total_examples + $(wc -l < "$negative_file" | tr -d ' ')))
    fi

    log_daemon "[$cycle_id] Found $total_examples training examples"

    if [ "$total_examples" -lt "$MIN_EXAMPLES" ]; then
        log_daemon "[$cycle_id] Insufficient training data (need >= $MIN_EXAMPLES), skipping cycle"
        return 0
    fi

    # Run the learning cycle
    if run_daily_learning 2>&1; then
        local cycle_end=$(date +%s)
        local duration=$((cycle_end - cycle_start))

        SUCCESSFUL_CYCLES=$((SUCCESSFUL_CYCLES + 1))
        log_daemon "[$cycle_id] Learning cycle completed successfully in ${duration}s"

        # Log metrics
        local metrics_file="$METRICS_DIR/continuous-learning-metrics.jsonl"
        echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cycle_id\":\"$cycle_id\",\"status\":\"success\",\"duration_seconds\":$duration,\"training_examples\":$total_examples}" >> "$metrics_file"

        # Check for improvement
        local improvement_file="$METRICS_DIR/improvement-$(date +%Y%m%d).json"
        if [ -f "$improvement_file" ]; then
            local improvement=$(jq -r '.score_improvement_percent // 0' "$improvement_file" 2>/dev/null || echo "0")
            log_daemon "[$cycle_id] Current improvement: ${improvement}%"
        fi

        return 0
    else
        FAILED_CYCLES=$((FAILED_CYCLES + 1))
        log_daemon "[$cycle_id] Learning cycle failed"

        # Log failure
        local metrics_file="$METRICS_DIR/continuous-learning-metrics.jsonl"
        echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cycle_id\":\"$cycle_id\",\"status\":\"failed\",\"training_examples\":$total_examples}" >> "$metrics_file"

        return 1
    fi
}

# ============================================================================
# Main Daemon Loop
# ============================================================================

log_daemon "Starting continuous learning loop..."

while true; do
    TOTAL_CYCLES=$((TOTAL_CYCLES + 1))

    # Run learning cycle
    run_learning_cycle || true

    # Log stats every 10 cycles
    if [ $((TOTAL_CYCLES % 10)) -eq 0 ]; then
        log_daemon "Stats: $TOTAL_CYCLES cycles, $SUCCESSFUL_CYCLES successful, $FAILED_CYCLES failed"
    fi

    # Sleep until next cycle
    log_daemon "Sleeping for ${LEARNING_INTERVAL}s until next learning cycle..."
    sleep "$LEARNING_INTERVAL"
done
