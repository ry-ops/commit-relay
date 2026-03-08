#!/usr/bin/env bash
#
# Approval Workflow
# Part of Phase 2 Security Enhancements
#
# Manages approval workflows for sensitive operations:
# - Creates approval requests
# - Tracks pending approvals
# - Validates approval status
# - Integrates with access-check.sh
#
# Usage:
#   source scripts/lib/governance/approval-workflow.sh
#   request_approval "$operation" "$requester" "$context"
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Configuration
readonly APPROVALS_BASE_DIR="${APPROVALS_BASE_DIR:-coordination/approvals}"
readonly PENDING_DIR="${PENDING_DIR:-$APPROVALS_BASE_DIR/pending}"
readonly APPROVED_DIR="${APPROVED_DIR:-$APPROVALS_BASE_DIR/approved}"
readonly REJECTED_DIR="${REJECTED_DIR:-$APPROVALS_BASE_DIR/rejected}"
readonly EXPIRED_DIR="${EXPIRED_DIR:-$APPROVALS_BASE_DIR/expired}"
readonly APPROVAL_HISTORY_FILE="${APPROVAL_HISTORY_FILE:-$APPROVALS_BASE_DIR/history.jsonl}"
readonly APPROVAL_REQUIRED_FILE="${APPROVAL_REQUIRED_FILE:-coordination/policies/approval-required.json}"

# Default approval settings
readonly DEFAULT_EXPIRY_HOURS=24
readonly DEFAULT_APPROVAL_TIMEOUT=48  # hours

#
# Initialize approval workflow directories
#
initialize_approval_workflow() {
    mkdir -p "$PENDING_DIR" "$APPROVED_DIR" "$REJECTED_DIR" "$EXPIRED_DIR"
    mkdir -p "$(dirname "$APPROVAL_HISTORY_FILE")"
    mkdir -p "$(dirname "$APPROVAL_REQUIRED_FILE")"

    # Create default approval-required.json if it doesn't exist
    if [[ ! -f "$APPROVAL_REQUIRED_FILE" ]]; then
        create_default_approval_policy
    fi
}

#
# Create default approval policy
#
create_default_approval_policy() {
    cat > "$APPROVAL_REQUIRED_FILE" <<'EOF'
{
  "version": "1.0",
  "description": "Defines operations that require explicit approval before execution",
  "operations": [
    {
      "name": "credential_access",
      "description": "Access to credentials or secrets",
      "worker_types": ["security", "deployment"],
      "task_types": ["credential_rotation", "secret_management"],
      "required_approvers": 1,
      "approval_roles": ["security-admin", "system-admin"],
      "expiry_hours": 4,
      "auto_approve_conditions": []
    },
    {
      "name": "production_deployment",
      "description": "Deployment to production environment",
      "worker_types": ["deployment"],
      "task_types": ["production_deploy", "release"],
      "required_approvers": 2,
      "approval_roles": ["release-manager", "tech-lead"],
      "expiry_hours": 8,
      "auto_approve_conditions": [
        {"condition": "is_hotfix", "value": true, "required_approvers": 1}
      ]
    },
    {
      "name": "data_deletion",
      "description": "Deletion of data or resources",
      "worker_types": ["maintenance", "cleanup"],
      "task_types": ["data_cleanup", "resource_deletion"],
      "required_approvers": 1,
      "approval_roles": ["data-owner", "system-admin"],
      "expiry_hours": 12,
      "auto_approve_conditions": []
    },
    {
      "name": "config_change",
      "description": "Changes to system configuration",
      "worker_types": ["configuration"],
      "task_types": ["config_update", "policy_change"],
      "required_approvers": 1,
      "approval_roles": ["config-admin", "system-admin"],
      "expiry_hours": 24,
      "auto_approve_conditions": [
        {"condition": "is_rollback", "value": true, "required_approvers": 0}
      ]
    },
    {
      "name": "privileged_access",
      "description": "Access requiring elevated privileges",
      "worker_types": ["security", "audit"],
      "task_types": ["privilege_escalation", "admin_operation"],
      "required_approvers": 2,
      "approval_roles": ["security-admin"],
      "expiry_hours": 2,
      "auto_approve_conditions": []
    },
    {
      "name": "external_integration",
      "description": "Integration with external systems",
      "worker_types": ["integration"],
      "task_types": ["api_integration", "external_data_access"],
      "required_approvers": 1,
      "approval_roles": ["integration-admin", "security-admin"],
      "expiry_hours": 24,
      "auto_approve_conditions": []
    }
  ],
  "global_settings": {
    "require_justification": true,
    "allow_self_approval": false,
    "notification_channels": ["dashboard", "log"],
    "audit_all_decisions": true
  }
}
EOF
}

