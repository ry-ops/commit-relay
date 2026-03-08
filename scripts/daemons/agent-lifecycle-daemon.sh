#!/usr/bin/env bash
#
# Agent Lifecycle Management Daemon
# Part of Q2 Week 21-22: Agent Registry & Catalog
#
# Monitors agent health, manages lifecycle transitions, and cleanup
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source libraries
source "$SCRIPT_DIR/../lib/agentstudio/agent-register.sh"
source "$SCRIPT_DIR/../lib/agentstudio/agent-catalog.sh"

# Configuration
readonly CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # seconds
readonly STALE_THRESHOLD="${STALE_THRESHOLD:-300}"  # 5 minutes
readonly UNHEALTHY_THRESHOLD="${UNHEALTHY_THRESHOLD:-600}"  # 10 minutes
readonly AUTO_RETIRE_THRESHOLD="${AUTO_RETIRE_THRESHOLD:-86400}"  # 24 hours

# Daemon state
readonly DAEMON_STATE_FILE="coordination/agentstudio/lifecycle-daemon-state.json"
readonly DAEMON_LOG="coordination/agentstudio/lifecycle-events.jsonl"

#
# Initialize daemon
#
init_daemon() {
    init_registry

    mkdir -p "$(dirname "$DAEMON_STATE_FILE")"
    mkdir -p "$(dirname "$DAEMON_LOG")"

    if [[ ! -f "$DAEMON_STATE_FILE" ]]; then
        cat > "$DAEMON_STATE_FILE" <<EOF
{
  "daemon_id": "agent-lifecycle-daemon",
  "started_at": $(get_timestamp_ms),
  "last_check_at": 0,
  "checks_performed": 0,
  "agents_transitioned": 0,
  "agents_retired": 0,
  "status": "running"
}
EOF
    fi
}

#
# Log lifecycle event
#
log_event() {
    local event_type="$1"
    local agent_id="$2"
    local details="$3"

    local timestamp=$(get_timestamp_ms)

    cat >> "$DAEMON_LOG" <<EOF
{"timestamp":$timestamp,"event_type":"$event_type","agent_id":"$agent_id","details":$details}
EOF
}

#
# Check agent health based on last_seen
#
check_agent_health() {
    local agent_id="$1"
    local agent_data="$2"

    local now=$(get_timestamp_ms)
    local last_seen=$(echo "$agent_data" | jq -r '.last_seen_at // 0')
    local age=$((now - last_seen))
    local age_seconds=$((age / 1000))

    local current_status=$(echo "$agent_data" | jq -r '.status')
    local current_health=$(echo "$agent_data" | jq -r '.health.status')

    local new_status="$current_status"
    local new_health="$current_health"
    local health_message=""

    # Skip retired agents
    if [[ "$current_status" == "retired" ]]; then
        return 0
    fi

    # Check for stale agent (no heartbeat in STALE_THRESHOLD)
    if [[ $age_seconds -gt $STALE_THRESHOLD ]]; then
        if [[ "$current_status" == "active" || "$current_status" == "busy" ]]; then
            new_status="idle"
            health_message="Agent idle: no activity for ${age_seconds}s"
            log_event "status_transition" "$agent_id" "{\"from\":\"$current_status\",\"to\":\"$new_status\",\"reason\":\"stale\"}"
        fi
    fi

    # Check for unhealthy agent (no heartbeat in UNHEALTHY_THRESHOLD)
    if [[ $age_seconds -gt $UNHEALTHY_THRESHOLD ]]; then
        new_health="unhealthy"
        health_message="No heartbeat for ${age_seconds}s"

        if [[ "$current_health" != "unhealthy" ]]; then
            log_event "health_degradation" "$agent_id" "{\"from\":\"$current_health\",\"to\":\"unhealthy\",\"age_seconds\":$age_seconds}"
        fi
    fi

    # Check for auto-retirement (no heartbeat in AUTO_RETIRE_THRESHOLD)
    if [[ $age_seconds -gt $AUTO_RETIRE_THRESHOLD ]]; then
        new_status="retired"
        health_message="Auto-retired: no heartbeat for ${age_seconds}s"
        log_event "auto_retirement" "$agent_id" "{\"age_seconds\":$age_seconds}"

        # Update daemon stats
        local state=$(cat "$DAEMON_STATE_FILE")
        local retired_count=$(echo "$state" | jq -r '.agents_retired // 0')
        state=$(echo "$state" | jq \
            --arg count "$((retired_count + 1))" \
            '.agents_retired = ($count | tonumber)')
        echo "$state" > "$DAEMON_STATE_FILE"
    fi

    # Apply status update if changed
    if [[ "$new_status" != "$current_status" ]]; then
        update_agent_status "$agent_id" "$new_status"

        # Update daemon stats
        local state=$(cat "$DAEMON_STATE_FILE")
        local transitioned=$(echo "$state" | jq -r '.agents_transitioned // 0')
        state=$(echo "$state" | jq \
            --arg count "$((transitioned + 1))" \
            '.agents_transitioned = ($count | tonumber)')
        echo "$state" > "$DAEMON_STATE_FILE"
    fi

    # Apply health update if changed
    if [[ "$new_health" != "$current_health" || -n "$health_message" ]]; then
        local error_count=$(echo "$agent_data" | jq -r '.health.error_count // 0')
        update_health "$agent_id" "$new_health" "$health_message" "$error_count"
    fi
}

