#!/usr/bin/env bash
#
# Agentstudio Cross-System Connectors
# Part of Q2 Week 28: Integration & Polish
#
# Connects Agentstudio with observability, coordination, and governance systems
#

set -euo pipefail

if [[ -z "${CONNECTORS_LOADED:-}" ]]; then
    readonly CONNECTORS_LOADED=true
fi

# Directory setup
readonly COORDINATION_DIR="${COORDINATION_DIR:-coordination}"
readonly DASHBOARD_EVENTS="${COORDINATION_DIR}/dashboard-events.jsonl"
readonly METRICS_SNAPSHOTS="${COORDINATION_DIR}/metrics-snapshots.jsonl"
readonly HEALTH_REPORTS="${COORDINATION_DIR}/health-reports.jsonl"

#
# Get timestamp in milliseconds
#
_get_timestamp_ms() {
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

# =============================================================================
# OBSERVABILITY CONNECTORS
# =============================================================================

#
# Emit dashboard event for agent operations
#
emit_agent_event() {
    local event_type="$1"
    local agent_id="$2"
    local details="${3:-{}}"

    local timestamp=$(_get_timestamp_ms)

    local event=$(cat <<EOF
{
  "timestamp": $timestamp,
  "type": "agentstudio",
  "subtype": "$event_type",
  "agent_id": "$agent_id",
  "details": $details
}
EOF
)

    echo "$event" >> "$DASHBOARD_EVENTS"
}

#
# Emit agent registration event
#
emit_agent_registered() {
    local agent_id="$1"
    local agent_name="$2"
    local agent_class="$3"

    local details=$(cat <<EOF
{
  "name": "$agent_name",
  "class": "$agent_class",
  "action": "registered"
}
EOF
)

    emit_agent_event "agent_registered" "$agent_id" "$details"
}

#
# Emit agent deployment event
#
emit_agent_deployed() {
    local agent_id="$1"
    local version="$2"
    local environment="$3"
    local instances="$4"

    local details=$(cat <<EOF
{
  "version": "$version",
  "environment": "$environment",
  "instances": $instances,
  "action": "deployed"
}
EOF
)

    emit_agent_event "agent_deployed" "$agent_id" "$details"
}

#
# Emit agent rollback event
#
emit_agent_rollback() {
    local agent_id="$1"
    local from_version="$2"
    local to_version="$3"
    local reason="$4"

    local details=$(cat <<EOF
{
  "from_version": "$from_version",
  "to_version": "$to_version",
  "reason": "$reason",
  "action": "rollback"
}
EOF
)

    emit_agent_event "agent_rollback" "$agent_id" "$details"
}

#
# Emit marketplace event
#
emit_marketplace_event() {
    local event_type="$1"
    local listing_id="$2"
    local agent_id="$3"
    local details="${4:-{}}"

    local timestamp=$(_get_timestamp_ms)

    local event=$(cat <<EOF
{
  "timestamp": $timestamp,
  "type": "marketplace",
  "subtype": "$event_type",
  "listing_id": "$listing_id",
  "agent_id": "$agent_id",
  "details": $details
}
EOF
)

    echo "$event" >> "$DASHBOARD_EVENTS"
}

#
# Emit performance alert
#
emit_performance_alert() {
    local agent_id="$1"
    local severity="$2"
    local metric="$3"
    local value="$4"
    local threshold="$5"

    local timestamp=$(_get_timestamp_ms)

    local alert=$(cat <<EOF
{
  "timestamp": $timestamp,
  "type": "performance_alert",
  "agent_id": "$agent_id",
  "severity": "$severity",
  "metric": "$metric",
  "value": $value,
  "threshold": $threshold
}
EOF
)

    echo "$alert" >> "$DASHBOARD_EVENTS"
}

#
# Record metrics snapshot for agent
#
record_agent_metrics() {
    local agent_id="$1"
    local metrics="$2"

    local timestamp=$(_get_timestamp_ms)

    local snapshot=$(cat <<EOF
{
  "timestamp": $timestamp,
  "source": "agentstudio",
  "agent_id": "$agent_id",
  "metrics": $metrics
}
EOF
)

    echo "$snapshot" >> "$METRICS_SNAPSHOTS"
}

# =============================================================================
# COORDINATION CONNECTORS
# =============================================================================

#
# Get master status from coordination
#
get_master_status() {
    local master_name="$1"
    local master_dir="$COORDINATION_DIR/masters/$master_name"

    if [[ -d "$master_dir" ]]; then
        local state_file="$master_dir/state.json"
        if [[ -f "$state_file" ]]; then
            cat "$state_file"
        else
            echo '{"status": "unknown"}'
        fi
    else
        echo '{"status": "not_found"}'
    fi
}

#
# Get worker status from coordination
#
get_worker_status() {
    local worker_id="$1"
    local worker_spec="$COORDINATION_DIR/worker-specs/active/${worker_id}.json"

    if [[ -f "$worker_spec" ]]; then
        cat "$worker_spec"
    else
        echo '{"status": "not_found"}'
    fi
}

#
# Sync agent registry with coordination workers
#
sync_registry_workers() {
    local registry_dir="${REGISTRY_DIR:-$COORDINATION_DIR/agentstudio/registry}"

    # Find all active workers
    local workers_synced=0

    for spec_file in "$COORDINATION_DIR/worker-specs/active"/*.json; do
        if [[ -f "$spec_file" ]]; then
            local worker_id=$(jq -r '.worker_id // .id' "$spec_file")
            local worker_type=$(jq -r '.type // "worker"' "$spec_file")

            # Check if registered
            local reg_file="$registry_dir/active/${worker_id}.json"
            if [[ ! -f "$reg_file" ]]; then
                # Create registry entry from worker spec
                local timestamp=$(_get_timestamp_ms)
                local entry=$(cat <<EOF
{
  "agent_id": "$worker_id",
  "name": "$worker_id",
  "agent_class": "worker",
  "status": "active",
  "synced_from": "coordination",
  "registered_at": $timestamp
}
EOF
)
                mkdir -p "$(dirname "$reg_file")"
                echo "$entry" > "$reg_file"
                workers_synced=$((workers_synced + 1))
            fi
        fi
    done

    echo "{\"workers_synced\": $workers_synced}"
}

#
# Sync agent registry with coordination masters
#
sync_registry_masters() {
    local registry_dir="${REGISTRY_DIR:-$COORDINATION_DIR/agentstudio/registry}"

    # Find all masters
    local masters_synced=0

    for master_dir in "$COORDINATION_DIR/masters"/*/; do
        if [[ -d "$master_dir" ]]; then
            local master_name=$(basename "$master_dir")
            local agent_id="${master_name}-master"

            # Check if registered
            local reg_file="$registry_dir/active/${agent_id}.json"
            if [[ ! -f "$reg_file" ]]; then
                local timestamp=$(_get_timestamp_ms)
                local entry=$(cat <<EOF
{
  "agent_id": "$agent_id",
  "name": "$master_name",
  "agent_class": "master",
  "status": "active",
  "synced_from": "coordination",
  "registered_at": $timestamp
}
EOF
)
                mkdir -p "$(dirname "$reg_file")"
                echo "$entry" > "$reg_file"
                masters_synced=$((masters_synced + 1))
            fi
        fi
    done

    echo "{\"masters_synced\": $masters_synced}"
}

#
# Get routing health for agent
#
get_routing_health() {
    local agent_id="$1"
    local routing_health="$COORDINATION_DIR/routing-health.json"

    if [[ -f "$routing_health" ]]; then
        cat "$routing_health" | jq --arg id "$agent_id" \
            'if .agents[$id] then .agents[$id] else {"status": "unknown"} end'
    else
        echo '{"status": "not_configured"}'
    fi
}

# =============================================================================
# GOVERNANCE CONNECTORS
# =============================================================================

#
# Check agent compliance
#
check_agent_compliance() {
    local agent_id="$1"

    # Check governance policies
    local compliance_dir="$COORDINATION_DIR/governance"
    local result='{"compliant": true, "checks": []}'

    # Check if agent has required configuration
    local checks=()

    # Check 1: Agent is registered
    local reg_file="${REGISTRY_DIR:-$COORDINATION_DIR/agentstudio/registry}/active/${agent_id}.json"
    if [[ -f "$reg_file" ]]; then
        checks+=('{"check": "registered", "passed": true}')
    else
        checks+=('{"check": "registered", "passed": false}')
        result=$(echo "$result" | jq '.compliant = false')
    fi

    # Check 2: Agent has version deployed
    local versions_dir="${VERSIONS_DIR:-$COORDINATION_DIR/agentstudio/versions}"
    local has_version=false
    for ver_file in "$versions_dir/active"/*.json; do
        if [[ -f "$ver_file" ]]; then
            local ver_agent=$(jq -r '.agent_id' "$ver_file")
            if [[ "$ver_agent" == "$agent_id" ]]; then
                has_version=true
                break
            fi
        fi
    done

    if [[ "$has_version" == "true" ]]; then
        checks+=('{"check": "versioned", "passed": true}')
    else
        checks+=('{"check": "versioned", "passed": false}')
    fi

    # Check 3: Agent has performance baseline
    local perf_dir="${PERFORMANCE_DIR:-$COORDINATION_DIR/agentstudio/performance}"
    if [[ -f "$perf_dir/baselines/${agent_id}-baseline.json" ]]; then
        checks+=('{"check": "baselined", "passed": true}')
    else
        checks+=('{"check": "baselined", "passed": false}')
    fi

    # Build result
    local checks_json="["
    local first=true
    for check in "${checks[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            checks_json+=","
        fi
        checks_json+="$check"
    done
    checks_json+="]"

    echo "$result" | jq --argjson checks "$checks_json" '.checks = $checks'
}

#
# Validate agent before deployment
#
validate_deployment() {
    local agent_id="$1"
    local version_id="$2"
    local environment="$3"

    local result='{"valid": true, "errors": [], "warnings": []}'

    # Check 1: Version exists
    local versions_dir="${VERSIONS_DIR:-$COORDINATION_DIR/agentstudio/versions}"
    local version_file="$versions_dir/active/${version_id}.json"
    if [[ ! -f "$version_file" ]]; then
        result=$(echo "$result" | jq '.valid = false | .errors += ["Version not found"]')
        echo "$result"
        return 1
    fi

    # Check 2: Version status allows deployment
    local status=$(jq -r '.status' "$version_file")
    if [[ "$status" != "staged" && "$status" != "testing" && "$status" != "deployed" ]]; then
        result=$(echo "$result" | jq '.warnings += ["Version not in staged/testing status"]')
    fi

    # Check 3: Environment validation
    case "$environment" in
        production)
            # Production requires version to be tagged
            local tags=$(jq -r '.tags // []' "$version_file")
            if [[ "$tags" == "[]" ]]; then
                result=$(echo "$result" | jq '.warnings += ["Production deployment without version tags"]')
            fi
            ;;
        staging|development)
            # OK for any status
            ;;
        *)
            result=$(echo "$result" | jq '.valid = false | .errors += ["Invalid environment"]')
            ;;
    esac

    # Check 4: Compliance check
    local compliance=$(check_agent_compliance "$agent_id")
    local is_compliant=$(echo "$compliance" | jq -r '.compliant')
    if [[ "$is_compliant" != "true" ]]; then
        result=$(echo "$result" | jq '.warnings += ["Agent not fully compliant with governance policies"]')
    fi

    echo "$result"
}

#
# Record deployment for audit
#
record_deployment_audit() {
    local agent_id="$1"
    local version_id="$2"
    local environment="$3"
    local user="${4:-$(whoami)}"

    local timestamp=$(_get_timestamp_ms)
    local audit_dir="$COORDINATION_DIR/agentstudio/audit"
    mkdir -p "$audit_dir"

    local audit_entry=$(cat <<EOF
{
  "timestamp": $timestamp,
  "type": "deployment",
  "agent_id": "$agent_id",
  "version_id": "$version_id",
  "environment": "$environment",
  "user": "$user",
  "source": "agentstudio"
}
EOF
)

    echo "$audit_entry" >> "$audit_dir/deployments.jsonl"
}

# =============================================================================
# HEALTH MONITORING CONNECTORS
# =============================================================================

#
# Get agent health summary
#
get_agent_health() {
    local agent_id="$1"

    local timestamp=$(_get_timestamp_ms)
    local health='{"status": "healthy", "checks": []}'

    # Check 1: Registration status
    local reg_file="${REGISTRY_DIR:-$COORDINATION_DIR/agentstudio/registry}/active/${agent_id}.json"
    if [[ -f "$reg_file" ]]; then
        local status=$(jq -r '.status' "$reg_file")
        health=$(echo "$health" | jq --arg s "$status" '.checks += [{"name": "registration", "status": $s}]')
        if [[ "$status" != "running" && "$status" != "active" ]]; then
            health=$(echo "$health" | jq '.status = "degraded"')
        fi
    else
        health=$(echo "$health" | jq '.status = "unknown" | .checks += [{"name": "registration", "status": "not_found"}]')
    fi

    # Check 2: Performance metrics
    local perf_dir="${PERFORMANCE_DIR:-$COORDINATION_DIR/agentstudio/performance}"
    local latest_report=$(ls -t "$perf_dir/reports/${agent_id}"*.json 2>/dev/null | head -1)
    if [[ -n "$latest_report" && -f "$latest_report" ]]; then
        local success_rate=$(jq -r '.metrics.reliability.success_rate // 0' "$latest_report")
        if (( $(echo "$success_rate < 0.9" | bc -l 2>/dev/null || echo 0) )); then
            health=$(echo "$health" | jq '.status = "degraded" | .checks += [{"name": "reliability", "status": "low"}]')
        else
            health=$(echo "$health" | jq '.checks += [{"name": "reliability", "status": "good"}]')
        fi
    fi

    # Check 3: Version deployment
    local versions_dir="${VERSIONS_DIR:-$COORDINATION_DIR/agentstudio/versions}"
    local deployed=false
    for ver_file in "$versions_dir/active"/*.json; do
        if [[ -f "$ver_file" ]]; then
            local ver_agent=$(jq -r '.agent_id' "$ver_file")
            local ver_status=$(jq -r '.status' "$ver_file")
            if [[ "$ver_agent" == "$agent_id" && "$ver_status" == "deployed" ]]; then
                deployed=true
                break
            fi
        fi
    done

    if [[ "$deployed" == "true" ]]; then
        health=$(echo "$health" | jq '.checks += [{"name": "deployment", "status": "deployed"}]')
    else
        health=$(echo "$health" | jq '.checks += [{"name": "deployment", "status": "not_deployed"}]')
    fi

    echo "$health" | jq --argjson ts "$timestamp" '. + {"timestamp": $ts}'
}

#
# Record health report
#
record_health_report() {
    local agent_id="$1"
    local health="$2"

    echo "$health" | jq --arg id "$agent_id" '. + {"agent_id": $id}' >> "$HEALTH_REPORTS"
}

#
# Get system-wide health summary
#
get_system_health() {
    local registry_dir="${REGISTRY_DIR:-$COORDINATION_DIR/agentstudio/registry}"

    local total_agents=0
    local healthy_agents=0
    local degraded_agents=0
    local unknown_agents=0

    for agent_file in "$registry_dir/active"/*.json; do
        if [[ -f "$agent_file" ]]; then
            total_agents=$((total_agents + 1))
            local agent_id=$(jq -r '.agent_id' "$agent_file")
            local health=$(get_agent_health "$agent_id")
            local status=$(echo "$health" | jq -r '.status')

            case "$status" in
                healthy) healthy_agents=$((healthy_agents + 1)) ;;
                degraded) degraded_agents=$((degraded_agents + 1)) ;;
                *) unknown_agents=$((unknown_agents + 1)) ;;
            esac
        fi
    done

    cat <<EOF
{
  "timestamp": $(_get_timestamp_ms),
  "total_agents": $total_agents,
  "healthy": $healthy_agents,
  "degraded": $degraded_agents,
  "unknown": $unknown_agents,
  "health_percentage": $(echo "scale=2; $healthy_agents * 100 / ($total_agents + 1)" | bc)
}
EOF
}

# Export functions
export -f emit_agent_event
export -f emit_agent_registered
export -f emit_agent_deployed
export -f emit_agent_rollback
export -f emit_marketplace_event
export -f emit_performance_alert
export -f record_agent_metrics
export -f get_master_status
export -f get_worker_status
export -f sync_registry_workers
export -f sync_registry_masters
export -f get_routing_health
export -f check_agent_compliance
export -f validate_deployment
export -f record_deployment_audit
export -f get_agent_health
export -f record_health_report
export -f get_system_health