#
# Generate approval ID
#
generate_approval_id() {
    local timestamp=$(date +%s%N | cut -b1-13)
    local random=$(openssl rand -hex 4)
    echo "APR-${timestamp}-${random}"
}

#
# Check if operation requires approval
#
requires_approval() {
    local operation="$1"
    local worker_type="${2:-}"
    local task_type="${3:-}"

    if [[ ! -f "$APPROVAL_REQUIRED_FILE" ]]; then
        echo "false"
        return
    fi

    # Check if operation matches any defined approval requirement
    local match=$(jq -r --arg op "$operation" --arg wt "$worker_type" --arg tt "$task_type" '
        .operations[] |
        select(
            .name == $op or
            (.worker_types | any(. == $wt)) or
            (.task_types | any(. == $tt))
        ) |
        .name
    ' "$APPROVAL_REQUIRED_FILE" 2>/dev/null | head -1)

    if [[ -n "$match" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

#
# Get approval configuration for operation
#
get_approval_config() {
    local operation="$1"

    if [[ ! -f "$APPROVAL_REQUIRED_FILE" ]]; then
        echo "{}"
        return
    fi

    jq --arg op "$operation" '.operations[] | select(.name == $op)' "$APPROVAL_REQUIRED_FILE"
}

#
# Request approval for an operation
#
request_approval() {
    local operation="$1"
    local requester="$2"
    local context="${3:-{}}"
    local justification="${4:-}"

    initialize_approval_workflow

    local approval_id=$(generate_approval_id)
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Get approval configuration
    local config=$(get_approval_config "$operation")

    if [[ -z "$config" || "$config" == "{}" ]]; then
        echo "Error: No approval configuration found for operation: $operation" >&2
        return 1
    fi

    local required_approvers=$(echo "$config" | jq -r '.required_approvers // 1')
    local approval_roles=$(echo "$config" | jq -c '.approval_roles // []')
    local expiry_hours=$(echo "$config" | jq -r '.expiry_hours // 24')

    # Calculate expiry time
    local expiry_epoch=$(($(date +%s) + (expiry_hours * 3600)))
    local expiry_time
    if [[ "$OSTYPE" == "darwin"* ]]; then
        expiry_time=$(date -r "$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
    else
        expiry_time=$(date -d "@$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
    fi

    # Check auto-approve conditions
    local auto_approved="false"
    local auto_approve_conditions=$(echo "$config" | jq -c '.auto_approve_conditions // []')

    if [[ "$auto_approve_conditions" != "[]" ]]; then
        # Check each condition
        auto_approved=$(echo "$auto_approve_conditions" | jq -r --argjson ctx "$context" '
            map(
                select(.condition as $cond | $ctx[$cond] == .value)
            ) |
            if length > 0 then "true" else "false" end
        ')
    fi

    # Create approval request
    local request=$(jq -n \
        --arg id "$approval_id" \
        --arg op "$operation" \
        --arg req "$requester" \
        --arg ts "$timestamp" \
        --arg exp "$expiry_time" \
        --arg just "$justification" \
        --arg req_approvers "$required_approvers" \
        --argjson roles "$approval_roles" \
        --argjson ctx "$context" \
        --arg auto "$auto_approved" \
        '{
            approval_id: $id,
            operation: $op,
            requester: $req,
            requested_at: $ts,
            expires_at: $exp,
            justification: $just,
            required_approvers: ($req_approvers | tonumber),
            approval_roles: $roles,
            context: $ctx,
            status: (if $auto == "true" then "auto_approved" else "pending" end),
            approvals: [],
            rejections: [],
            auto_approved: ($auto == "true")
        }')

    if [[ "$auto_approved" == "true" ]]; then
        # Auto-approved, save to approved directory
        echo "$request" > "$APPROVED_DIR/${approval_id}.json"
        log_approval_event "$approval_id" "auto_approved" "system" "Auto-approved based on conditions"
    else
        # Save to pending directory
        echo "$request" > "$PENDING_DIR/${approval_id}.json"
        log_approval_event "$approval_id" "requested" "$requester" "$justification"

        # Emit notification
        emit_approval_notification "$approval_id" "$operation" "$requester"
    fi

    echo "$approval_id"
}

#
# Approve a request
#
approve_request() {
    local approval_id="$1"
    local approver="$2"
    local comments="${3:-Approved}"

    local pending_file="$PENDING_DIR/${approval_id}.json"

    if [[ ! -f "$pending_file" ]]; then
        echo "Error: Approval request not found: $approval_id" >&2
        return 1
    fi

    local request=$(cat "$pending_file")
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Check if approver has required role
    local approval_roles=$(echo "$request" | jq -c '.approval_roles')
    # Note: In a full implementation, verify approver's role

    # Check if already expired
    local expires_at=$(echo "$request" | jq -r '.expires_at')
    if is_expired "$expires_at"; then
        move_to_expired "$approval_id"
        echo "Error: Approval request has expired" >&2
        return 1
    fi

    # Add approval
    local updated=$(echo "$request" | jq \
        --arg approver "$approver" \
        --arg ts "$timestamp" \
        --arg comments "$comments" \
        '.approvals += [{
            approver: $approver,
            approved_at: $ts,
            comments: $comments
        }]')

    # Check if we have enough approvals
    local required=$(echo "$updated" | jq -r '.required_approvers')
    local current=$(echo "$updated" | jq '.approvals | length')

    if [[ "$current" -ge "$required" ]]; then
        # Fully approved
        updated=$(echo "$updated" | jq --arg ts "$timestamp" '.status = "approved" | .approved_at = $ts')
        echo "$updated" > "$APPROVED_DIR/${approval_id}.json"
        rm -f "$pending_file"
        log_approval_event "$approval_id" "approved" "$approver" "$comments"
    else
        # Still pending more approvals
        echo "$updated" > "$pending_file"
        log_approval_event "$approval_id" "partial_approval" "$approver" "$comments ($current/$required)"
    fi

    echo "Approved by $approver ($current/$required approvals)"
}

#
# Reject a request
#
reject_request() {
    local approval_id="$1"
    local rejector="$2"
    local reason="${3:-Rejected}"

    local pending_file="$PENDING_DIR/${approval_id}.json"

    if [[ ! -f "$pending_file" ]]; then
        echo "Error: Approval request not found: $approval_id" >&2
        return 1
    fi

    local request=$(cat "$pending_file")
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Update status
    local updated=$(echo "$request" | jq \
        --arg rejector "$rejector" \
        --arg ts "$timestamp" \
        --arg reason "$reason" \
        '.status = "rejected" |
         .rejected_at = $ts |
         .rejections += [{
            rejector: $rejector,
            rejected_at: $ts,
            reason: $reason
         }]')

    echo "$updated" > "$REJECTED_DIR/${approval_id}.json"
    rm -f "$pending_file"

    log_approval_event "$approval_id" "rejected" "$rejector" "$reason"

    echo "Rejected by $rejector: $reason"
}

#
# Check if approval is valid (not expired and approved)
#
is_approval_valid() {
    local approval_id="$1"

    local approved_file="$APPROVED_DIR/${approval_id}.json"

    if [[ ! -f "$approved_file" ]]; then
        echo "false"
        return
    fi

    local request=$(cat "$approved_file")
    local expires_at=$(echo "$request" | jq -r '.expires_at')

    if is_expired "$expires_at"; then
        move_to_expired "$approval_id"
        echo "false"
        return
    fi

    echo "true"
}

#
# Check if timestamp is expired
#
is_expired() {
    local expires_at="$1"
    local now_epoch=$(date +%s)
    local expiry_epoch

    if [[ "$OSTYPE" == "darwin"* ]]; then
        expiry_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" "+%s" 2>/dev/null || echo "0")
    else
        expiry_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo "0")
    fi

    if [[ "$now_epoch" -gt "$expiry_epoch" ]]; then
        return 0
    else
        return 1
    fi
}

#
# Move expired approval to expired directory
#
move_to_expired() {
    local approval_id="$1"

    for dir in "$PENDING_DIR" "$APPROVED_DIR"; do
        local file="$dir/${approval_id}.json"
        if [[ -f "$file" ]]; then
            local request=$(cat "$file")
            local updated=$(echo "$request" | jq \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '.status = "expired" | .expired_at = $ts')

            echo "$updated" > "$EXPIRED_DIR/${approval_id}.json"
            rm -f "$file"

            log_approval_event "$approval_id" "expired" "system" "Approval expired"
            return
        fi
    done
}

#
# Get pending approvals
#
get_pending_approvals() {
    local operation="${1:-}"

    if [[ ! -d "$PENDING_DIR" ]]; then
        echo "[]"
        return
    fi

    local results='[]'

    for file in "$PENDING_DIR"/*.json; do
        if [[ ! -f "$file" ]]; then
            continue
        fi

        local request=$(cat "$file")

        if [[ -n "$operation" ]]; then
            local op=$(echo "$request" | jq -r '.operation')
            if [[ "$op" != "$operation" ]]; then
                continue
            fi
        fi

        results=$(echo "$results" | jq --argjson req "$request" '. += [$req]')
    done

    echo "$results" | jq 'sort_by(.requested_at)'
}

#
# Get approval by ID
#
get_approval() {
    local approval_id="$1"

    for dir in "$PENDING_DIR" "$APPROVED_DIR" "$REJECTED_DIR" "$EXPIRED_DIR"; do
        local file="$dir/${approval_id}.json"
        if [[ -f "$file" ]]; then
            cat "$file"
            return
        fi
    done

    echo "{}"
}

#
# Log approval event to history
#
log_approval_event() {
    local approval_id="$1"
    local event_type="$2"
    local actor="$3"
    local details="$4"

    local event=$(jq -n \
        --arg id "$approval_id" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg type "$event_type" \
        --arg actor "$actor" \
        --arg details "$details" \
        '{
            approval_id: $id,
            timestamp: $ts,
            event_type: $type,
            actor: $actor,
            details: $details
        }')

    echo "$event" >> "$APPROVAL_HISTORY_FILE"
}

#
# Emit notification for new approval request
#
emit_approval_notification() {
    local approval_id="$1"
    local operation="$2"
    local requester="$3"

    local event_file="$PROJECT_ROOT/coordination/dashboard-events.jsonl"

    if [[ -w "$event_file" ]]; then
        jq -nc \
            --arg id "evt-approval-$(date +%s)" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg aid "$approval_id" \
            --arg op "$operation" \
            --arg req "$requester" \
            '{
                id: $id,
                timestamp: $ts,
                type: "approval_requested",
                severity: "info",
                data: {
                    approval_id: $aid,
                    operation: $op,
                    requester: $req,
                    action_required: true
                },
                source: "approval-workflow"
            }' >> "$event_file"
    fi
}

#
# Cleanup expired approvals
#
cleanup_expired_approvals() {
    local max_age_days="${1:-30}"

    find "$EXPIRED_DIR" -name "*.json" -mtime +$max_age_days -delete 2>/dev/null || true

    # Also check pending for expired
    for file in "$PENDING_DIR"/*.json; do
        if [[ ! -f "$file" ]]; then
            continue
        fi

        local expires_at=$(jq -r '.expires_at' "$file")
        if is_expired "$expires_at"; then
            local approval_id=$(basename "$file" .json)
            move_to_expired "$approval_id"
        fi
    done
}

#
# Get approval statistics
#
get_approval_stats() {
    local pending=$(find "$PENDING_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local approved=$(find "$APPROVED_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local rejected=$(find "$REJECTED_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local expired=$(find "$EXPIRED_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    jq -n \
        --arg pending "$pending" \
        --arg approved "$approved" \
        --arg rejected "$rejected" \
        --arg expired "$expired" \
        --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pending: ($pending | tonumber),
            approved: ($approved | tonumber),
            rejected: ($rejected | tonumber),
            expired: ($expired | tonumber),
            total: (($pending | tonumber) + ($approved | tonumber) + ($rejected | tonumber) + ($expired | tonumber)),
            last_updated: $updated
        }'
}

# Export functions
export -f initialize_approval_workflow
export -f requires_approval
export -f request_approval
export -f approve_request
export -f reject_request
export -f is_approval_valid
export -f get_pending_approvals
export -f get_approval
export -f get_approval_stats
export -f cleanup_expired_approvals
