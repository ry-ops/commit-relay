#!/bin/bash
# coordination/governance/lib/bypass-auditor.sh
# Bypass Auditing for Commit-Relay
#
# Purpose:
# - Track and audit all governance bypass operations
# - Ensure accountability for bypasses
# - Check authorization for bypasses
# - Log all bypass activities
#
# Usage:
#   source coordination/governance/lib/bypass-auditor.sh
#   audit_bypass "$bypass_type" "$reason" "$approved_by"

set -eo pipefail

# Prevent re-sourcing
if [ -n "${BYPASS_AUDITOR_LOADED:-}" ]; then
    return 0
fi
BYPASS_AUDITOR_LOADED=1

# Authorization matrix (role -> bypass types allowed)
# Format: "role:bypass_type:max_duration_minutes"
AUTHORIZATION_MATRIX=(
    "developer:validation:0"
    "senior_engineer:validation:30"
    "tech_lead:validation:120"
    "tech_lead:governance:30"
    "engineering_manager:validation:480"
    "engineering_manager:governance:120"
    "engineering_manager:access:30"
    "director:validation:999999"
    "director:governance:999999"
    "director:access:999999"
)

# Audit a bypass operation
# Returns: 0 if allowed, 1 if denied
audit_bypass() {
    local bypass_type="$1"
    local reason="${2:-no_reason_provided}"
    local approved_by="${3:-none}"
    local duration_minutes="${4:-30}"

    # Get current principal
    local principal="${COMMIT_RELAY_PRINCIPAL:-system}"

    # Check if bypass is authorized
    if ! check_bypass_authorization "$principal" "$bypass_type" "$duration_minutes"; then
        log_bypass_denied "$bypass_type" "$reason" "$principal"
        return 1
    fi

    # Calculate risk level
    local risk_level=$(calculate_bypass_risk "$bypass_type" "$duration_minutes")

    # Generate trace ID for this bypass
    local bypass_id="bypass-$(date +%s)-$$"

    # Log bypass
    local audit_entry=$(cat <<EOF
{
  "bypass_id": "$bypass_id",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bypass_type": "$bypass_type",
  "principal": "$principal",
  "reason": "$reason",
  "approved_by": "$approved_by",
  "duration_minutes": $duration_minutes,
  "risk_level": "$risk_level",
  "status": "approved",
  "scope": {
    "operation": "${BYPASS_OPERATION:-unknown}",
    "component": "${BYPASS_COMPONENT:-unknown}"
  }
}
EOF
)

    # Write to bypass audit log
    local audit_log="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/governance/bypass-audit.jsonl"
    mkdir -p "$(dirname "$audit_log")"
    echo "$audit_entry" >> "$audit_log"

    # Set bypass expiration
    export BYPASS_EXPIRES_AT=$(($(date +%s) + (duration_minutes * 60)))
    export BYPASS_ID="$bypass_id"

    return 0
}

# Check if principal is authorized for bypass
check_bypass_authorization() {
    local principal="$1"
    local bypass_type="$2"
    local duration_minutes="${3:-30}"

    # Extract role from principal (format: user@role or just role)
    local role=$(echo "$principal" | grep -oE 'developer|senior_engineer|tech_lead|engineering_manager|director' || echo "developer")

    # Check authorization matrix
    for entry in "${AUTHORIZATION_MATRIX[@]}"; do
        local auth_role=$(echo "$entry" | cut -d: -f1)
        local auth_bypass=$(echo "$entry" | cut -d: -f2)
        local auth_duration=$(echo "$entry" | cut -d: -f3)

        if [ "$auth_role" = "$role" ] && [ "$auth_bypass" = "$bypass_type" ]; then
            # Check if duration is within allowed limit
            if [ "$auth_duration" = "999999" ] || [ "$duration_minutes" -le "$auth_duration" ]; then
                return 0  # Authorized
            fi
        fi
    done

    return 1  # Not authorized
}

# Calculate risk level for bypass
calculate_bypass_risk() {
    local bypass_type="$1"
    local duration_minutes="$2"

    # Base risk by type
    local base_risk=0
    case "$bypass_type" in
        validation)
            base_risk=5
            ;;
        governance)
            base_risk=7
            ;;
        access)
            base_risk=9
            ;;
        *)
            base_risk=5
            ;;
    esac

    # Increase risk based on duration
    if [ "$duration_minutes" -gt 480 ]; then
        base_risk=$((base_risk + 3))
    elif [ "$duration_minutes" -gt 120 ]; then
        base_risk=$((base_risk + 2))
    elif [ "$duration_minutes" -gt 30 ]; then
        base_risk=$((base_risk + 1))
    fi

    # Convert to risk level
    if [ "$base_risk" -ge 9 ]; then
        echo "critical"
    elif [ "$base_risk" -ge 7 ]; then
        echo "high"
    elif [ "$base_risk" -ge 5 ]; then
        echo "medium"
    else
        echo "low"
    fi
}

