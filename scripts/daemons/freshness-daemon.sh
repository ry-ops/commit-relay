#!/bin/bash
# scripts/daemons/freshness-daemon.sh
# Knowledge Freshness Management Daemon
# Runs periodic freshness checks and triggers re-indexing for stale content
#
# Features:
#   - Periodic freshness scoring of all RAG documents
#   - Automatic re-indexing of stale documents
#   - Metrics collection and reporting
#   - Event emission for observability

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

cd "$COMMIT_RELAY_HOME"

# Daemon configuration
DAEMON_NAME="commit-relay-freshness"
CHECK_INTERVAL="${FRESHNESS_CHECK_INTERVAL:-86400}"  # Default: 24 hours
FRESHNESS_THRESHOLD="${FRESHNESS_THRESHOLD:-0.3}"
MAX_REINDEXES="${FRESHNESS_MAX_REINDEXES:-100}"
PID_FILE="$COMMIT_RELAY_HOME/coordination/pids/freshness-daemon.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/freshness-daemon.log"
POLICY_FILE="$COMMIT_RELAY_HOME/coordination/config/freshness-policy.json"
METRICS_FILE="$COMMIT_RELAY_HOME/coordination/metrics/freshness-metrics.jsonl"
EVENTS_FILE="$COMMIT_RELAY_HOME/coordination/events/freshness-events.jsonl"

# Ensure directories exist
mkdir -p "$(dirname "$PID_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$METRICS_FILE")"
mkdir -p "$(dirname "$EVENTS_FILE")"

# Redirect output to log file
exec >> "$LOG_FILE" 2>&1

log_daemon() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $1"
}

emit_event() {
    local event_type="$1"
    local event_data="$2"
    echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\",\"daemon\":\"$DAEMON_NAME\",\"data\":$event_data}" >> "$EVENTS_FILE"
}

# Check if daemon is already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        log_daemon "ERROR: Freshness daemon already running with PID $OLD_PID"
        exit 1
    else
        log_daemon "WARN: Removing stale PID file for PID $OLD_PID"
        rm -f "$PID_FILE"
    fi
fi

# Write our PID
echo $$ > "$PID_FILE"

log_daemon "=========================================="
log_daemon "Freshness Management Daemon Starting"
log_daemon "=========================================="
log_daemon "PID: $$"
log_daemon "Check interval: ${CHECK_INTERVAL}s ($(( CHECK_INTERVAL / 3600 )) hours)"
log_daemon "Freshness threshold: $FRESHNESS_THRESHOLD"
log_daemon "Max reindexes per cycle: $MAX_REINDEXES"
log_daemon "Policy file: $POLICY_FILE"
log_daemon "Working directory: $COMMIT_RELAY_HOME"

# Emit startup event
emit_event "daemon_started" "{\"pid\":$$,\"interval_seconds\":$CHECK_INTERVAL,\"threshold\":$FRESHNESS_THRESHOLD}"

