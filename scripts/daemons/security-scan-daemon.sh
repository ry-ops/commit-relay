#!/usr/bin/env bash
# scripts/daemons/security-scan-daemon.sh
# Security Scan Daemon - Scheduled Security Scan Automation
# Triggers scheduled security scans based on policy configuration
#
# Features:
#   - Configurable check interval (default 5 minutes)
#   - Schedule-based scanning (hourly, daily, weekly)
#   - Respects max_concurrent_scans limit
#   - Routes scans through Security Master
#   - Comprehensive metrics collection
#
# Usage:
#   ./scripts/daemons/security-scan-daemon.sh
#   CHECK_INTERVAL=600 ./scripts/daemons/security-scan-daemon.sh
#   or via systemd/launchd for auto-start

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Daemon configuration
DAEMON_NAME="security-scan-daemon"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"  # 5 minutes default

# Paths
POLICY_PATH="$COMMIT_RELAY_HOME/coordination/config/security-scan-policy.json"
SCHEDULE_PATH="$COMMIT_RELAY_HOME/coordination/metrics/security-scan-schedule.json"
METRICS_PATH="$COMMIT_RELAY_HOME/coordination/metrics/security-scan-daemon-metrics.json"
PID_FILE="$COMMIT_RELAY_HOME/coordination/pids/security-scan-daemon.pid"
LOG_FILE="$COMMIT_RELAY_HOME/coordination/metrics/security-scan-daemon.jsonl"
WORKER_POOL="$COMMIT_RELAY_HOME/coordination/worker-pool.json"
SPAWN_WORKER="$COMMIT_RELAY_HOME/scripts/spawn-worker.sh"

# Ensure directories exist
mkdir -p "$(dirname "$PID_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$METRICS_PATH")"
mkdir -p "$(dirname "$SCHEDULE_PATH")"

# Metrics counters (session totals)
SCANS_TRIGGERED=0
SCANS_COMPLETED=0
SCANS_FAILED=0
CYCLE_COUNT=0

# ============================================================================
# Logging Functions
# ============================================================================

log_event() {
    local level="$1"
    local message="$2"
    local extra="${3:-{}}"
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Log to JSONL file
    local log_entry=$(jq -nc \
        --arg ts "$timestamp" \
        --arg lvl "$level" \
        --arg msg "$message" \
        --argjson extra "$extra" \
        '{
            timestamp: $ts,
            level: $lvl,
            daemon: "security-scan-daemon",
            message: $msg,
            extra: $extra
        }')

    echo "$log_entry" >> "$LOG_FILE"

    # Also print to stdout for debugging
    echo "[$timestamp] $level: $message"
}

log_info() {
    log_event "INFO" "$1" "${2:-{}}"
}

log_warn() {
    log_event "WARN" "$1" "${2:-{}}"
}

log_error() {
    log_event "ERROR" "$1" "${2:-{}}"
}

log_success() {
    log_event "SUCCESS" "$1" "${2:-{}}"
}

# ============================================================================
# Initialization Functions
# ============================================================================

init_policy() {
    # Create default policy if it doesn't exist
    if [ ! -f "$POLICY_PATH" ]; then
        log_info "Creating default security scan policy"
        cat > "$POLICY_PATH" <<'EOF'
{
  "version": "1.0.0",
  "last_updated": "2025-11-23T00:00:00-0600",
  "enabled": true,
  "global_settings": {
    "max_concurrent_scans": 3,
    "default_priority": "medium",
    "default_schedule": "daily",
    "token_budget_per_scan": 8000
  },
  "schedules": {
    "hourly": {
      "interval_hours": 1,
      "enabled": true
    },
    "daily": {
      "interval_hours": 24,
      "enabled": true
    },
    "weekly": {
      "interval_hours": 168,
      "enabled": true
    }
  },
  "repositories": [
    {
      "name": "commit-relay",
      "path": ".",
      "schedule": "daily",
      "priority": "high",
      "enabled": true,
      "scan_types": ["dependencies", "secrets", "code"]
    }
  ],
  "scan_types": {
    "dependencies": {
      "enabled": true,
      "description": "Scan for vulnerable dependencies"
    },
    "secrets": {
      "enabled": true,
      "description": "Scan for exposed secrets and credentials"
    },
    "code": {
      "enabled": true,
      "description": "Static code analysis for security issues"
    }
  },
  "notifications": {
    "on_scan_complete": true,
    "on_vulnerabilities_found": true,
    "on_scan_failure": true,
    "channels": ["dashboard", "log"]
  }
}
EOF
    fi
}

