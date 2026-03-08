#!/bin/bash
# scripts/daily-learning-scheduler.sh
# Daily Learning Scheduler
# Week 5: Q1 Implementation - Learning Agent
#
# Purpose: Schedule and execute daily learning cycle
# - Run learner to extract patterns and update models
# - Calculate improvement metrics
# - Generate learning performance reports
#
# Can be run via cron or as a daemon

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

source "$SCRIPT_DIR/lib/learning-agent/learner.sh"

cd "$COMMIT_RELAY_HOME"

LOG_FILE="agents/logs/system/daily-learning-scheduler.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

log_info "=== Daily Learning Scheduler Starting ==="

# Check if already ran today
LAST_RUN_FILE="coordination/metrics/learning/last-daily-run.txt"
mkdir -p "$(dirname "$LAST_RUN_FILE")"

TODAY=$(date +%Y-%m-%d)

if [ -f "$LAST_RUN_FILE" ]; then
    LAST_RUN=$(cat "$LAST_RUN_FILE")
    if [ "$LAST_RUN" = "$TODAY" ]; then
        log_info "Daily learning already ran today ($TODAY), skipping"
        exit 0
    fi
fi

# Run daily learning cycle
log_info "Executing daily learning cycle for $TODAY"

if run_daily_learning; then
    # Record successful run
    echo "$TODAY" > "$LAST_RUN_FILE"
    log_info "Daily learning cycle completed successfully"

    # Generate summary
    IMPROVEMENT_FILE="coordination/metrics/learning/improvement-$(date +%Y%m%d).json"
    if [ -f "$IMPROVEMENT_FILE" ]; then
        IMPROVEMENT=$(cat "$IMPROVEMENT_FILE" | jq -r '.score_improvement_percent // 0')
        log_info "Weekly improvement: ${IMPROVEMENT}%"
    fi
else
    log_error "Daily learning cycle failed"
    exit 1
fi

log_info "=== Daily Learning Scheduler Complete ==="
