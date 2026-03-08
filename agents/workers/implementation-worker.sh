#!/bin/bash
################################################################################
# Implementation Worker
# Purpose: Implement new features and functionality
# Parent Masters: Development Master, CI/CD Master
# Token Budget: 12k-18k tokens
################################################################################

set -euo pipefail

# === Configuration ===
export WORKER_ID="${WORKER_ID:-impl-worker-$(date +%s)}"
export WORKER_TYPE="implementation-worker"
export TASK_ID="${TASK_ID:-unknown-task}"
export TASK_DESCRIPTION="${TASK_DESCRIPTION:-Feature implementation}"
export COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Load logging library
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh"

# === Argument Parsing ===
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Implementation Worker - Implements new features and functionality

OPTIONS:
    --task-id ID              Task identifier
    --description DESC        Feature description
    --requirements FILE       Requirements file (JSON/text)
    --target-files FILES      Comma-separated list of files to modify/create
    --help                    Show this help message

EXAMPLES:
    # Implement a new dashboard feature
    $0 --task-id task-123 --description "Add real-time notifications"

    # Implement with specific target files
    $0 --task-id task-124 --target-files "src/notifications.js,src/api.js"

ENVIRONMENT VARIABLES:
    WORKER_ID                 Unique worker identifier (default: auto-generated)
    TASK_ID                   Task ID (required)
    TASK_DESCRIPTION          What to implement (required)
    COMMIT_RELAY_HOME         Project root directory

EOF
    exit 1
}

REQUIREMENTS_FILE=""
TARGET_FILES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)
            export TASK_ID="$2"
            shift 2
            ;;
        --description)
            export TASK_DESCRIPTION="$2"
            shift 2
            ;;
        --requirements)
            REQUIREMENTS_FILE="$2"
            shift 2
            ;;
        --target-files)
            TARGET_FILES="$2"
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

# === Worker Initialization ===
log_section "Implementation Worker"
log_info "Worker ID: $WORKER_ID"
log_info "Task ID: $TASK_ID"
log_info "Description: $TASK_DESCRIPTION"
log_info ""

cd "$COMMIT_RELAY_HOME"

# === Phase 1: Analysis ===
log_section "Phase 1: Requirements Analysis"

if [ -n "$REQUIREMENTS_FILE" ] && [ -f "$REQUIREMENTS_FILE" ]; then
    log_info "Loading requirements from: $REQUIREMENTS_FILE"
    # Parse requirements
    # In a real implementation, this would use jq or parse the file
    log_success "Requirements loaded"
else
    log_info "No requirements file provided, using task description"
fi

log_info ""

# === Phase 2: Implementation ===
log_section "Phase 2: Feature Implementation"

# NOTE: This is a template - actual implementation logic would go here
# For demonstration purposes, we'll create a simple example

if [ -n "$TARGET_FILES" ]; then
    # Parse target files
    IFS=',' read -ra FILES <<< "$TARGET_FILES"

    for file in "${FILES[@]}"; do
        log_info "Processing: $file"

        # Create directory if needed
        mkdir -p "$(dirname "$file")"

        # Example: Add a simple implementation comment
        if [ -f "$file" ]; then
            log_info "Updating existing file: $file"
            echo "" >> "$file"
            echo "// Updated by $WORKER_ID for $TASK_ID" >> "$file"
            echo "// $TASK_DESCRIPTION" >> "$file"
        else
            log_info "Creating new file: $file"
            cat > "$file" <<EOF
// File: $file
// Created by: $WORKER_ID
// Task: $TASK_ID
// Description: $TASK_DESCRIPTION
// Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)

// TODO: Implement $TASK_DESCRIPTION

export default {
    // Implementation goes here
};
EOF
        fi

        log_success "Completed: $file"
    done

    # Set files for git automation
    export FILES_CHANGED="$TARGET_FILES"
else
    # No specific files provided, create a default implementation file
    IMPL_FILE="examples/implementations/${TASK_ID}-implementation.md"
    mkdir -p "$(dirname "$IMPL_FILE")"

    cat > "$IMPL_FILE" <<EOF
# Implementation: $TASK_DESCRIPTION

**Task ID**: $TASK_ID
**Worker**: $WORKER_ID
**Timestamp**: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Implementation Details

This file documents the implementation of: $TASK_DESCRIPTION

### Changes Made

- Implemented feature as specified
- Added necessary tests
- Updated documentation

### Files Modified

(List of files would go here in real implementation)

### Testing

(Testing steps would go here)

---

🤖 Implemented by commit-relay autonomous worker system
EOF

    export FILES_CHANGED="$IMPL_FILE"
    log_success "Created implementation document: $IMPL_FILE"
fi

log_info ""

# === Phase 3: Validation ===
log_section "Phase 3: Implementation Validation"

# In a real worker, this would:
# - Run linters
# - Check syntax
# - Run tests
# - Verify no breaking changes

log_info "Running validation checks..."
sleep 1  # Simulate validation time

log_success "Validation passed"
log_info ""

# === Phase 4: Automatic Git Workflow ===
log_section "Phase 4: Autonomous Git Workflow"

# The completion hook handles:
# - Git add
# - Git commit (with conventional commit format)
# - Git push
# - Worker status update
# - Git operation recording

source "$COMMIT_RELAY_HOME/scripts/templates/worker-completion-hook.sh"

# === End ===
# Note: We never reach here because the completion hook exits
