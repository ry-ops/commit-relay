#!/bin/bash
# Lineage Tracking Integration for Bash Scripts
# Part of Phase 3: Automated Data Lineage & Audit Trails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Lineage tracking functions

##############################################################################
# record_lineage: Record a data lineage operation
#
# Usage: record_lineage <type> <source> <target> <actor> [transformation]
#
# Example:
#   record_lineage "transform" "task-queue.json" "tasks/task-001.json" \
#                  "coordinator-master" "task_extraction"
##############################################################################
record_lineage() {
    local operation_type="$1"
    local source="$2"
    local target="$3"
    local actor="$4"
    local transformation="${5:-}"

    local lineage_log="$COMMIT_RELAY_HOME/coordination/governance/lineage-log.jsonl"
    mkdir -p "$(dirname "$lineage_log")"

    local lineage_id="lineage-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build lineage record
    local record=$(cat <<EOF
{
  "id": "$lineage_id",
  "timestamp": "$timestamp",
  "type": "$operation_type",
  "source": $([ -n "$source" ] && echo "\"$source\"" || echo "null"),
  "target": $([ -n "$target" ] && echo "\"$target\"" || echo "null"),
  "actor": "$actor",
  "transformation": $([ -n "$transformation" ] && echo "\"$transformation\"" || echo "null"),
  "metadata": {
    "hostname": "$(hostname)",
    "process_id": $$,
    "shell": "$SHELL"
  }
}
EOF
)

    # Append to log
    echo "$record" >> "$lineage_log"
}

##############################################################################
# log_audit: Log an audit event
#
# Usage: log_audit <action> <actor> <resource> <outcome> [context_json]
#
# Example:
#   log_audit "task_creation" "coordinator-master" "task-001" "success" \
#             '{"priority": "high"}'
##############################################################################
log_audit() {
    local action="$1"
    local actor="$2"
    local resource="$3"
    local outcome="$4"
    local context_json="${5:-{}}"

    local audit_log="$COMMIT_RELAY_HOME/coordination/governance/audit-trail.jsonl"
    mkdir -p "$(dirname "$audit_log")"

    local audit_id="audit-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Determine severity
    local severity="low"
    case "$action" in
        *delete*|*admin*|*permission*|*security*)
            severity="high"
            ;;
        *write*|*update*|*create*)
            severity="medium"
            ;;
    esac

    if [ "$outcome" = "failure" ]; then
        severity="high"
    fi

    # Build audit record
    local record=$(cat <<EOF
{
  "id": "$audit_id",
  "timestamp": "$timestamp",
  "action": "$action",
  "actor": "$actor",
  "resource": "$resource",
  "outcome": "$outcome",
  "severity": "$severity",
  "context": $context_json
}
EOF
)

    # Append to log
    echo "$record" >> "$audit_log"
}

##############################################################################
# query_lineage: Query lineage records
#
# Usage: query_lineage <entity>
##############################################################################
query_lineage() {
    local entity="$1"
    node "$COMMIT_RELAY_HOME/lib/governance/lineage.js" query-lineage "$entity"
}

##############################################################################
# query_audit: Query audit records
#
# Usage: query_audit <criteria_json>
# Example: query_audit '{"actor": "coordinator-master"}'
##############################################################################
query_audit() {
    local criteria="${1:-{}}"
    node "$COMMIT_RELAY_HOME/lib/governance/lineage.js" query-audit "$criteria"
}

##############################################################################
# generate_compliance_report: Generate compliance report
#
# Usage: generate_compliance_report [period]
# Example: generate_compliance_report "30d"
##############################################################################
generate_compliance_report() {
    local period="${1:-30d}"
    node "$COMMIT_RELAY_HOME/lib/governance/lineage.js" compliance-report "$period"
}

##############################################################################
# build_lineage_graph: Build lineage graph for entity
#
# Usage: build_lineage_graph <entity> [depth]
##############################################################################
build_lineage_graph() {
    local entity="$1"
    local depth="${2:-3}"
    node "$COMMIT_RELAY_HOME/lib/governance/lineage.js" lineage-graph "$entity" "$depth"
}

# Export functions for sourcing
export -f record_lineage
export -f log_audit
export -f query_lineage
export -f query_audit
export -f generate_compliance_report
export -f build_lineage_graph