init_schedule() {
    # Create schedule file if it doesn't exist
    if [ ! -f "$SCHEDULE_PATH" ]; then
        log_info "Creating initial scan schedule"
        cat > "$SCHEDULE_PATH" <<'EOF'
{
  "version": "1.0.0",
  "last_updated": null,
  "repositories": {}
}
EOF
    fi
}

init_metrics() {
    # Create metrics file if it doesn't exist
    if [ ! -f "$METRICS_PATH" ]; then
        log_info "Creating initial metrics file"
        cat > "$METRICS_PATH" <<'EOF'
{
  "daemon_status": "initializing",
  "started_at": null,
  "last_cycle": null,
  "cycle_count": 0,
  "session_metrics": {
    "scans_triggered": 0,
    "scans_completed": 0,
    "scans_failed": 0
  },
  "lifetime_metrics": {
    "total_scans_triggered": 0,
    "total_scans_completed": 0,
    "total_scans_failed": 0,
    "total_vulnerabilities_found": 0
  },
  "active_scans": [],
  "last_scan_results": {}
}
EOF
    fi
}

# ============================================================================
# Policy Functions
# ============================================================================

check_policy_enabled() {
    if [ ! -f "$POLICY_PATH" ]; then
        return 1
    fi

    local enabled=$(jq -r '.enabled // false' "$POLICY_PATH")
    [ "$enabled" = "true" ]
}

get_max_concurrent_scans() {
    jq -r '.global_settings.max_concurrent_scans // 3' "$POLICY_PATH"
}

get_repositories_from_policy() {
    jq -r '.repositories[] | select(.enabled == true) | .name' "$POLICY_PATH"
}

get_repository_config() {
    local repo_name="$1"
    jq --arg name "$repo_name" '.repositories[] | select(.name == $name)' "$POLICY_PATH"
}

# ============================================================================
# Schedule Functions
# ============================================================================

get_last_scan_time() {
    local repo_name="$1"
    jq -r --arg name "$repo_name" '.repositories[$name].last_scan // "1970-01-01T00:00:00+0000"' "$SCHEDULE_PATH"
}

update_last_scan_time() {
    local repo_name="$1"
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    local tmp_file=$(mktemp)
    jq --arg name "$repo_name" \
       --arg ts "$timestamp" \
       '.repositories[$name] = (.repositories[$name] // {}) |
        .repositories[$name].last_scan = $ts |
        .last_updated = $ts' \
       "$SCHEDULE_PATH" > "$tmp_file"

    mv "$tmp_file" "$SCHEDULE_PATH"
}

get_schedule_interval_seconds() {
    local schedule="$1"

    case "$schedule" in
        hourly)
            echo 3600
            ;;
        daily)
            echo 86400
            ;;
        weekly)
            echo 604800
            ;;
        *)
            # Default to daily
            echo 86400
            ;;
    esac
}

should_scan_repository() {
    local repo_name="$1"

    # Get repository config
    local repo_config=$(get_repository_config "$repo_name")
    if [ -z "$repo_config" ] || [ "$repo_config" = "null" ]; then
        return 1
    fi

    local schedule=$(echo "$repo_config" | jq -r '.schedule // "daily"')
    local last_scan=$(get_last_scan_time "$repo_name")

    # Convert timestamps to epoch
    local last_scan_epoch
    if [ "$last_scan" = "1970-01-01T00:00:00+0000" ] || [ -z "$last_scan" ]; then
        last_scan_epoch=0
    else
        last_scan_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$last_scan" +%s 2>/dev/null || echo "0")
    fi

    local now_epoch=$(date +%s)
    local interval=$(get_schedule_interval_seconds "$schedule")
    local elapsed=$((now_epoch - last_scan_epoch))

    # Return true if elapsed time exceeds interval
    [ "$elapsed" -ge "$interval" ]
}

