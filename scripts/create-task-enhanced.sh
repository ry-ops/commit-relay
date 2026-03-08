#!/bin/bash
# scripts/create-task-enhanced.sh
# ENHANCED Task Management CLI with Core Principles Foundation
#
# Enhancements:
# - Uses init-common.sh for automatic initialization
# - Validates all JSON before writing
# - Emits observability events
# - Enforces governance checks
# - Prevents malformed task specs

# Note: Using -e pipefail (not -u) for compatibility with existing logging.sh
set -e
set -o pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set log level before loading (required for logging.sh compatibility)
export COMMIT_RELAY_LOG_LEVEL=1  # INFO level

# 🎯 NEW: Use core foundation (replaces manual library loading)
source "$SCRIPT_DIR/lib/init-common.sh" || exit 99

# Start tracing this operation
OPERATION_ID="create-task-$(date +%s)"
trace_start "task.create" "$OPERATION_ID"

# Colors for interactive mode
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
TASK_TYPE=""
REPOSITORY=""
PRIORITY="high"
BRANCH="main"
DESCRIPTION=""
SCAN_TYPES='["dependencies", "static-analysis", "secrets"]'
BATCH_FILE=""
INTERACTIVE=false

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Enhanced Task Management CLI for Commit-Relay
✨ Now with automatic validation and observability!

MODES:
  Interactive:  $0                           (no arguments)
  CLI:          $0 --type TYPE --repo REPO [OPTIONS]

OPTIONS:
  --type TYPE              Task type (security-scan, security-fix, development)
  --repo REPO              Repository (e.g., ry-ops/commit-relay)
  --priority PRIORITY      Priority: critical, high, medium, low (default: high)
  --branch BRANCH          Branch name (default: main)
  --description DESC       Task description
  --help                   Show this help

EXAMPLES:
  # Interactive mode
  $0

  # Create security scan task
  $0 --type security-scan --repo ry-ops/commit-relay --priority high

  # Create development task
  $0 --type development --repo ry-ops/mcp-server --description "Add new feature"

ENHANCEMENTS IN THIS VERSION:
  ✅ Automatic JSON validation (prevents malformed tasks)
  ✅ Observability events (trace task creation)
  ✅ Governance enforcement (permission checks)
  ✅ Schema validation (ensures task structure is correct)
  ✅ Safe JSON writing (atomic operations)

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            TASK_TYPE="$2"
            shift 2
            ;;
        --repo)
            REPOSITORY="$2"
            shift 2
            ;;
        --priority)
            PRIORITY="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Interactive mode if no arguments
if [ -z "$TASK_TYPE" ]; then
    INTERACTIVE=true
    echo -e "${CYAN}=== Commit-Relay Enhanced Task Creator ===${NC}"
    echo -e "${GREEN}✨ With automatic validation and observability${NC}"
    echo ""

    # Select task type
    echo -e "${BLUE}Select task type:${NC}"
    echo "1) security-scan    - Scan repository for vulnerabilities"
    echo "2) security-fix     - Fix identified vulnerabilities"
    echo "3) development      - Development task"
    read -p "Enter choice (1-3): " type_choice

    case $type_choice in
        1) TASK_TYPE="security-scan" ;;
        2) TASK_TYPE="security-fix" ;;
        3) TASK_TYPE="development" ;;
        *)
            log_error "Invalid choice"
            trace_end "task.create" "failed"
            exit 1
            ;;
    esac

    # Get repository
    read -p "Repository (e.g., ry-ops/commit-relay): " REPOSITORY

    # Get priority
    echo -e "${BLUE}Select priority:${NC}"
    echo "1) critical"
    echo "2) high"
    echo "3) medium"
    echo "4) low"
    read -p "Enter choice (1-4, default=2): " priority_choice

    case ${priority_choice:-2} in
        1) PRIORITY="critical" ;;
        2) PRIORITY="high" ;;
        3) PRIORITY="medium" ;;
        4) PRIORITY="low" ;;
        *) PRIORITY="high" ;;
    esac

    # Get description
    read -p "Description (optional): " DESCRIPTION
fi

# Validate required fields
if [ -z "$TASK_TYPE" ] || [ -z "$REPOSITORY" ]; then
    log_error "Task type and repository are required"
    trace_event "task.validation.failed" "error" '{"reason":"missing_required_fields"}'
    trace_end "task.create" "failed"
    exit 1
fi

log_info "Creating task: $TASK_TYPE for $REPOSITORY"
trace_event "task.validation.started" "info" "{\"type\":\"$TASK_TYPE\",\"repo\":\"$REPOSITORY\"}"

# 🎯 NEW: Check governance permission
if ! check_permission "$COMMIT_RELAY_PRINCIPAL" "task-queue" "write"; then
    log_error "Permission denied: Cannot create tasks"
    trace_event "task.permission.denied" "error" "{\"principal\":\"$COMMIT_RELAY_PRINCIPAL\"}"
    trace_end "task.create" "failed"
    exit 1
fi

log_debug "Permission check passed for $COMMIT_RELAY_PRINCIPAL"
trace_event "task.permission.granted" "success" "{\"principal\":\"$COMMIT_RELAY_PRINCIPAL\"}"

# Generate task ID
TASK_ID="task-${TASK_TYPE}-$(date +%s)"