# Log denied bypass
log_bypass_denied() {
    local bypass_type="$1"
    local reason="$2"
    local principal="$3"

    local audit_entry=$(cat <<EOF
{
  "bypass_id": "denied-$(date +%s)-$$",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bypass_type": "$bypass_type",
  "principal": "$principal",
  "reason": "$reason",
  "status": "denied",
  "denial_reason": "insufficient_authorization"
}
EOF
)

    # Write to bypass audit log
    local audit_log="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/governance/bypass-audit.jsonl"
    mkdir -p "$(dirname "$audit_log")"
    echo "$audit_entry" >> "$audit_log"
}

# Check if bypass is currently active
is_bypass_active() {
    if [ -n "${BYPASS_EXPIRES_AT:-}" ]; then
        local current_time=$(date +%s)
        if [ "$current_time" -lt "$BYPASS_EXPIRES_AT" ]; then
            return 0  # Bypass is active
        else
            # Bypass expired
            unset BYPASS_EXPIRES_AT
            unset BYPASS_ID
            return 1
        fi
    fi
    return 1  # No active bypass
}

# End bypass early
end_bypass() {
    local bypass_id="${BYPASS_ID:-unknown}"

    if [ -n "$bypass_id" ]; then
        # Log bypass end
        local audit_entry=$(cat <<EOF
{
  "bypass_id": "$bypass_id",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "event": "bypass_ended",
  "principal": "${COMMIT_RELAY_PRINCIPAL:-system}"
}
EOF
)

        local audit_log="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/governance/bypass-audit.jsonl"
        echo "$audit_entry" >> "$audit_log"

        # Clear bypass variables
        unset BYPASS_EXPIRES_AT
        unset BYPASS_ID
    fi
}

# Get bypass statistics
get_bypass_stats() {
    local audit_log="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/governance/bypass-audit.jsonl"

    if [ ! -f "$audit_log" ]; then
        echo '{
  "total_bypasses": 0,
  "approved": 0,
  "denied": 0,
  "by_type": {},
  "by_risk": {}
}'
        return
    fi

    local total=$(wc -l < "$audit_log" | tr -d ' ' | tr -d '\n')
    local approved=$(grep '"status":"approved"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')
    local denied=$(grep '"status":"denied"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')

    # Count by type
    local validation=$(grep '"bypass_type":"validation"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')
    local governance=$(grep '"bypass_type":"governance"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')
    local access=$(grep '"bypass_type":"access"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')

    # Count by risk
    local critical=$(grep '"risk_level":"critical"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')
    local high=$(grep '"risk_level":"high"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')
    local medium=$(grep '"risk_level":"medium"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')
    local low=$(grep '"risk_level":"low"' "$audit_log" 2>/dev/null | wc -l | tr -d ' ' | tr -d '\n')

    local result=$(cat <<EOF
{
  "total_bypasses": $total,
  "approved": $approved,
  "denied": $denied,
  "by_type": {
    "validation": $validation,
    "governance": $governance,
    "access": $access
  },
  "by_risk": {
    "critical": $critical,
    "high": $high,
    "medium": $medium,
    "low": $low
  }
}
EOF
)

    echo "$result"
}

# Check if GOVERNANCE_BYPASS environment variable is set
check_env_bypass() {
    if [ "${GOVERNANCE_BYPASS:-false}" = "true" ]; then
        # Automatically audit environment-based bypass
        audit_bypass "governance" "GOVERNANCE_BYPASS=true environment variable" "environment" 60
        return 0
    fi
    return 1
}

# Export functions
export -f audit_bypass 2>/dev/null || true
export -f check_bypass_authorization 2>/dev/null || true
export -f calculate_bypass_risk 2>/dev/null || true
export -f log_bypass_denied 2>/dev/null || true
export -f is_bypass_active 2>/dev/null || true
export -f end_bypass 2>/dev/null || true
export -f get_bypass_stats 2>/dev/null || true
export -f check_env_bypass 2>/dev/null || true

# Log that bypass auditor is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[GOVERNANCE] Bypass auditor loaded" >&2
fi