get_repositories_to_scan() {
    local repos_to_scan=()

    while IFS= read -r repo_name; do
        if should_scan_repository "$repo_name"; then
            repos_to_scan+=("$repo_name")
        fi
    done < <(get_repositories_from_policy)

    # Return repos as newline-separated list
    printf '%s\n' "${repos_to_scan[@]}"
}

# ============================================================================
# Concurrent Scan Management
# ============================================================================

get_active_scan_count() {
    # Count active scan workers
    if [ -f "$WORKER_POOL" ]; then
        jq '[.active_workers[] | select(.worker_type == "scan-worker" and .status != "completed" and .status != "failed")] | length' "$WORKER_POOL" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

within_concurrent_limit() {
    local max_concurrent=$(get_max_concurrent_scans)
    local active_count=$(get_active_scan_count)

    [ "$active_count" -lt "$max_concurrent" ]
}

# ============================================================================
# Scan Triggering
# ============================================================================

trigger_scan() {
    local repo_name="$1"

    # Get repository configuration
    local repo_config=$(get_repository_config "$repo_name")
    local priority=$(echo "$repo_config" | jq -r '.priority // "medium"')
    local scan_types=$(echo "$repo_config" | jq -c '.scan_types // ["dependencies", "secrets", "code"]')
    local repo_path=$(echo "$repo_config" | jq -r '.path // "."')

    # Generate task ID
    local task_id="sec-scan-$(date +%Y%m%d-%H%M%S)-$(echo "$repo_name" | tr '/' '-')"

    log_info "Triggering security scan for repository: $repo_name" \
        "{\"task_id\":\"$task_id\",\"priority\":\"$priority\",\"scan_types\":$scan_types}"

    # Build scope JSON
    local scope_json=$(jq -nc \
        --arg repo "$repo_name" \
        --arg path "$repo_path" \
        --argjson types "$scan_types" \
        '{
            repository: $repo,
            path: $path,
            scan_types: $types,
            description: "Scheduled security scan"
        }')

    # Build context JSON
    local context_json=$(jq -nc \
        --arg task "$task_id" \
        --arg priority "$priority" \
        --arg schedule "scheduled" \
        '{
            parent_task: $task,
            priority: $priority,
            trigger: $schedule,
            daemon: "security-scan-daemon"
        }')

    # Spawn scan worker through Security Master
    if [ -x "$SPAWN_WORKER" ]; then
        local spawn_result
        if spawn_result=$("$SPAWN_WORKER" \
            --type scan-worker \
            --task-id "$task_id" \
            --master security-master \
            --priority "$priority" \
            --scope "$scope_json" \
            --context "$context_json" 2>&1); then

            log_success "Scan worker spawned for $repo_name" \
                "{\"task_id\":\"$task_id\"}"

            # Update schedule with last scan time
            update_last_scan_time "$repo_name"

            # Update metrics
            ((SCANS_TRIGGERED++))

            # Track active scan
            track_active_scan "$task_id" "$repo_name"

            return 0
        else
            log_error "Failed to spawn scan worker for $repo_name" \
                "{\"task_id\":\"$task_id\",\"error\":\"$spawn_result\"}"
            ((SCANS_FAILED++))
            return 1
        fi
    else
        log_error "spawn-worker.sh not found or not executable" \
            "{\"path\":\"$SPAWN_WORKER\"}"
        ((SCANS_FAILED++))
        return 1
    fi
}

track_active_scan() {
    local task_id="$1"
    local repo_name="$2"
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    local tmp_file=$(mktemp)
    jq --arg task_id "$task_id" \
       --arg repo "$repo_name" \
       --arg ts "$timestamp" \
       '.active_scans += [{
            task_id: $task_id,
            repository: $repo,
            started_at: $ts,
            status: "running"
        }]' \
       "$METRICS_PATH" > "$tmp_file"

    mv "$tmp_file" "$METRICS_PATH"
}

