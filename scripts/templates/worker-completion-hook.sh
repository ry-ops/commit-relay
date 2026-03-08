#!/bin/bash
# scripts/templates/worker-completion-hook.sh
# Template for worker completion with automatic git workflow
# Copy this template and customize for specific worker types

set -euo pipefail

# Get script directory and load libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load required libraries
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/coordination.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/git-automation.sh"

# Worker context (these should be set by the worker process)
WORKER_ID="${WORKER_ID:-unknown-worker}"
WORKER_TYPE="${WORKER_TYPE:-generic-worker}"
TASK_ID="${TASK_ID:-unknown-task}"
TASK_DESCRIPTION="${TASK_DESCRIPTION:-Worker completion}"

# Files changed by this worker (space-separated or array)
# Examples:
#   FILES_CHANGED="src/file1.js src/file2.js"
#   FILES_CHANGED=("dashboard/server/index.js" "dashboard/public/index.html")
FILES_CHANGED="${FILES_CHANGED:-}"

# Optional: Override commit message description
COMMIT_DESCRIPTION="${COMMIT_DESCRIPTION:-$TASK_DESCRIPTION}"

# Optional: Skip git automation (useful for testing)
SKIP_GIT_AUTO="${SKIP_GIT_AUTO:-false}"

log_section "Worker Completion Hook"
log_info "Worker ID: $WORKER_ID"
log_info "Worker Type: $WORKER_TYPE"
log_info "Task ID: $TASK_ID"
log_info ""

# ============================================================================
# Phase 1: Validate Worker Completion
# ============================================================================

log_info "Validating worker completion..."

# Check if worker actually completed successfully
# Add your validation logic here
VALIDATION_PASSED=true

if [ "$VALIDATION_PASSED" = "false" ]; then
    log_error "Worker validation failed, skipping git automation"
    exit 1
fi

log_success "Worker validation passed"
log_info ""

# ============================================================================
# Phase 2: Automatic Git Workflow
# ============================================================================

if [ "$SKIP_GIT_AUTO" = "true" ]; then
    log_warn "Git automation skipped (SKIP_GIT_AUTO=true)"
else
    log_section "Automatic Git Workflow"

    cd "$COMMIT_RELAY_HOME"

    # Convert FILES_CHANGED to array if it's a string
    if [ -n "$FILES_CHANGED" ]; then
        # If it's already an array, use it directly
        # Otherwise split string into array
        if [[ ! "$(declare -p FILES_CHANGED 2>/dev/null)" =~ "declare -a" ]]; then
            read -ra file_patterns <<< "$FILES_CHANGED"
        else
            file_patterns=("${FILES_CHANGED[@]}")
        fi
    else
        # No specific files, will add all changes
        file_patterns=()
    fi

    # Execute automatic commit and push
    if auto_commit_worker_changes "$WORKER_TYPE" "$TASK_ID" "$COMMIT_DESCRIPTION" "${file_patterns[@]}"; then
        GIT_STATUS="success"
        GIT_COMMIT_HASH=$(git rev-parse --short HEAD)
        log_success "Git workflow completed successfully"
        log_info "Commit: $GIT_COMMIT_HASH"

        # Record git operation
        record_git_operation "$WORKER_ID" "auto_commit_push" "success" "Commit: $GIT_COMMIT_HASH"
    else
        GIT_STATUS="failed"
        GIT_COMMIT_HASH=""
        log_error "Git workflow failed"

        # Record failure
        record_git_operation "$WORKER_ID" "auto_commit_push" "failed" "See worker logs"

        # Don't fail the entire worker, just log the error
        log_warn "Continuing despite git failure..."
    fi

    log_info ""
fi

# ============================================================================
# Phase 3: Update Worker Status
# ============================================================================

log_section "Updating Worker Status"

WORKER_SPEC="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${WORKER_ID}.json"

if [ -f "$WORKER_SPEC" ]; then
    # Update worker spec with completion info
    jq --arg status "completed" \
       --arg completed_at "$(date +%Y-%m-%dT%H:%M:%S%z)" \
       --arg git_status "${GIT_STATUS:-skipped}" \
       --arg commit_hash "${GIT_COMMIT_HASH:-}" \
       '.status = $status |
        .completed_at = $completed_at |
        .git_workflow = {
          status: $git_status,
          commit_hash: $commit_hash,
          automated: true
        }' \
       "$WORKER_SPEC" > "${WORKER_SPEC}.tmp"

    mv "${WORKER_SPEC}.tmp" "$WORKER_SPEC"

    log_success "Worker status updated"
else
    log_warn "Worker spec not found: $WORKER_SPEC"
fi

log_info ""

# ============================================================================
# Phase 4: Handoff to CI/CD Master (Optional)
# ============================================================================

# Uncomment this section if you want to hand off to CI/CD master
# for dashboard updates or other post-processing

# log_section "Handoff to CI/CD Master"
#
# HANDOFF_FILE="$COMMIT_RELAY_HOME/coordination/masters/cicd/handoffs/${WORKER_ID}-handoff.json"
#
# jq -nc \
#     --arg worker_id "$WORKER_ID" \
#     --arg task_id "$TASK_ID" \
#     --arg from "worker" \
#     --arg to "cicd-master" \
#     '{
#         handoff_id: ($worker_id + "-to-cicd"),
#         from: $from,
#         to: $to,
#         task_id: $task_id,
#         worker_id: $worker_id,
#         reason: "Post-deployment tasks (dashboard update, notifications)",
#         created_at: (now | todate),
#         context: {
#             git_commit: $git_commit_hash,
#             dashboard_update_required: true,
#             notification_required: false
#         }
#     }' > "$HANDOFF_FILE"
#
# log_success "Handoff created for CI/CD master"

# ============================================================================
# Completion
# ============================================================================

log_section "Worker Completion Summary"
log_success "Worker $WORKER_ID completed successfully"
log_info "Task: $TASK_ID"
if [ -n "${GIT_COMMIT_HASH:-}" ]; then
    log_info "Git Commit: $GIT_COMMIT_HASH"
fi
log_info ""

exit 0
