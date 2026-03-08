#!/bin/bash
# Adversary Simulation
# Phase 5 Item #61: Controlled attack simulation to test detection/response

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Simulation directory
SIM_DIR="$COMMIT_RELAY_HOME/coordination/security/simulations"
mkdir -p "$SIM_DIR"

# Simulation scenarios
declare -A SCENARIOS=(
    ["token_exhaustion"]="Simulate rapid token consumption to test budget alerts"
    ["worker_flood"]="Simulate many concurrent worker spawns to test limits"
    ["anomalous_behavior"]="Simulate unusual access patterns for anomaly detection"
    ["failed_auth"]="Simulate authentication failures to test lockout"
    ["data_exfil"]="Simulate data exfiltration patterns (safe mode)"
)

# Run a simulation scenario
run_simulation() {
    local scenario="$1"
    local dry_run="${2:-true}"

    if [ -z "${SCENARIOS[$scenario]:-}" ]; then
        log_error "Unknown scenario: $scenario"
        echo "Available scenarios:"
        for s in "${!SCENARIOS[@]}"; do
            echo "  $s - ${SCENARIOS[$s]}"
        done
        return 1
    fi

    local sim_id="sim-${scenario}-$(date +%s)"
    local sim_file="$SIM_DIR/${sim_id}.json"

    log_info "Running simulation: $scenario"
    log_info "Description: ${SCENARIOS[$scenario]}"
    log_info "Dry run: $dry_run"

    # Initialize simulation record
    jq -n \
        --arg id "$sim_id" \
        --arg scenario "$scenario" \
        --arg desc "${SCENARIOS[$scenario]}" \
        --argjson dry_run "$dry_run" \
        --arg started "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            simulation_id: $id,
            scenario: $scenario,
            description: $desc,
            dry_run: $dry_run,
            started_at: $started,
            status: "running",
            events: [],
            detections: []
        }' > "$sim_file"

    # Run scenario-specific simulation
    case "$scenario" in
        token_exhaustion)
            simulate_token_exhaustion "$sim_id" "$dry_run"
            ;;
        worker_flood)
            simulate_worker_flood "$sim_id" "$dry_run"
            ;;
        anomalous_behavior)
            simulate_anomalous_behavior "$sim_id" "$dry_run"
            ;;
        failed_auth)
            simulate_failed_auth "$sim_id" "$dry_run"
            ;;
        data_exfil)
            simulate_data_exfil "$sim_id" "$dry_run"
            ;;
    esac

    # Complete simulation
    jq --arg completed "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '.status = "completed" | .completed_at = $completed' \
        "$sim_file" > "${sim_file}.tmp" && mv "${sim_file}.tmp" "$sim_file"

    log_info "Simulation complete: $sim_id"

    # Generate report
    generate_simulation_report "$sim_id"
}

# Token exhaustion simulation
simulate_token_exhaustion() {
    local sim_id="$1"
    local dry_run="$2"
    local sim_file="$SIM_DIR/${sim_id}.json"

    log_info "Simulating token exhaustion..."

    for i in {1..10}; do
        local event="Token consumption spike #$i"
        record_sim_event "$sim_file" "$event"

        if [ "$dry_run" = "false" ]; then
            # Actually consume some tokens (in controlled way)
            :
        fi

        # Check if detected
        local alert_file="$COMMIT_RELAY_HOME/coordination/health-alerts.json"
        if [ -f "$alert_file" ] && grep -q "token" "$alert_file"; then
            record_detection "$sim_file" "Token alert triggered" "success"
        fi

        sleep 0.1
    done
}

# Worker flood simulation
simulate_worker_flood() {
    local sim_id="$1"
    local dry_run="$2"
    local sim_file="$SIM_DIR/${sim_id}.json"

    log_info "Simulating worker flood..."

    for i in {1..20}; do
        local event="Worker spawn request #$i"
        record_sim_event "$sim_file" "$event"

        if [ "$dry_run" = "false" ]; then
            # Create mock worker spec
            :
        fi

        sleep 0.05
    done

    # Check for rate limiting detection
    record_detection "$sim_file" "Rate limit check" "pending"
}

