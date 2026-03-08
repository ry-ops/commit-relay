#!/bin/bash
# scripts/examples/autonomous-worker-demo.sh
# Demonstration of fully autonomous worker with automatic git workflow
# This worker creates a simple test file, then automatically commits and pushes

set -euo pipefail

# === Worker Configuration ===
export WORKER_ID="autonomous-demo-$(date +%s)"
export WORKER_TYPE="implementation-worker"
export TASK_ID="${TASK_ID:-demo-task}"
export TASK_DESCRIPTION="Autonomous workflow demonstration - automated git commit and push"
export COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Load logging library for pretty output
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh"

log_section "Autonomous Worker Demo"
log_info "Worker ID: $WORKER_ID"
log_info "Task ID: $TASK_ID"
log_info "Working Directory: $COMMIT_RELAY_HOME"
log_info ""

# === Phase 1: Do Some Work ===
log_section "Phase 1: Performing Work"

cd "$COMMIT_RELAY_HOME"

# Create a demo directory if it doesn't exist
mkdir -p examples/autonomous-demo

# Create/update a demo file
DEMO_FILE="examples/autonomous-demo/demo-$(date +%Y%m%d-%H%M%S).txt"
cat > "$DEMO_FILE" <<EOF
Autonomous Worker Demonstration
================================

Worker ID: $WORKER_ID
Task ID: $TASK_ID
Timestamp: $(date +%Y-%m-%dT%H:%M:%S%z)

This file was created automatically by an autonomous commit-relay worker.

The worker:
1. Created this file
2. Automatically staged it with git add
3. Created a descriptive commit message
4. Pushed to GitHub - all without manual intervention!

This demonstrates the fully autonomous CI/CD workflow of commit-relay.

🤖 Generated with Claude Code
EOF

log_success "Created demo file: $DEMO_FILE"
log_info ""

# Update a tracking file
TRACKER_FILE="examples/autonomous-demo/execution-log.txt"
echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] Worker $WORKER_ID completed successfully" >> "$TRACKER_FILE"

log_success "Updated execution log"
log_info ""

# Specify which files to commit
export FILES_CHANGED="$DEMO_FILE $TRACKER_FILE"

log_info "Files changed by this worker:"
log_info "  - $DEMO_FILE"
log_info "  - $TRACKER_FILE"
log_info ""

# === Phase 2: Automatic Git Workflow ===
log_section "Phase 2: Automatic Git Workflow"
log_info "The worker completion hook will now:"
log_info "  1. Stage the changed files"
log_info "  2. Check for sensitive data"
log_info "  3. Create a commit with conventional format"
log_info "  4. Push to origin/main"
log_info "  5. Update worker status"
log_info "  6. Record the git operation"
log_info ""

# Execute the automatic completion hook
# This handles ALL git operations automatically!
source "$COMMIT_RELAY_HOME/scripts/templates/worker-completion-hook.sh"

# === End ===
# Note: We never reach here because the completion hook exits