# Create task spec based on type
case $TASK_TYPE in
    security-scan)
        TITLE="Security Scan: $REPOSITORY"
        REQUIREMENTS=$(cat <<EOF
{
  "scan_types": $SCAN_TYPES,
  "repository": "$REPOSITORY",
  "branch": "$BRANCH",
  "severity_threshold": "medium"
}
EOF
)
        ;;
    security-fix)
        TITLE="Security Fix: $REPOSITORY"
        REQUIREMENTS=$(cat <<EOF
{
  "repository": "$REPOSITORY",
  "branch": "$BRANCH",
  "create_pr": true
}
EOF
)
        ;;
    development)
        TITLE="${DESCRIPTION:-Development Task: $REPOSITORY}"
        REQUIREMENTS=$(cat <<EOF
{
  "repository": "$REPOSITORY",
  "branch": "$BRANCH"
}
EOF
)
        ;;
    *)
        log_error "Unknown task type: $TASK_TYPE"
        trace_end "task.create" "failed"
        exit 1
        ;;
esac

# Determine goal specification for this task type (Week 3: Goal-Based Planning)
case $TASK_TYPE in
    security-scan)
        GOAL_SPEC='{"goal_type":"analysis","expected_deliverables":["vulnerability_report","recommendations"],"success_criteria":"All specified scans completed"}'
        ;;
    security-fix)
        GOAL_SPEC='{"goal_type":"bug-fixes","expected_deliverables":["fixed_code","tests","pr"],"success_criteria":"Vulnerabilities remediated and verified"}'
        ;;
    development)
        GOAL_SPEC='{"goal_type":"feature-development","expected_deliverables":["implementation","tests","documentation"],"success_criteria":"Feature works as specified"}'
        ;;
    *)
        GOAL_SPEC='{"goal_type":"general","expected_deliverables":[],"success_criteria":"Task completed successfully"}'
        ;;
esac

# Build complete task specification
TASK_SPEC=$(cat <<EOF
{
  "id": "$TASK_ID",
  "title": "$TITLE",
  "description": "$DESCRIPTION",
  "type": "$TASK_TYPE",
  "priority": "$PRIORITY",
  "status": "pending",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "assigned_to": null,
  "requirements": $REQUIREMENTS,
  "goal_specification": $GOAL_SPEC,
  "metadata": {
    "created_by": "$COMMIT_RELAY_PRINCIPAL",
    "trace_id": "$TRACE_ID"
  }
}
EOF
)

log_debug "Task specification created"
trace_event "task.spec.created" "success" "{\"task_id\":\"$TASK_ID\"}"

# 🎯 NEW: Validate task spec before adding to queue
log_info "Validating task specification..."

# Validate JSON syntax
if ! validate_json_syntax "$TASK_SPEC"; then
    log_error "Task specification has invalid JSON syntax"
    trace_event "task.validation.failed" "error" '{"reason":"invalid_json_syntax"}'
    trace_end "task.create" "failed"
    exit 1
fi

# Validate required fields
if ! validate_required_fields "$TASK_SPEC" "id" "title" "type" "priority" "status"; then
    log_error "Task specification missing required fields"
    trace_event "task.validation.failed" "error" '{"reason":"missing_required_fields"}'
    trace_end "task.create" "failed"
    exit 1
fi

log_info "✅ Task specification validation passed"
trace_event "task.validation.success" "success" "{\"task_id\":\"$TASK_ID\"}"

# Read current task queue
TASK_QUEUE_FILE="$COMMIT_RELAY_HOME/coordination/task-queue.json"

if [ ! -f "$TASK_QUEUE_FILE" ]; then
    log_warn "Task queue not found, creating new one"
    TASK_QUEUE='{"tasks":[],"last_updated":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
else
    TASK_QUEUE=$(cat "$TASK_QUEUE_FILE")
fi

# Add task to queue
UPDATED_QUEUE=$(echo "$TASK_QUEUE" | jq \
    --argjson task "$TASK_SPEC" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.tasks += [$task] | .last_updated = $updated')

# 🎯 NEW: Use safe_write_json instead of direct write
log_info "Writing task to queue with validation..."
if safe_write_json "$UPDATED_QUEUE" "$TASK_QUEUE_FILE" "none"; then
    log_info "✅ Task created successfully: $TASK_ID"
    trace_event "task.created" "success" "{\"task_id\":\"$TASK_ID\",\"type\":\"$TASK_TYPE\"}"
else
    log_error "Failed to write task to queue"
    trace_event "task.write.failed" "error" "{\"task_id\":\"$TASK_ID\"}"
    trace_end "task.create" "failed"
    exit 1
fi

# Display success message
echo ""
echo -e "${GREEN}✅ Task Created Successfully!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Task ID:      ${YELLOW}$TASK_ID${NC}"
echo -e "Type:         $TASK_TYPE"
echo -e "Repository:   $REPOSITORY"
echo -e "Priority:     $PRIORITY"
echo -e "Status:       pending"
echo -e "Trace ID:     $TRACE_ID"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Enhanced Features Used:${NC}"
echo -e "  ✅ JSON validation (prevents malformed tasks)"
echo -e "  ✅ Permission check (governance enforced)"
echo -e "  ✅ Observability events (trace ID: $TRACE_ID)"
echo -e "  ✅ Safe atomic write (prevents data corruption)"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. View task: jq '.tasks[] | select(.id == \"$TASK_ID\")' $TASK_QUEUE_FILE"
echo "  2. Check events: cat coordination/observability/events/all-events.jsonl | grep $TRACE_ID"
echo "  3. Monitor: Open dashboard at http://localhost:3000/"
echo ""

# End tracing
trace_end "task.create" "success"

exit 0
