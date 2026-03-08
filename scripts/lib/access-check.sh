#!/bin/bash
# Access Control Helper Functions
# Provides permission checking for all commit-relay scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/access-check.sh"
#   check_permission "$principal" "$asset" "$operation" || exit 1

# Configuration
GOVERNANCE_LIB="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/Projects/commit-relay}/lib/governance"
ACCESS_CLI="$GOVERNANCE_LIB/access-cli.js"

# Permission check cache disabled for Bash 3.2 compatibility
# (Associative arrays require Bash 4+)
# Future: Use temp file-based cache if needed

# Cache expiry time (5 minutes in seconds) - disabled for now
CACHE_EXPIRY=300

# Statistics
CHECKS_TOTAL=0
CHECKS_ALLOWED=0
CHECKS_DENIED=0
CHECKS_CACHED=0

# Color codes for output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m"  # No Color

##
# Check if a principal has permission to perform an operation on an asset
#
# Args:
#   $1 - Principal (e.g., "coordinator-master", "dev-worker-ABC")
#   $2 - Asset (e.g., "task-queue", "worker-specs", path to file)
#   $3 - Operation (read, write, execute, admin)
#
# Returns:
#   0 if allowed, 1 if denied
#
# Example:
#   check_permission "coordinator-master" "task-queue" "read" || exit 1
##
check_permission() {
    local principal="$1"
    local asset="$2"
    local operation="$3"
    local start_time=$(date +%s%N)

    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

    # Perform permission check using Node.js CLI
    # Note: Caching disabled for Bash 3.2 compatibility
    local result
    if result=$(node "$ACCESS_CLI" check "$principal" "$asset" "$operation" 2>&1); then
        # Permission granted
        CHECKS_ALLOWED=$((CHECKS_ALLOWED + 1))

        # Calculate latency
        local end_time=$(date +%s%N)
        local latency_ns=$((end_time - start_time))
        local latency_ms=$((latency_ns / 1000000))

        if [ "${ACCESS_CHECK_VERBOSE:-0}" == "1" ]; then
            echo -e "${GREEN}✓ Permission granted${NC}: $principal can $operation $asset (${latency_ms}ms)" >&2
        fi

        return 0
    else
        # Permission denied
        CHECKS_DENIED=$((CHECKS_DENIED + 1))

        # Calculate latency
        local end_time=$(date +%s%N)
        local latency_ns=$((end_time - start_time))
        local latency_ms=$((latency_ns / 1000000))

        echo -e "${RED}✗ Permission denied${NC}: $principal cannot $operation $asset" >&2
        echo -e "${YELLOW}Reason:${NC} $result" >&2

        return 1
    fi
}

##
# Quick permission check (returns true/false without logging)
#
# Args:
#   Same as check_permission
#
# Returns:
#   "true" if allowed, "false" if denied
##
has_permission() {
    if check_permission "$1" "$2" "$3" 2>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

##
# Require permission (exits script if denied)
#
# Args:
#   Same as check_permission
#
# Example:
#   require_permission "coordinator-master" "task-queue" "write"
##
require_permission() {
    if ! check_permission "$1" "$2" "$3"; then
        echo -e "${RED}FATAL: Required permission denied${NC}" >&2
        exit 1
    fi
}

##
# Log access decision (explicit logging for audit trail)
#
# Args:
#   $1 - Principal
#   $2 - Asset
#   $3 - Operation
#   $4 - Result (allowed|denied)
#   $5 - Reason (optional)
##
log_access_decision() {
    local principal="$1"
    local asset="$2"
    local operation="$3"
    local result="$4"
    local reason="${5:-}"

    # This is handled automatically by the AccessControl class
    # but can be called explicitly if needed
    :
}

##
# Get current principal from context
# Attempts to determine who is running this script
#
# Returns:
#   Principal identifier
##
get_current_principal() {
    # Check environment variable first
    if [ -n "${COMMIT_RELAY_PRINCIPAL:-}" ]; then
        echo "$COMMIT_RELAY_PRINCIPAL"
        return
    fi

    # Check if we're in a master context
    if [ -n "${MASTER_ID:-}" ]; then
        echo "$MASTER_ID"
        return
    fi

    # Check if we're in a worker context
    if [ -n "${WORKER_ID:-}" ]; then
        echo "$WORKER_ID"
        return
    fi

    # Default to system
    echo "system"
}

##
# Check if asset contains PII or sensitive data
#
# Args:
#   $1 - Asset identifier or path
#
# Returns:
#   0 if sensitive, 1 if not
##
is_sensitive_asset() {
    local asset="$1"

    # Check for common sensitive patterns
    if [[ "$asset" =~ (pii|secret|credential|password|token|api[_-]?key) ]]; then
        return 0
    fi

    # Check catalog for sensitivity classification
    # (Would query catalog-manager here in full implementation)

    return 1
}

##
# Show access control statistics for current session
##
show_access_stats() {
    local cache_hit_rate=0
    if [ $CHECKS_TOTAL -gt 0 ]; then
        cache_hit_rate=$(awk "BEGIN {printf \"%.1f\", ($CHECKS_CACHED / $CHECKS_TOTAL) * 100}")
    fi

    echo ""
    echo "Access Control Statistics:"
    echo "  Total Checks: $CHECKS_TOTAL"
    echo "  Allowed: $CHECKS_ALLOWED"
    echo "  Denied: $CHECKS_DENIED"
    echo "  Cached: $CHECKS_CACHED (${cache_hit_rate}%)"
    echo ""
}

##
# Initialize access control system
# Called automatically when script is sourced
##
_init_access_control() {
    # Verify that access control CLI exists
    if [ ! -f "$ACCESS_CLI" ]; then
        echo -e "${YELLOW}Warning: Access control CLI not found at $ACCESS_CLI${NC}" >&2
        echo -e "${YELLOW}Permission checks will be disabled${NC}" >&2

        # Create stub function that always returns true
        check_permission() { return 0; }
        require_permission() { return 0; }
    fi
}

# Initialize when sourced
_init_access_control

# Export functions
export -f check_permission
export -f has_permission
export -f require_permission
export -f log_access_decision
export -f get_current_principal
export -f is_sensitive_asset
export -f show_access_stats
