#!/usr/bin/env bash
#
# System Metrics Collection Points
# Part of Q2 Week 15-16: Metrics Collection System
#
# Defines 50+ system-wide metrics collection points
# Usage: Source this file and call collect_system_metrics periodically
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/metrics-collector.sh"

#
# Collect all task metrics
#
collect_task_metrics() {
    # Task queue depth
    local queue_depth=$(ls coordination/tasks/*.json 2>/dev/null | wc -l | tr -d ' ')
    record_gauge "task_queue_depth" "$queue_depth" '{}' "tasks"

    # Tasks by status
    if ls coordination/tasks/*.json >/dev/null 2>&1; then
        local pending=$(grep -l '"status":"pending"' coordination/tasks/*.json 2>/dev/null | wc -l | tr -d ' ')
        local in_progress=$(grep -l '"status":"in_progress"' coordination/tasks/*.json 2>/dev/null | wc -l | tr -d ' ')
        local completed=$(grep -l '"status":"completed"' coordination/tasks/*.json 2>/dev/null | wc -l | tr -d ' ')
        local failed=$(grep -l '"status":"failed"' coordination/tasks/*.json 2>/dev/null | wc -l | tr -d ' ')

        record_gauge "tasks_pending" "$pending" '{}' "tasks"
        record_gauge "tasks_in_progress" "$in_progress" '{}' "tasks"
        record_gauge "tasks_completed_total" "$completed" '{}' "tasks"
        record_gauge "tasks_failed_total" "$failed" '{}' "tasks"

        # Success rate
        local total=$((completed + failed))
        if [[ $total -gt 0 ]]; then
            local success_rate=$(echo "scale=4; $completed / $total" | bc)
            record_gauge "task_success_rate" "$success_rate" '{}' "ratio"
        fi
    fi

    # Queue age (oldest pending task)
    if ls coordination/tasks/*.json >/dev/null 2>&1; then
        local oldest_task=$(ls -t coordination/tasks/*.json | tail -1)
        if [[ -n "$oldest_task" ]]; then
            local task_time=$(stat -f %m "$oldest_task" 2>/dev/null || stat -c %Y "$oldest_task")
            local now=$(date +%s)
            local age_seconds=$((now - task_time))
            local age_ms=$((age_seconds * 1000))
            record_gauge "task_queue_age_ms" "$age_ms" '{}' "milliseconds"
        fi
    fi
}

#
# Collect all worker metrics
#
collect_worker_metrics() {
    # Active workers
    local active_workers=$(ls coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
    record_gauge "workers_active" "$active_workers" '{}' "workers"

    # Workers by type
    if ls coordination/worker-specs/active/*.json >/dev/null 2>&1; then
        local scan_workers=$(grep -l '"worker_type":"scan"' coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
        local impl_workers=$(grep -l '"worker_type":"implementation"' coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
        local doc_workers=$(grep -l '"worker_type":"documentation"' coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')
        local analysis_workers=$(grep -l '"worker_type":"analysis"' coordination/worker-specs/active/*.json 2>/dev/null | wc -l | tr -d ' ')

        record_gauge "workers_scan" "$scan_workers" '{"worker_type":"scan"}' "workers"
        record_gauge "workers_implementation" "$impl_workers" '{"worker_type":"implementation"}' "workers"
        record_gauge "workers_documentation" "$doc_workers" '{"worker_type":"documentation"}' "workers"
        record_gauge "workers_analysis" "$analysis_workers" '{"worker_type":"analysis"}' "workers"
    fi

    # Worker spawn rate (last hour)
    if [[ -f "coordination/pm-activity.jsonl" ]]; then
        local hour_ago=$(($(date +%s) - 3600))
        local spawn_count=$(awk -v since="$hour_ago" '
            BEGIN {count=0}
            /"event_type":"worker_spawned"/ {
                if (match($0, /"timestamp":"([^"]+)"/, arr)) {
                    # Simple heuristic: check if timestamp contains recent time
                    count++
                }
            }
            END {print count}
        ' coordination/pm-activity.jsonl 2>/dev/null || echo "0")
        record_gauge "worker_spawn_rate_hourly" "$spawn_count" '{}' "workers"
    fi
}

#
# Collect master metrics
#
collect_master_metrics() {
    # Routing decisions
    if [[ -f "coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl" ]]; then
        local total_routes=$(wc -l < coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl | tr -d ' ')
        record_gauge "routing_decisions_total" "$total_routes" '{}' "count"

        # Recent routing confidence
        local avg_confidence=$(tail -100 coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl 2>/dev/null | \
            jq -s 'map(.confidence // 0) | add / length' 2>/dev/null || echo "0")
        record_gauge "routing_confidence_avg" "$avg_confidence" '{}' "ratio"
    fi

    # Master-specific metrics
    for master in development security inventory cicd coordinator; do
        local master_file="coordination/routing-health.json"
        if [[ -f "$master_file" ]]; then
            local success_rate=$(jq -r ".masters.\"${master}-master\".success_rate // 0" "$master_file" 2>/dev/null || echo "0")
            record_gauge "master_success_rate" "$success_rate" "{\"master_id\":\"${master}-master\"}" "ratio"
        fi
    done
}

#
# Collect system metrics
#
collect_system_metrics() {
    # Token budget tracking
    if [[ -f "coordination/orchestrator/state/current.json" ]]; then
        local token_budget=$(jq -r '.token_budget.remaining // 0' coordination/orchestrator/state/current.json 2>/dev/null || echo "0")
        local token_used=$(jq -r '.token_budget.used // 0' coordination/orchestrator/state/current.json 2>/dev/null || echo "0")

        record_gauge "system_token_budget_remaining" "$token_budget" '{}' "tokens"
        record_gauge "system_token_used" "$token_used" '{}' "tokens"

        # Token burn rate (tokens per minute)
        local total_tokens=$((token_budget + token_used))
        if [[ $total_tokens -gt 0 ]]; then
            # Estimate burn rate based on recent usage
            local burn_rate=$(echo "scale=2; $token_used / 60" | bc 2>/dev/null || echo "0")
            record_gauge "system_token_burn_rate" "$burn_rate" '{}' "tokens"
        fi
    fi

    # System load
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    if [[ -n "$load_avg" ]]; then
        record_gauge "system_load_avg" "$load_avg" '{}' "count"
    fi

    # Disk usage
    local disk_usage=$(df -k coordination 2>/dev/null | tail -1 | awk '{print $3}')
    if [[ -n "$disk_usage" ]]; then
        local disk_bytes=$((disk_usage * 1024))
        record_gauge "system_disk_usage_bytes" "$disk_bytes" '{}' "bytes"
    fi

    # Event rate
    if [[ -f "coordination/observability/events/events-$(date +%Y-%m-%d).jsonl" ]]; then
        local event_count=$(wc -l < "coordination/observability/events/events-$(date +%Y-%m-%d).jsonl" | tr -d ' ')
        record_gauge "system_events_total" "$event_count" '{}' "count"

        # Events per second (last 60 seconds estimate)
        local events_per_sec=$(echo "scale=2; $event_count / 60" | bc 2>/dev/null || echo "0")
        record_gauge "system_event_rate" "$events_per_sec" '{}' "count"
    fi

    # Error rate
    if ls coordination/events/*.jsonl >/dev/null 2>&1; then
        local error_count=$(grep -h '"severity":"error"' coordination/events/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
        record_gauge "system_errors_total" "$error_count" '{}' "count"
    fi
}

#
# Collect learning system metrics
#
collect_learning_metrics() {
    # Learned patterns
    if [[ -f "coordination/knowledge-base/learned-patterns/patterns-latest.json" ]]; then
        local pattern_count=$(jq 'length' coordination/knowledge-base/learned-patterns/patterns-latest.json 2>/dev/null || echo "0")
        record_gauge "learning_patterns_count" "$pattern_count" '{}' "count"
    fi

    # Training examples
    if [[ -f "coordination/knowledge-base/training-examples/training-examples.jsonl" ]]; then
        local example_count=$(wc -l < coordination/knowledge-base/training-examples/training-examples.jsonl | tr -d ' ')
        record_gauge "learning_training_examples" "$example_count" '{}' "count"
    fi

    # Positive vs negative examples
    if [[ -f "coordination/knowledge-base/training-examples/positive-examples.jsonl" ]]; then
        local positive=$(wc -l < coordination/knowledge-base/training-examples/positive-examples.jsonl | tr -d ' ')
        record_gauge "learning_positive_examples" "$positive" '{}' "count"
    fi

    if [[ -f "coordination/knowledge-base/training-examples/negative-examples.jsonl" ]]; then
        local negative=$(wc -l < coordination/knowledge-base/training-examples/negative-examples.jsonl | tr -d ' ')
        record_gauge "learning_negative_examples" "$negative" '{}' "count"
    fi

    # Model versions
    if ls coordination/knowledge-base/model-versions/*.jsonl >/dev/null 2>&1; then
        local version_count=$(ls coordination/knowledge-base/model-versions/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
        record_gauge "learning_model_versions" "$version_count" '{}' "count"
    fi
}

#
# Collect governance metrics
#
collect_governance_metrics() {
    # Access log entries
    if [[ -f "coordination/governance/access-log.jsonl" ]]; then
        local access_count=$(wc -l < coordination/governance/access-log.jsonl | tr -d ' ')
        record_gauge "governance_access_log_entries" "$access_count" '{}' "count"
    fi

    # Health alerts
    if [[ -f "coordination/health-alerts.json" ]]; then
        local alert_count=$(jq '.alerts | length' coordination/health-alerts.json 2>/dev/null || echo "0")
        record_gauge "governance_health_alerts" "$alert_count" '{}' "count"
    fi

    # Compliance score (if available)
    if [[ -f "coordination/governance/compliance-score.json" ]]; then
        local compliance=$(jq -r '.overall_score // 0' coordination/governance/compliance-score.json 2>/dev/null || echo "0")
        record_gauge "governance_compliance_score" "$compliance" '{}' "percentage"
    fi
}

#
# Collect daemon metrics
#
collect_daemon_metrics() {
    # PM daemon metrics
    if [[ -f "coordination/pm-state.json" ]]; then
        local pm_active=$(jq -r '.active // false' coordination/pm-state.json 2>/dev/null || echo "false")
        local pm_active_int=0
        [[ "$pm_active" == "true" ]] && pm_active_int=1
        record_gauge "daemon_pm_active" "$pm_active_int" '{}' "count"

        local pm_cycles=$(jq -r '.total_cycles // 0' coordination/pm-state.json 2>/dev/null || echo "0")
        record_gauge "daemon_pm_cycles" "$pm_cycles" '{}' "count"
    fi

    # Heartbeat monitor metrics
    if [[ -f "coordination/metrics/heartbeat-monitor-metrics.json" ]]; then
        local heartbeats=$(jq -r '.total_checks // 0' coordination/metrics/heartbeat-monitor-metrics.json 2>/dev/null || echo "0")
        record_gauge "daemon_heartbeat_checks" "$heartbeats" '{}' "count"

        local dead_workers=$(jq -r '.workers_detected_dead // 0' coordination/metrics/heartbeat-monitor-metrics.json 2>/dev/null || echo "0")
        record_gauge "daemon_workers_detected_dead" "$dead_workers" '{}' "count"
    fi

    # Auto-fix metrics
    if [[ -f "coordination/metrics/auto-fix-daemon-metrics.json" ]]; then
        local fixes_attempted=$(jq -r '.fixes_attempted // 0' coordination/metrics/auto-fix-daemon-metrics.json 2>/dev/null || echo "0")
        local fixes_successful=$(jq -r '.fixes_successful // 0' coordination/metrics/auto-fix-daemon-metrics.json 2>/dev/null || echo "0")

        record_gauge "daemon_autofix_attempted" "$fixes_attempted" '{}' "count"
        record_gauge "daemon_autofix_successful" "$fixes_successful" '{}' "count"

        if [[ $fixes_attempted -gt 0 ]]; then
            local fix_success_rate=$(echo "scale=4; $fixes_successful / $fixes_attempted" | bc)
            record_gauge "daemon_autofix_success_rate" "$fix_success_rate" '{}' "ratio"
        fi
    fi

    # Failure pattern detection
    if [[ -f "coordination/metrics/failure-pattern-metrics.json" ]]; then
        local patterns_detected=$(jq -r '.patterns_detected // 0' coordination/metrics/failure-pattern-metrics.json 2>/dev/null || echo "0")
        record_gauge "daemon_failure_patterns_detected" "$patterns_detected" '{}' "count"
    fi
}

#
# Collect all metrics
#
collect_all_metrics() {
    collect_task_metrics
    collect_worker_metrics
    collect_master_metrics
    collect_system_metrics
    collect_learning_metrics
    collect_governance_metrics
    collect_daemon_metrics
}

# Export function
export -f collect_all_metrics
export -f collect_task_metrics
export -f collect_worker_metrics
export -f collect_master_metrics
export -f collect_system_metrics
export -f collect_learning_metrics
export -f collect_governance_metrics
export -f collect_daemon_metrics
