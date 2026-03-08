#!/bin/bash
# scripts/coordinate-task-git.sh
# CLI tool for coordinating git operations across multiple workers
# Used by CI/CD master

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/git-coordination.sh"

# Usage information
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Coordinate git operations across multiple workers for a task.

COMMANDS:
    wait        Wait for workers to complete and coordinate commits
    branch      Create feature branch for task
    pr          Create pull request from completed workers
    status      Show git coordination status for task

OPTIONS:
    --task-id ID             Task identifier (required)
    --description DESC       Task description
    --worker-count NUM       Expected number of workers (default: 1)
    --timeout MINUTES        Wait timeout in minutes (default: 30)
    --help                   Show this help message

EXAMPLES:
    # Wait for 3 workers to complete, then create PR if needed
    $0 wait --task-id task-050 --worker-count 3 --description "Add auth feature"

    # Create feature branch for task
    $0 branch --task-id task-051 --description "Database migration"

    # Create PR from completed workers
    $0 pr --task-id task-052 --description "API refactoring"

    # Check coordination status
    $0 status --task-id task-053

EOF
    exit 1
}

# Parse arguments
COMMAND="${1:-}"
shift || true

TASK_ID=""
DESCRIPTION=""
WORKER_COUNT=1
TIMEOUT=30

while [[ $# -gt 0 ]]; do
    case $1 in
        --task-id)
            TASK_ID="$2"
            shift 2
            ;;
        --description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --worker-count)
            WORKER_COUNT="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$TASK_ID" ]; then
    echo "Error: --task-id is required"
    usage
fi

cd "$COMMIT_RELAY_HOME"

# Execute command
case "$COMMAND" in
    wait)
        log_section "Wait for Workers and Coordinate"
        coordinate_multi_worker_task "$TASK_ID" "$DESCRIPTION" "$WORKER_COUNT"
        ;;

    branch)
        log_section "Create Feature Branch"
        if [ -z "$DESCRIPTION" ]; then
            echo "Error: --description is required for branch command"
            exit 1
        fi
        create_feature_branch "$TASK_ID" "$DESCRIPTION"
        ;;

    pr)
        log_section "Create Pull Request"
        if [ -z "$DESCRIPTION" ]; then
            echo "Error: --description is required for pr command"
            exit 1
        fi

        # Get workers for this task
        local completed_workers=$(wait_for_workers "$TASK_ID" "$WORKER_COUNT" 1)
        local worker_array=($completed_workers)

        if [ ${#worker_array[@]} -eq 0 ]; then
            log_error "No completed workers found for task $TASK_ID"
            exit 1
        fi

        create_consolidated_pr "$TASK_ID" "$DESCRIPTION" "${worker_array[@]}"
        ;;

    status)
        log_section "Git Coordination Status"
        log_info "Task ID: $TASK_ID"
        echo ""

        # Get commits
        local commits=$(get_worker_commits "$TASK_ID")
        if [ -n "$commits" ]; then
            log_success "Found commits:"
            for commit in $commits; do
                local msg=$(git log --format=%s -n 1 "$commit" 2>/dev/null || echo "Unknown")
                echo "  - $commit: $msg"
            done
        else
            log_warn "No commits found for task $TASK_ID"
        fi

        echo ""

        # Check if feature branch needed
        if should_use_feature_branch "$TASK_ID"; then
            log_info "Recommendation: Create feature branch (many files changed)"
        else
            log_info "Recommendation: Direct to main (few files changed)"
        fi
        ;;

    *)
        echo "Unknown command: $COMMAND"
        usage
        ;;
esac
