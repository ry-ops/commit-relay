#!/bin/bash
# scripts/start-worker.sh
# Automatically start a pending worker in a new Claude Code session

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"
source "$SCRIPT_DIR/lib/worker-reflection.sh" 2>/dev/null || true

# Check for worker ID argument
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <worker-id>"
    log_info "Example: $0 worker-scan-001"
    exit 1
fi

WORKER_ID="$1"
WORKER_SPEC_PATH="$COMMIT_RELAY_HOME/coordination/worker-specs/active/${WORKER_ID}.json"

# Verify worker specification exists
if [ ! -f "$WORKER_SPEC_PATH" ]; then
    log_error "Worker specification not found: $WORKER_SPEC_PATH"
    exit 1
fi

log_section "Starting Worker: $WORKER_ID"

# Read worker details
WORKER_TYPE=$(jq -r '.worker_type' "$WORKER_SPEC_PATH")
PROMPT_TEMPLATE=$(jq -r '.prompt_template' "$WORKER_SPEC_PATH")
TASK_ID=$(jq -r '.task_id' "$WORKER_SPEC_PATH")
STATUS=$(jq -r '.status' "$WORKER_SPEC_PATH")

log_info "Worker Type: $WORKER_TYPE"
log_info "Task ID: $TASK_ID"
log_info "Status: $STATUS"
log_info "Prompt: $PROMPT_TEMPLATE"

# Check if worker is already running
if [ "$STATUS" = "running" ]; then
    log_warn "Worker $WORKER_ID is already running"
    exit 0
fi

# Verify prompt template exists
FULL_PROMPT_PATH="$COMMIT_RELAY_HOME/$PROMPT_TEMPLATE"
if [ ! -f "$FULL_PROMPT_PATH" ]; then
    log_error "Prompt template not found: $FULL_PROMPT_PATH"
    exit 1
fi

log_section "Launching Claude CLI Session"
log_info "Prompt: $FULL_PROMPT_PATH"
log_info ""
log_info "The worker will:"
log_info "  1. Read its specification from: $WORKER_SPEC_PATH"
log_info "  2. Execute its assigned task: $TASK_ID"
log_info "  3. Update coordination state with results"
log_info "  4. Auto-commit and push to GitHub"
log_info ""

# Update worker status to running
UPDATE_DATA=$(jq -nc \
    --arg started "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{started_at: $started}')

# Use jq to update the worker spec file
jq --arg started "$(date +%Y-%m-%dT%H:%M:%S%z)" \
   '.status = "running" | .execution.started_at = $started' \
   "$WORKER_SPEC_PATH" > "${WORKER_SPEC_PATH}.tmp" && \
   mv "${WORKER_SPEC_PATH}.tmp" "$WORKER_SPEC_PATH"

log_success "Worker status updated to 'running'"

# Broadcast dashboard event
EVENT_DATA=$(jq -nc \
    --arg worker "$WORKER_ID" \
    --arg task "$TASK_ID" \
    --arg type "$WORKER_TYPE" \
    '{worker_id: $worker, task_id: $task, worker_type: $type}')
broadcast_dashboard_event "worker_started" "$EVENT_DATA"

log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Starting Claude CLI with prompt..."
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""

# Launch Claude CLI in interactive mode with prompt
# Workers need full tool access, not print mode
claude "$(cat "$COMMIT_RELAY_HOME/$PROMPT_TEMPLATE")"

# Phase 3 Enhancement #17: Worker self-correction via reflection
# After worker completes, perform validation before marking complete
log_section "Worker Reflection Phase"

# Check if worker-reflection is available
if type perform_reflection &>/dev/null; then
    log_info "Performing self-correction validation..."

    # Get output location from worker spec if available
    OUTPUT_LOCATION=$(jq -r '.results.output_location // ""' "$WORKER_SPEC_PATH" 2>/dev/null || echo "")

    # Perform reflection
    REFLECTION_RESULT=$(perform_reflection "$WORKER_ID" "$TASK_ID" "$OUTPUT_LOCATION" 2>/dev/null || echo '{"passed": true}')

    # Check if reflection passed
    REFLECTION_PASSED=$(echo "$REFLECTION_RESULT" | jq -r '.passed // true')
    RECOMMENDATION=$(echo "$REFLECTION_RESULT" | jq -r '.recommendation // "complete"')

    if [ "$REFLECTION_PASSED" = "true" ]; then
        log_success "Reflection validation passed"

        # Update worker spec with reflection results
        if [ -n "$REFLECTION_RESULT" ] && [ "$REFLECTION_RESULT" != '{"passed": true}' ]; then
            jq --argjson reflection "$REFLECTION_RESULT" \
               '.reflection = $reflection' \
               "$WORKER_SPEC_PATH" > "${WORKER_SPEC_PATH}.tmp" && \
               mv "${WORKER_SPEC_PATH}.tmp" "$WORKER_SPEC_PATH"
            log_info "Reflection results saved to worker spec"
        fi
    else
        log_warn "Reflection validation found issues"
        log_warn "Recommendation: $RECOMMENDATION"

        # Log correction suggestions
        SUGGESTIONS=$(echo "$REFLECTION_RESULT" | jq -r '.correction_suggestions.suggestions[]' 2>/dev/null || echo "")
        if [ -n "$SUGGESTIONS" ]; then
            log_info "Suggested corrections:"
            echo "$SUGGESTIONS" | while read -r suggestion; do
                log_info "  - $suggestion"
            done
        fi

        # Save reflection results even on failure
        jq --argjson reflection "$REFLECTION_RESULT" \
           '.reflection = $reflection | .results.status = "needs_correction"' \
           "$WORKER_SPEC_PATH" > "${WORKER_SPEC_PATH}.tmp" && \
           mv "${WORKER_SPEC_PATH}.tmp" "$WORKER_SPEC_PATH"

        # Emit event for monitoring
        EVENT_DATA=$(jq -nc \
            --arg worker "$WORKER_ID" \
            --arg task "$TASK_ID" \
            --arg recommendation "$RECOMMENDATION" \
            '{worker_id: $worker, task_id: $task, recommendation: $recommendation}')
        broadcast_dashboard_event "worker_needs_correction" "$EVENT_DATA"
    fi
else
    log_info "Worker reflection library not available, skipping validation"
fi

log_section "Worker Session Complete"
log_info "Worker $WORKER_ID has finished execution"
log_info "Check worker spec for results: $WORKER_SPEC_PATH"
