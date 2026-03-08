#!/bin/bash
# scripts/lib/identity-check.sh
# Bash wrapper for agent identity verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

IDENTITY_CLI="$COMMIT_RELAY_HOME/lib/governance/identity/agent-identity.js"
CAPABILITY_CLI="$COMMIT_RELAY_HOME/lib/governance/identity/capability-policy.js"

##############################################################################
# verify_identity: Verify agent identity token
# Args:
#   $1: token - JWT identity token
# Returns: 0 if valid, 1 if invalid
# Outputs: Decoded identity JSON to stdout
##############################################################################
verify_identity() {
    local token="$1"

    if [ ! -f "$IDENTITY_CLI" ]; then
        echo "Error: Identity CLI not found: $IDENTITY_CLI" >&2
        return 1
    fi

    # Verify token using Node.js CLI
    if result=$(node "$IDENTITY_CLI" verify "$token" 2>&1); then
        echo "$result"
        return 0
    else
        echo "Identity verification failed: $result" >&2
        return 1
    fi
}

##############################################################################
# check_capability: Check if agent has required capability
# Args:
#   $1: token - JWT identity token
#   $2: required_capability - Required capability (e.g., "tasks:read")
# Returns: 0 if authorized, 1 if denied
##############################################################################
check_capability() {
    local token="$1"
    local required_capability="$2"

    # Verify and decode token
    local identity=$(verify_identity "$token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Extract capabilities and trust level
    local capabilities=$(echo "$identity" | jq -r '.capabilities | join(",")')
    local trust_level=$(echo "$identity" | jq -r '.trust_level')

    # Check capability
    node "$CAPABILITY_CLI" check "$capabilities" "$required_capability" "$trust_level" > /dev/null 2>&1
    return $?
}

##############################################################################
# get_agent_id: Extract agent ID from token
# Args:
#   $1: token - JWT identity token
# Returns: Agent ID
##############################################################################
get_agent_id() {
    local token="$1"

    local identity=$(verify_identity "$token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$identity" | jq -r '.agent_id'
}

##############################################################################
# get_spiffe_id: Extract SPIFFE ID from token
# Args:
#   $1: token - JWT identity token
# Returns: SPIFFE ID
##############################################################################
get_spiffe_id() {
    local token="$1"

    local identity=$(verify_identity "$token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "$identity" | jq -r '.sub'
}

##############################################################################
# issue_worker_token: Issue identity token for worker
# Args:
#   $1: worker_id - Worker identifier
#   $2: master_agent - Master agent name (e.g., "development-master")
#   $3: task_id - Task ID
# Returns: JSON with token and identity info
##############################################################################
issue_worker_token() {
    local worker_id="$1"
    local master_agent="$2"
    local task_id="$3"

    # Determine capabilities based on master
    local capabilities
    case "$master_agent" in
        development-master)
            capabilities="development:implement,development:test,tasks:read,coordination:read,governance:read"
            ;;
        security-master)
            capabilities="security:scan,security:audit,tasks:read,coordination:read,governance:read,governance:audit"
            ;;
        inventory-master)
            capabilities="inventory:catalog,inventory:document,inventory:analyze,tasks:read,coordination:read,governance:read"
            ;;
        cicd-master)
            capabilities="cicd:build,cicd:deploy,cicd:monitor,tasks:read,coordination:read,governance:read"
            ;;
        *)
            capabilities="tasks:read,coordination:read,governance:read"
            ;;
    esac

    # Calculate trust level based on worker type
    local trust_level=50  # Standard worker trust

    # Issue token
    local result=$(node "$IDENTITY_CLI" issue "$worker_id" "worker" "$trust_level" $(echo "$capabilities" | tr ',' ' ') 2>&1)

    if [ $? -eq 0 ]; then
        echo "$result"
        return 0
    else
        echo "Failed to issue token: $result" >&2
        return 1
    fi
}

##############################################################################
# Main CLI interface
##############################################################################
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "${1:-help}" in
        verify)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 verify <token>"
                exit 1
            fi
            verify_identity "$2"
            ;;
        check)
            if [ $# -lt 3 ]; then
                echo "Usage: $0 check <token> <capability>"
                exit 1
            fi
            if check_capability "$2" "$3"; then
                echo "ALLOWED"
                exit 0
            else
                echo "DENIED"
                exit 1
            fi
            ;;
        agent-id)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 agent-id <token>"
                exit 1
            fi
            get_agent_id "$2"
            ;;
        spiffe-id)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 spiffe-id <token>"
                exit 1
            fi
            get_spiffe_id "$2"
            ;;
        issue-worker)
            if [ $# -lt 4 ]; then
                echo "Usage: $0 issue-worker <worker_id> <master_agent> <task_id>"
                exit 1
            fi
            issue_worker_token "$2" "$3" "$4"
            ;;
        help|--help|-h)
            cat <<EOF
Identity Check - Agent identity verification wrapper

Usage: $0 <command> [arguments]

Commands:
  verify <token>                           Verify and decode identity token
  check <token> <capability>               Check if token has capability
  agent-id <token>                         Extract agent ID from token
  spiffe-id <token>                        Extract SPIFFE ID from token
  issue-worker <worker_id> <master> <task> Issue token for worker

Examples:
  # Verify token
  $0 verify "\$TOKEN"

  # Check capability
  $0 check "\$TOKEN" "tasks:read"

  # Issue worker token
  $0 issue-worker worker-impl-001 development-master task-123
EOF
            ;;
        *)
            echo "Unknown command: $1"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
fi