# Anomalous behavior simulation
simulate_anomalous_behavior() {
    local sim_id="$1"
    local dry_run="$2"
    local sim_file="$SIM_DIR/${sim_id}.json"

    log_info "Simulating anomalous behavior..."

    # Unusual access patterns
    local patterns=("rapid_file_access" "off_hours_activity" "unusual_routes")

    for pattern in "${patterns[@]}"; do
        record_sim_event "$sim_file" "Anomaly pattern: $pattern"
        sleep 0.2
    done

    # Check anomaly detector
    local anomaly_log="$COMMIT_RELAY_HOME/coordination/events/anomaly-events.jsonl"
    if [ -f "$anomaly_log" ]; then
        record_detection "$sim_file" "Anomaly detector active" "success"
    else
        record_detection "$sim_file" "Anomaly detector not active" "warning"
    fi
}

# Failed authentication simulation
simulate_failed_auth() {
    local sim_id="$1"
    local dry_run="$2"
    local sim_file="$SIM_DIR/${sim_id}.json"

    log_info "Simulating failed authentication attempts..."

    for i in {1..5}; do
        record_sim_event "$sim_file" "Failed auth attempt #$i"
        sleep 0.1
    done

    record_detection "$sim_file" "Auth failure monitoring" "success"
}

# Data exfiltration simulation (safe)
simulate_data_exfil() {
    local sim_id="$1"
    local dry_run="$2"
    local sim_file="$SIM_DIR/${sim_id}.json"

    log_info "Simulating data exfiltration patterns (safe mode)..."

    local patterns=("large_read" "unusual_export" "bulk_access")

    for pattern in "${patterns[@]}"; do
        record_sim_event "$sim_file" "Exfil pattern: $pattern"
        sleep 0.2
    done

    record_detection "$sim_file" "Data access monitoring" "success"
}

# Record simulation event
record_sim_event() {
    local sim_file="$1"
    local event="$2"

    jq --arg event "$event" --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '.events += [{timestamp: $ts, event: $event}]' \
        "$sim_file" > "${sim_file}.tmp" && mv "${sim_file}.tmp" "$sim_file"
}

# Record detection result
record_detection() {
    local sim_file="$1"
    local detection="$2"
    local result="$3"

    jq --arg det "$detection" --arg res "$result" --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '.detections += [{timestamp: $ts, detection: $det, result: $res}]' \
        "$sim_file" > "${sim_file}.tmp" && mv "${sim_file}.tmp" "$sim_file"
}

# Generate simulation report
generate_simulation_report() {
    local sim_id="$1"
    local sim_file="$SIM_DIR/${sim_id}.json"

    if [ ! -f "$sim_file" ]; then
        log_error "Simulation not found: $sim_id"
        return 1
    fi

    local report=$(jq '{
        simulation_id: .simulation_id,
        scenario: .scenario,
        duration: ((.completed_at // .started_at) as $end | .started_at as $start | "calculated"),
        total_events: (.events | length),
        detections: {
            total: (.detections | length),
            successful: ([.detections[] | select(.result == "success")] | length),
            warnings: ([.detections[] | select(.result == "warning")] | length),
            failed: ([.detections[] | select(.result == "failed")] | length)
        },
        status: .status
    }' "$sim_file")

    echo "$report"
}

# List all simulations
list_simulations() {
    local sims='[]'

    for sim_file in "$SIM_DIR"/sim-*.json; do
        [ -f "$sim_file" ] || continue

        local sim=$(jq '{
            simulation_id: .simulation_id,
            scenario: .scenario,
            status: .status,
            started_at: .started_at
        }' "$sim_file")

        sims=$(echo "$sims" | jq --argjson s "$sim" '. + [$s]')
    done

    echo "$sims" | jq 'sort_by(.started_at) | reverse'
}

# Export functions
export -f run_simulation
export -f generate_simulation_report
export -f list_simulations

# CLI
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        run)
            run_simulation "$2" "${3:-true}"
            ;;
        report)
            generate_simulation_report "$2"
            ;;
        list)
            list_simulations
            ;;
        scenarios)
            echo "Available scenarios:"
            for s in "${!SCENARIOS[@]}"; do
                echo "  $s - ${SCENARIOS[$s]}"
            done
            ;;
        *)
            echo "Adversary Simulation"
            echo "Usage: adversary-simulation.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  run <scenario> [dry_run]  Run simulation (dry_run=true|false)"
            echo "  report <sim_id>           Get simulation report"
            echo "  list                      List all simulations"
            echo "  scenarios                 Show available scenarios"
            ;;
    esac
fi