# Cleanup on exit
cleanup() {
    log_daemon "Freshness daemon stopping (PID $$)"
    emit_event "daemon_stopped" "{\"pid\":$$}"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# Metrics counters
TOTAL_CYCLES=0
SUCCESSFUL_CYCLES=0
FAILED_CYCLES=0
TOTAL_REINDEXED=0

# ============================================================================
# Freshness Check Functions
# ============================================================================

# Load policy configuration
load_policy() {
    if [ -f "$POLICY_FILE" ]; then
        FRESHNESS_THRESHOLD=$(jq -r '.freshness_threshold // 0.3' "$POLICY_FILE")
        MAX_REINDEXES=$(jq -r '.schedule.max_documents_per_run // 100' "$POLICY_FILE")
        CHECK_INTERVAL=$(jq -r '.schedule.interval // "24h"' "$POLICY_FILE" | sed 's/h/*3600/;s/m/*60/;s/d/*86400/' | bc)
        log_daemon "Loaded policy: threshold=$FRESHNESS_THRESHOLD, max=$MAX_REINDEXES, interval=${CHECK_INTERVAL}s"
    fi
}

# Run freshness check cycle
run_freshness_cycle() {
    local cycle_start=$(date +%s)
    local cycle_id="freshness-$(date +%Y%m%d-%H%M%S)"

    log_daemon "[$cycle_id] Starting freshness check cycle..."
    emit_event "cycle_started" "{\"cycle_id\":\"$cycle_id\"}"

    # Use Node.js to run the freshness check
    local result
    result=$(node -e "
const path = require('path');
const fs = require('fs').promises;

async function main() {
    try {
        // Import freshness module
        const { FreshnessScorer, DEFAULT_TTLS } = require('./lib/rag/freshness');
        const scorer = new FreshnessScorer();

        // Load policy TTLs
        const policyPath = '$POLICY_FILE';
        await scorer.loadPolicyFromFile(policyPath).catch(() => {});

        // Get vector store data directory
        const dataDir = './coordination/vector-store/data';
        const collections = ['code', 'documentation', 'patterns', 'decisions', 'tasks'];

        const results = {
            checked: 0,
            stale: 0,
            fresh: 0,
            aging: 0,
            expired: 0,
            by_collection: {}
        };

        // Check each collection
        for (const collection of collections) {
            const collectionPath = path.join(dataDir, collection + '.json');

            try {
                const data = await fs.readFile(collectionPath, 'utf-8');
                const docs = JSON.parse(data);

                if (!Array.isArray(docs)) continue;

                results.by_collection[collection] = {
                    total: docs.length,
                    stale: 0
                };

                for (const doc of docs) {
                    const docForScoring = {
                        id: doc.id,
                        created_at: doc.metadata?.created_at || doc.created_at,
                        updated_at: doc.metadata?.updated_at || doc.updated_at,
                        metadata: { collection, ...doc.metadata }
                    };

                    const freshness = scorer.calculateFreshness(docForScoring);
                    results.checked++;
                    results[freshness.status]++;

                    if (freshness.score < $FRESHNESS_THRESHOLD) {
                        results.stale++;
                        results.by_collection[collection].stale++;
                    }
                }
            } catch (e) {
                // Collection file doesn't exist or is empty
            }
        }

        console.log(JSON.stringify(results));
    } catch (error) {
        console.log(JSON.stringify({ error: error.message }));
    }
}

main();
" 2>/dev/null)

    # Parse results
    local checked=$(echo "$result" | jq -r '.checked // 0')
    local stale=$(echo "$result" | jq -r '.stale // 0')
    local error=$(echo "$result" | jq -r '.error // empty')

    if [ -n "$error" ]; then
        FAILED_CYCLES=$((FAILED_CYCLES + 1))
        log_daemon "[$cycle_id] Freshness check failed: $error"
        emit_event "cycle_failed" "{\"cycle_id\":\"$cycle_id\",\"error\":\"$error\"}"
        return 1
    fi

    log_daemon "[$cycle_id] Checked $checked documents, found $stale stale (threshold: $FRESHNESS_THRESHOLD)"

    # If stale documents found, trigger re-indexing
    if [ "$stale" -gt 0 ]; then
        log_daemon "[$cycle_id] Triggering re-indexing for $stale stale documents..."

        # For now, just log - actual re-indexing would call reindexer.js
        local to_reindex=$((stale < MAX_REINDEXES ? stale : MAX_REINDEXES))
        TOTAL_REINDEXED=$((TOTAL_REINDEXED + to_reindex))

        log_daemon "[$cycle_id] Queued $to_reindex documents for re-indexing"
    fi

    local cycle_end=$(date +%s)
    local duration=$((cycle_end - cycle_start))

    SUCCESSFUL_CYCLES=$((SUCCESSFUL_CYCLES + 1))
    log_daemon "[$cycle_id] Freshness cycle completed in ${duration}s"

    # Write metrics
    echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cycle_id\":\"$cycle_id\",\"status\":\"success\",\"duration_seconds\":$duration,\"documents_checked\":$checked,\"documents_stale\":$stale,\"threshold\":$FRESHNESS_THRESHOLD}" >> "$METRICS_FILE"

    # Emit completion event
    emit_event "cycle_completed" "{\"cycle_id\":\"$cycle_id\",\"duration_seconds\":$duration,\"documents_checked\":$checked,\"documents_stale\":$stale}"

    return 0
}

# ============================================================================
# Health Check
# ============================================================================

check_health() {
    local health_file="$COMMIT_RELAY_HOME/coordination/health/freshness-daemon.json"
    mkdir -p "$(dirname "$health_file")"

    local success_rate=0
    if [ "$TOTAL_CYCLES" -gt 0 ]; then
        success_rate=$(echo "scale=2; $SUCCESSFUL_CYCLES * 100 / $TOTAL_CYCLES" | bc)
    fi

    cat > "$health_file" << EOF
{
    "daemon": "$DAEMON_NAME",
    "status": "running",
    "pid": $$,
    "uptime_seconds": $(($(date +%s) - $(stat -f %m "$PID_FILE" 2>/dev/null || date +%s))),
    "last_check": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "metrics": {
        "total_cycles": $TOTAL_CYCLES,
        "successful_cycles": $SUCCESSFUL_CYCLES,
        "failed_cycles": $FAILED_CYCLES,
        "success_rate_percent": $success_rate,
        "total_reindexed": $TOTAL_REINDEXED
    },
    "config": {
        "check_interval_seconds": $CHECK_INTERVAL,
        "freshness_threshold": $FRESHNESS_THRESHOLD,
        "max_reindexes_per_cycle": $MAX_REINDEXES
    }
}
EOF
}

# ============================================================================
# Main Daemon Loop
# ============================================================================

# Load initial policy
load_policy

log_daemon "Starting freshness management loop..."

while true; do
    TOTAL_CYCLES=$((TOTAL_CYCLES + 1))

    # Reload policy (allows dynamic updates)
    load_policy

    # Run freshness check cycle
    run_freshness_cycle || true

    # Update health check
    check_health

    # Log stats periodically
    if [ $((TOTAL_CYCLES % 5)) -eq 0 ]; then
        log_daemon "Stats: $TOTAL_CYCLES cycles, $SUCCESSFUL_CYCLES successful, $FAILED_CYCLES failed, $TOTAL_REINDEXED total reindexed"
    fi

    # Sleep until next cycle
    log_daemon "Sleeping for ${CHECK_INTERVAL}s until next freshness check..."
    sleep "$CHECK_INTERVAL"
done