# ============================================================================
# Scan Monitoring
# ============================================================================

check_completed_scans() {
    # Check worker pool for completed scan workers
    if [ ! -f "$WORKER_POOL" ]; then
        return
    fi

    # Get list of completed scan workers
    local completed_workers=$(jq -r '.active_workers[] |
        select(.worker_type == "scan-worker" and (.status == "completed" or .status == "failed")) |
        .task_id' "$WORKER_POOL" 2>/dev/null || echo "")

    if [ -z "$completed_workers" ]; then
        return
    fi

    # Process each completed scan
    while IFS= read -r task_id; do
        if [ -z "$task_id" ]; then
            continue
        fi

        # Check if this is one of our triggered scans
        local is_our_scan=$(jq --arg id "$task_id" \
            '[.active_scans[] | select(.task_id == $id)] | length' \
            "$METRICS_PATH" 2>/dev/null || echo "0")

        if [ "$is_our_scan" -gt 0 ]; then
            # Get worker status
            local worker_status=$(jq -r --arg id "$task_id" \
                '.active_workers[] | select(.task_id == $id) | .status' \
                "$WORKER_POOL" 2>/dev/null || echo "unknown")

            if [ "$worker_status" = "completed" ]; then
                ((SCANS_COMPLETED++))
                log_success "Security scan completed" "{\"task_id\":\"$task_id\"}"
            else
                ((SCANS_FAILED++))
                log_error "Security scan failed" "{\"task_id\":\"$task_id\"}"
            fi

            # Remove from active scans
            local tmp_file=$(mktemp)
            jq --arg id "$task_id" \
               '.active_scans = [.active_scans[] | select(.task_id != $id)]' \
               "$METRICS_PATH" > "$tmp_file"
            mv "$tmp_file" "$METRICS_PATH"
        fi
    done <<< "$completed_workers"
}

# ============================================================================
# Metrics Functions
# ============================================================================

update_metrics() {
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Read existing lifetime metrics
    local lifetime_triggered=$(jq -r '.lifetime_metrics.total_scans_triggered // 0' "$METRICS_PATH")
    local lifetime_completed=$(jq -r '.lifetime_metrics.total_scans_completed // 0' "$METRICS_PATH")
    local lifetime_failed=$(jq -r '.lifetime_metrics.total_scans_failed // 0' "$METRICS_PATH")

    # Calculate success rate
    local total_finished=$((SCANS_COMPLETED + SCANS_FAILED))
    local success_rate="0"
    if [ "$total_finished" -gt 0 ]; then
        success_rate=$(echo "scale=4; $SCANS_COMPLETED / $total_finished" | bc)
    fi

    local tmp_file=$(mktemp)
    jq --arg ts "$timestamp" \
       --argjson triggered "$SCANS_TRIGGERED" \
       --argjson completed "$SCANS_COMPLETED" \
       --argjson failed "$SCANS_FAILED" \
       --argjson cycle "$CYCLE_COUNT" \
       --argjson lt_triggered "$((lifetime_triggered + SCANS_TRIGGERED))" \
       --argjson lt_completed "$((lifetime_completed + SCANS_COMPLETED))" \
       --argjson lt_failed "$((lifetime_failed + SCANS_FAILED))" \
       --argjson success_rate "$success_rate" \
       '{
            daemon_status: "running",
            started_at: .started_at,
            last_cycle: $ts,
            cycle_count: $cycle,
            session_metrics: {
                scans_triggered: $triggered,
                scans_completed: $completed,
                scans_failed: $failed,
                success_rate: $success_rate
            },
            lifetime_metrics: {
                total_scans_triggered: $lt_triggered,
                total_scans_completed: $lt_completed,
                total_scans_failed: $lt_failed,
                total_vulnerabilities_found: .lifetime_metrics.total_vulnerabilities_found
            },
            active_scans: .active_scans,
            last_scan_results: .last_scan_results
        }' \
       "$METRICS_PATH" > "$tmp_file"

    mv "$tmp_file" "$METRICS_PATH"
}