#
# Run health checks on all agents
#
run_health_checks() {
    local all_agents=$(list_agents)

    local agent_count=$(echo "$all_agents" | jq 'length')

    if [[ "$agent_count" -eq 0 ]]; then
        return 0
    fi

    echo "$all_agents" | jq -c '.[]' | while IFS= read -r agent_data; do
        local agent_id=$(echo "$agent_data" | jq -r '.agent_id')
        check_agent_health "$agent_id" "$agent_data"
    done

    # Update daemon state
    local state=$(cat "$DAEMON_STATE_FILE")
    local checks=$(echo "$state" | jq -r '.checks_performed // 0')
    local timestamp=$(get_timestamp_ms)

    state=$(echo "$state" | jq \
        --arg checks "$((checks + 1))" \
        --arg ts "$timestamp" \
        '.checks_performed = ($checks | tonumber) | .last_check_at = ($ts | tonumber)')
    echo "$state" > "$DAEMON_STATE_FILE"
}

#
# Cleanup old retired agents
#
cleanup_retired_agents() {
    local retention_days="${1:-30}"
    local retention_ms=$((retention_days * 86400 * 1000))
    local now=$(get_timestamp_ms)
    local cutoff=$((now - retention_ms))

    if [[ ! -d "$RETIRED_DIR" ]]; then
        return 0
    fi

    local retired_files=$(find "$RETIRED_DIR" -name "*.json" -type f 2>/dev/null || echo "")

    if [[ -z "$retired_files" ]]; then
        return 0
    fi

    local cleanup_count=0

    while IFS= read -r agent_file; do
        if [[ -f "$agent_file" ]]; then
            local retired_at=$(cat "$agent_file" | jq -r '.retired_at // 0')

            if [[ $retired_at -gt 0 && $retired_at -lt $cutoff ]]; then
                local agent_id=$(cat "$agent_file" | jq -r '.agent_id')
                rm -f "$agent_file"
                log_event "cleanup" "$agent_id" "{\"retired_at\":$retired_at,\"retention_days\":$retention_days}"
                cleanup_count=$((cleanup_count + 1))
            fi
        fi
    done <<< "$retired_files"

    if [[ $cleanup_count -gt 0 ]]; then
        echo "Cleaned up $cleanup_count retired agent(s)"
    fi
}

#
# Generate health report
#
generate_health_report() {
    local stats=$(get_catalog_stats)
    local timestamp=$(get_timestamp_ms)

    local report=$(jq -n \
        --arg ts "$timestamp" \
        --argjson stats "$stats" \
        '{
            timestamp: ($ts | tonumber),
            statistics: $stats
        }')

    echo "$report" > "coordination/agentstudio/health-report.json"
}

#
# Daemon main loop
#
run_daemon() {
    echo "Agent Lifecycle Daemon starting..."
    echo "Check interval: ${CHECK_INTERVAL}s"
    echo "Stale threshold: ${STALE_THRESHOLD}s"
    echo "Unhealthy threshold: ${UNHEALTHY_THRESHOLD}s"
    echo "Auto-retire threshold: ${AUTO_RETIRE_THRESHOLD}s"

    init_daemon

    local iteration=0

    while true; do
        iteration=$((iteration + 1))

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running health checks (iteration $iteration)..."

        run_health_checks

        # Cleanup retired agents every 100 iterations
        if [[ $((iteration % 100)) -eq 0 ]]; then
            echo "Running cleanup of old retired agents..."
            cleanup_retired_agents 30
        fi

        # Generate health report every 10 iterations
        if [[ $((iteration % 10)) -eq 0 ]]; then
            generate_health_report
        fi

        sleep "$CHECK_INTERVAL"
    done
}

#
# Show daemon status
#
show_status() {
    if [[ -f "$DAEMON_STATE_FILE" ]]; then
        cat "$DAEMON_STATE_FILE" | jq .
    else
        echo "Daemon not initialized"
    fi
}

#
# Main CLI
#
main() {
    local command="${1:-start}"

    case "$command" in
        start)
            run_daemon
            ;;
        status)
            show_status
            ;;
        check-once)
            init_daemon
            run_health_checks
            generate_health_report
            echo "Health check complete"
            ;;
        cleanup)
            local retention_days="${2:-30}"
            cleanup_retired_agents "$retention_days"
            ;;
        help|--help|-h)
            cat <<EOF
Agent Lifecycle Daemon

Usage: $0 <command>

Commands:
  start           Start daemon (runs continuously)
  status          Show daemon status
  check-once      Run single health check
  cleanup [days]  Cleanup retired agents older than N days (default: 30)
  help            Show this help

Environment Variables:
  CHECK_INTERVAL           Check interval in seconds (default: 60)
  STALE_THRESHOLD          Stale agent threshold in seconds (default: 300)
  UNHEALTHY_THRESHOLD      Unhealthy threshold in seconds (default: 600)
  AUTO_RETIRE_THRESHOLD    Auto-retire threshold in seconds (default: 86400)

EOF
            ;;
        *)
            echo "Unknown command: $command"
            exit 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
