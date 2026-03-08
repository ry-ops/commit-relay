#!/bin/bash
# scripts/observers/run-git-ops.sh
# Git-Ops Observer - Automatic GitHub synchronization
# Part of Phase 1: Script-Triggered Automation

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/coordination.sh"

# Agent configuration
AGENT_ID="git-ops-observer"
GIT_OPS_MAX_RETRIES="${GIT_OPS_MAX_RETRIES:-3}"
GIT_OPS_DRY_RUN="${GIT_OPS_DRY_RUN:-false}"

# Acquire lock to prevent concurrent runs
if ! acquire_lock "$AGENT_ID"; then
    log_debug "Another git-ops observer is already running"
    exit 0  # Silent exit, not an error
fi

# Trap to ensure lock is released on exit
trap "release_lock $AGENT_ID" EXIT

# Navigate to project root
cd "$COMMIT_RELAY_HOME"

log_debug "Git-Ops Observer checking for changes..."

# Step 1: Pull latest from remote
git fetch origin main --quiet 2>/dev/null || log_warn "Failed to fetch from remote"

BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
if [ "$BEHIND" -gt 0 ]; then
    log_info "Local is $BEHIND commits behind remote, pulling..."
    git pull origin main --quiet
fi

# Step 2: Check for uncommitted changes
HAS_CHANGES=false

if ! git diff --quiet || ! git diff --cached --quiet; then
    HAS_CHANGES=true
fi

# Check for untracked coordination files
UNTRACKED=$(git ls-files --others --exclude-standard coordination/ agents/logs/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$UNTRACKED" -gt 0 ]; then
    HAS_CHANGES=true
fi

if [ "$HAS_CHANGES" = "false" ]; then
    log_debug "No uncommitted changes, exiting"
    exit 0
fi

log_section "Git-Ops: Syncing Changes to GitHub"

# Step 3: Analyze changes
CHANGED_FILES=$(git status --porcelain coordination/ agents/logs/ 2>/dev/null || echo "")

if [ -z "$CHANGED_FILES" ]; then
    log_debug "No coordination changes detected"
    exit 0
fi

log_info "Changes detected:"
echo "$CHANGED_FILES" | head -10 | while read -r line; do
    log_debug "  $line"
done

# Categorize changes
TASK_QUEUE_CHANGED=false
WORKER_POOL_CHANGED=false
BUDGET_CHANGED=false

if echo "$CHANGED_FILES" | grep -q "task-queue.json"; then
    TASK_QUEUE_CHANGED=true
fi

if echo "$CHANGED_FILES" | grep -q "worker-pool.json"; then
    WORKER_POOL_CHANGED=true
fi

if echo "$CHANGED_FILES" | grep -q "token-budget.json"; then
    BUDGET_CHANGED=true
fi

WORKER_LOGS=$(echo "$CHANGED_FILES" | grep "agents/logs/workers" | wc -l | tr -d ' ')

# Step 4: Generate commit message
COMMIT_TYPE="chore"
COMMIT_SCOPE="coordination"
COMMIT_SUBJECT=""

if [ "$TASK_QUEUE_CHANGED" = "true" ]; then
    COMMIT_TYPE="feat"
    COMMIT_SUBJECT="update task queue"
fi

if [ "$WORKER_POOL_CHANGED" = "true" ]; then
    COMMIT_TYPE="feat"
    COMMIT_SCOPE="workers"
    COMMIT_SUBJECT="update worker pool"
fi

if [ "$BUDGET_CHANGED" = "true" ]; then
    if [ -z "$COMMIT_SUBJECT" ]; then
        COMMIT_SUBJECT="update token budget"
    fi
fi

if [ "$WORKER_LOGS" -gt 0 ]; then
    COMMIT_TYPE="feat"
    COMMIT_SCOPE="workers"
    if [ -z "$COMMIT_SUBJECT" ]; then
        COMMIT_SUBJECT="add worker artifacts ($WORKER_LOGS files)"
    fi
fi

# Default subject
if [ -z "$COMMIT_SUBJECT" ]; then
    COMMIT_SUBJECT="sync coordination state"
fi

# Build full commit message
COMMIT_MESSAGE="${COMMIT_TYPE}(${COMMIT_SCOPE}): ${COMMIT_SUBJECT}

> Auto-synced by git-ops observer

Co-Authored-By: Git-Ops Observer <gitops@commit-relay.local>"

log_info "Commit message: $COMMIT_TYPE($COMMIT_SCOPE): $COMMIT_SUBJECT"

# Step 5: Stage and commit
log_info "Staging changes..."

git add coordination/ agents/logs/ 2>/dev/null || true

# Verify we have changes staged
if git diff --cached --quiet; then
    log_warn "No changes staged after git add, skipping"
    exit 0
fi

if [ "$GIT_OPS_DRY_RUN" = "true" ]; then
    log_warn "DRY RUN: Would have committed and pushed:"
    git diff --cached --stat
    exit 0
fi

log_info "Creating commit..."

if git commit -m "$COMMIT_MESSAGE" --quiet; then
    COMMIT_HASH=$(git rev-parse --short HEAD)
    log_success "Committed: $COMMIT_HASH"
else
    log_error "Failed to create commit"
    exit 1
fi

# Step 6: Push to GitHub with retry logic
log_info "Pushing to GitHub..."

RETRY_COUNT=0
PUSH_SUCCESS=false

while [ $RETRY_COUNT -lt $GIT_OPS_MAX_RETRIES ] && [ "$PUSH_SUCCESS" = "false" ]; do
    log_debug "Push attempt $((RETRY_COUNT + 1))/$GIT_OPS_MAX_RETRIES..."

    if git push origin main --quiet 2>/tmp/git-push-error.log; then
        PUSH_SUCCESS=true
        log_success "Pushed to GitHub successfully"
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))

        # Check error type
        if grep -q "rejected.*non-fast-forward" /tmp/git-push-error.log 2>/dev/null; then
            log_warn "Remote has diverged, pulling and retrying..."
            if git pull origin main --rebase --quiet; then
                log_info "Rebased successfully, retrying push..."
            else
                log_error "Failed to rebase, manual intervention needed"
                break
            fi
        else
            if [ $RETRY_COUNT -lt $GIT_OPS_MAX_RETRIES ]; then
                SLEEP_TIME=$((2 ** RETRY_COUNT))
                log_warn "Push failed, retrying in ${SLEEP_TIME}s..."
                sleep $SLEEP_TIME
            fi
        fi
    fi
done

if [ "$PUSH_SUCCESS" = "false" ]; then
    log_error "Failed to push after $GIT_OPS_MAX_RETRIES attempts"

    # Broadcast failure event
    broadcast_dashboard_event "git_ops_failed" "Failed to push coordination updates after $GIT_OPS_MAX_RETRIES attempts. Manual intervention required."

    exit 1
fi

# Step 7: Broadcast success
EVENT_DATA=$(jq -nc \
    --arg commit "$COMMIT_HASH" \
    --arg message "$COMMIT_SUBJECT" \
    '{
        commit_hash: $commit,
        commit_message: $message,
        timestamp: "'$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)'"
    }')

broadcast_dashboard_event "git_ops_success" "$EVENT_DATA"

log_success "Coordination synced to GitHub: $COMMIT_HASH"
log_info "View at: https://github.com/ry-ops/commit-relay/commit/$COMMIT_HASH"

exit 0