# ============================================================================
# PID Management and Cleanup
# ============================================================================

write_pid() {
    echo $$ > "$PID_FILE"
    log_info "PID file written" "{\"pid\":$$,\"file\":\"$PID_FILE\"}"
}

check_duplicate_instance() {
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            log_error "Daemon already running" "{\"existing_pid\":$old_pid}"
            echo "ERROR: Security scan daemon already running with PID $old_pid"
            exit 1
        else
            log_warn "Removing stale PID file" "{\"stale_pid\":$old_pid}"
            rm -f "$PID_FILE"
        fi
    fi
}

cleanup() {
    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)

    log_info "Daemon shutting down" "{\"pid\":$$,\"cycles\":$CYCLE_COUNT}"

    # Update metrics with final status
    local tmp_file=$(mktemp)
    jq --arg ts "$timestamp" \
       '.daemon_status = "stopped" | .stopped_at = $ts' \
       "$METRICS_PATH" > "$tmp_file"
    mv "$tmp_file" "$METRICS_PATH"

    # Remove PID file
    rm -f "$PID_FILE"

    log_info "Cleanup complete"
    exit 0
}

# ============================================================================
# Main Processing Loop
# ============================================================================

main() {
    # Initialize
    log_info "Starting security scan daemon" \
        "{\"pid\":$$,\"check_interval\":$CHECK_INTERVAL}"

    # Check for duplicate instances
    check_duplicate_instance

    # Write PID file
    write_pid

    # Set up signal handlers
    trap cleanup EXIT SIGTERM SIGINT

    # Initialize configuration files
    init_policy
    init_schedule
    init_metrics

    # Record start time in metrics
    local start_time=$(date +%Y-%m-%dT%H:%M:%S%z)
    local tmp_file=$(mktemp)
    jq --arg ts "$start_time" \
       '.daemon_status = "running" | .started_at = $ts' \
       "$METRICS_PATH" > "$tmp_file"
    mv "$tmp_file" "$METRICS_PATH"

    log_info "Daemon initialized successfully" \
        "{\"policy_path\":\"$POLICY_PATH\",\"schedule_path\":\"$SCHEDULE_PATH\"}"

    # Main loop
    while true; do
        ((CYCLE_COUNT++))

        log_info "Starting scan cycle" "{\"cycle\":$CYCLE_COUNT}"

        # Check if policy is enabled
        if ! check_policy_enabled; then
            log_warn "Security scan policy is disabled, skipping cycle"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Check for completed scans from previous cycles
        check_completed_scans

        # Get repositories that need scanning
        local repos_to_scan
        repos_to_scan=$(get_repositories_to_scan)

        if [ -z "$repos_to_scan" ]; then
            log_info "No repositories due for scanning"
        else
            # Process each repository
            while IFS= read -r repo; do
                if [ -z "$repo" ]; then
                    continue
                fi

                # Check concurrent scan limit
                if ! within_concurrent_limit; then
                    log_warn "Concurrent scan limit reached, deferring scan" \
                        "{\"repository\":\"$repo\"}"
                    continue
                fi

                # Trigger scan for repository
                trigger_scan "$repo"

            done <<< "$repos_to_scan"
        fi

        # Update metrics
        update_metrics

        log_info "Cycle complete" \
            "{\"cycle\":$CYCLE_COUNT,\"triggered\":$SCANS_TRIGGERED,\"completed\":$SCANS_COMPLETED,\"failed\":$SCANS_FAILED}"

        # Sleep until next cycle
        sleep "$CHECK_INTERVAL"
    done
}

# Run main function
main "$@"
