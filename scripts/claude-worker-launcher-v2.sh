#!/bin/bash

# Claude Worker Launcher v2.2 - HEADLESS MODE
# Enhanced launcher with TRUE headless execution (no Terminal.app)
# v2.2: Replaced Terminal.app/osascript with nohup background execution
# v2.1: Fixed placeholder substitution bug + added governance validation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER_ID="$1"
TASK_ID="$2"
WORKER_TYPE="${3:-implementation-worker}"

# Log function
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] LAUNCHER: $1" >> "$PROJECT_ROOT/agents/logs/system/launcher.log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] LAUNCHER: $1"
}

# FIX #3: Add NVM paths to ensure claude CLI is available
# This fixes the "claude command not found" error for background processes
export PATH="/Users/ryandahlberg/.nvm/versions/node/v24.11.0/bin:$PATH"

log "============================================"
log "Starting enhanced worker launcher v2.2 (HEADLESS) for $WORKER_ID"
log "Task: $TASK_ID, Type: $WORKER_TYPE"

# FIX #2: INPUT VALIDATION - Validate required arguments
log "Validating input arguments..."

if [[ -z "$WORKER_ID" ]]; then
    log "ERROR: WORKER_ID (argument 1) is required but was empty"
    log "Usage: $0 <worker_id> <task_id> [worker_type]"
    exit 1
fi

if [[ -z "$TASK_ID" ]]; then
    log "ERROR: TASK_ID (argument 2) is required but was empty"
    log "Usage: $0 <worker_id> <task_id> [worker_type]"
    exit 1
fi

log "✅ Input validation passed: WORKER_ID=$WORKER_ID, TASK_ID=$TASK_ID, WORKER_TYPE=$WORKER_TYPE"

# Step 1: Ensure critical services are running
log "Checking service health..."

CRITICAL_SERVICES=(
    "worker-daemon:worker-daemon.sh"
    "health-monitor:health-monitor-daemon.sh"
    "metrics-snapshot:metrics-snapshot-daemon.sh"
    "orchestrator:task-orchestrator-daemon.sh"
)

for service_pair in "${CRITICAL_SERVICES[@]}"; do
    IFS=':' read -r service script <<< "$service_pair"

    if ! pgrep -f "$script" > /dev/null 2>&1; then
        log "WARNING: $service not running, attempting to start..."
        nohup "$SCRIPT_DIR/$script" > /dev/null 2>&1 &
        sleep 2

        if pgrep -f "$script" > /dev/null 2>&1; then
            log "✅ Successfully started $service"
        else
            log "⚠️ Could not start $service (may not be critical)"
        fi
    else
        log "✅ $service is running"
    fi
done

# Step 2: Check dashboard health
if curl -s http://localhost:5001/api/health > /dev/null 2>&1; then
    log "✅ Dashboard server is responsive"
else
    log "⚠️ Dashboard not responding, starting..."
    cd "$PROJECT_ROOT/dashboard"
    nohup npm start > /tmp/dashboard.log 2>&1 &
    sleep 3
fi

# Step 3: Update system health status
cat > "$PROJECT_ROOT/coordination/system-health-check.json" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "worker_id": "$WORKER_ID",
    "task_id": "$TASK_ID",
    "services_checked": true,
    "launcher_version": "v2.1-fixed"
}
EOF

# Step 4: Read task requirements
log "Loading task requirements..."

TASK_FILE="$PROJECT_ROOT/coordination/tasks/$TASK_ID.json"
WORKER_SPEC_FILE="$PROJECT_ROOT/coordination/worker-specs/active/$WORKER_ID.json"
REQUIREMENTS_FILE="$PROJECT_ROOT/agents/workers/$WORKER_ID/requirements.txt"

if [[ -f "$TASK_FILE" ]]; then
    TASK_TITLE=$(jq -r '.title // "Unknown task"' "$TASK_FILE")
    TASK_CONTEXT=$(jq -r '.context // {}' "$TASK_FILE" | jq -c .)
    log "Task file found: $TASK_TITLE"
elif [[ -f "$WORKER_SPEC_FILE" ]]; then
    # FIX #6: Fall back to reading task data from worker spec when task file doesn't exist
    TASK_TITLE=$(jq -r '.task_data.title // "Unknown task"' "$WORKER_SPEC_FILE")
    TASK_DESCRIPTION=$(jq -r '.task_data.description // ""' "$WORKER_SPEC_FILE")
    TASK_CONTEXT=$(jq -r '.task_data // {}' "$WORKER_SPEC_FILE" | jq -c .)
    log "Task data loaded from worker spec: $TASK_TITLE"
else
    TASK_TITLE="Task $TASK_ID"
    TASK_DESCRIPTION=""
    TASK_CONTEXT='{"note":"Task file not found, using minimal context"}'
    log "WARNING: Task file not found at $TASK_FILE and worker spec not found at $WORKER_SPEC_FILE"
fi

log "Task context loaded: $(echo "$TASK_CONTEXT" | jq -c '{title: .title, type: .type, priority: .priority}' 2>/dev/null || echo "$TASK_CONTEXT")"

# Step 5: Create worker directory
WORKER_DIR="$PROJECT_ROOT/agents/workers/$WORKER_ID"
mkdir -p "$WORKER_DIR"
cd "$WORKER_DIR"

# Step 6: Generate enhanced prompt with service awareness
log "Generating enhanced worker prompt..."

cat > "$WORKER_DIR/prompt.md" << 'EOF'
# Worker Task Execution

You are an AI worker (ID: WORKER_ID_PLACEHOLDER) executing task TASK_ID_PLACEHOLDER.

## Service Management Awareness

Before executing tasks, you should be aware that the following services are available:
- Dashboard API: http://localhost:5001/api/ (health, metrics, events, tasks, etc.)
- Worker coordination files in: /Users/ryandahlberg/Projects/commit-relay/coordination/
- System health status in: /Users/ryandahlberg/Projects/commit-relay/coordination/system-health.json

If you encounter service issues during execution:
1. Check service health: curl http://localhost:5001/api/health
2. Report issues to: /Users/ryandahlberg/Projects/commit-relay/coordination/health-alerts.json
3. You can attempt to restart services using: /Users/ryandahlberg/Projects/commit-relay/scripts/ensure-services.sh

## Task Information

**Task**: TASK_TITLE_PLACEHOLDER
**Type**: WORKER_TYPE_PLACEHOLDER

## Task Context

TASK_CONTEXT_PLACEHOLDER

## Execution Guidelines

1. **Service Checks**: Verify required services are running before starting work
2. **Progress Tracking**: Update task status in coordination/task-queue.json
3. **Error Handling**: Report any service failures or blockers
4. **Logging**: Write detailed logs to your worker directory
5. **Completion**: Update final status and create completion report

## Heartbeat & Progress Reporting (CRITICAL)

You MUST send periodic heartbeats to prevent being marked as a zombie worker:

1. **At task start**: Report that you've begun work
2. **Every 2-3 minutes**: Send a progress update showing what you're working on
3. **At major milestones**: Report completion of significant steps
4. **At task end**: Report final completion

### How to Send Heartbeats

Use one of these methods to report progress:

**Option 1 - Write to heartbeat file (Preferred):**
```bash
echo '{"timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "status": "working", "progress": "Analyzing codebase structure", "worker_id": "WORKER_ID_PLACEHOLDER"}' > /Users/ryandahlberg/Projects/commit-relay/agents/workers/WORKER_ID_PLACEHOLDER/heartbeat.json
```

**Option 2 - Use dashboard API:**
```bash
curl -s -X POST http://localhost:5001/api/workers/WORKER_ID_PLACEHOLDER/heartbeat \
  -H "Content-Type: application/json" \
  -d '{"status": "working", "progress": "Current activity description"}'
```

### Progress Messages Should Include:
- What step you're currently on (e.g., "Step 2/5: Implementing feature")
- Brief description of current activity
- Percentage complete if applicable

**IMPORTANT**: Workers that don't send heartbeats for 15+ minutes will be automatically killed as zombies!

## Available Tools and Resources

- Full access to the commit-relay repository
- Ability to read/write files and execute commands
- Dashboard API endpoints for monitoring and metrics
- Service management scripts in /scripts/

## Your Mission

Execute the assigned task while:
- Ensuring all required services remain operational
- Providing clear progress updates
- Handling errors gracefully
- Delivering high-quality results

Begin by analyzing the task requirements and checking service health.
EOF

# FIX #1: PROPER PLACEHOLDER SUBSTITUTION using sed for ALL placeholders
log "Performing template placeholder substitution..."

# FIX #7: Escape special characters in TASK_TITLE for sed (e.g., & in titles)
TASK_TITLE_ESCAPED=$(echo "$TASK_TITLE" | sed 's/[\/&]/\\&/g')

# Substitute basic placeholders
sed -i '' "s/WORKER_ID_PLACEHOLDER/$WORKER_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_ID_PLACEHOLDER/$TASK_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_TITLE_PLACEHOLDER/$TASK_TITLE_ESCAPED/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/WORKER_TYPE_PLACEHOLDER/$WORKER_TYPE/g" "$WORKER_DIR/prompt.md"

# FIX #4: Escape special characters in TASK_CONTEXT for sed
# Handle JSON special characters: / & \ $ " '
TASK_CONTEXT_ESCAPED=$(echo "$TASK_CONTEXT" | sed 's/[\/&]/\\&/g')

# Use | as delimiter to avoid conflicts with / in JSON
sed -i '' "s|TASK_CONTEXT_PLACEHOLDER|$TASK_CONTEXT_ESCAPED|g" "$WORKER_DIR/prompt.md"

log "✅ Template substitution completed"

# FIX #3: POST-GENERATION VALIDATION - Check for unsubstituted placeholders
log "Validating placeholder substitution..."

UNSUBSTITUTED=$(grep -c "PLACEHOLDER" "$WORKER_DIR/prompt.md" || true)

if [[ $UNSUBSTITUTED -gt 0 ]]; then
    log "ERROR: Found $UNSUBSTITUTED unsubstituted placeholders in prompt.md"
    log "Prompt generation failed validation - details below:"

    # Log the problematic content
    grep "PLACEHOLDER" "$WORKER_DIR/prompt.md" | while read -r line; do
        log "  Unsubstituted: $line"
    done
    grep "PLACEHOLDER" "$WORKER_DIR/prompt.md" >> "$PROJECT_ROOT/agents/logs/system/launcher.log"

    # Create failure status
    echo "{\"status\": \"failed\", \"error\": \"placeholder_substitution_failed\", \"unsubstituted_count\": $UNSUBSTITUTED, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKER_DIR/status.json"

    log "Worker launch aborted due to validation failure"
    exit 1
fi

log "✅ All placeholders substituted successfully (validation passed)"

# Step 7: Pre-flight validation
log "Running pre-flight checks..."

# Check if claude command exists
if ! command -v claude &> /dev/null; then
    log "ERROR: claude command not found"
    echo "{\"status\": \"failed\", \"error\": \"claude_not_found\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKER_DIR/status.json"

    # Update task status
    jq --arg tid "$TASK_ID" \
        '(.tasks[] | select(.id == $tid)).status = "failed"' \
        "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue.tmp && \
        mv /tmp/task-queue.tmp "$PROJECT_ROOT/coordination/task-queue.json"

    log "Worker failed: claude command not available"
    exit 1
fi

log "✅ Pre-flight checks passed"

# Step 8: Execute worker with Claude Code via Terminal.app
log "Launching Claude Code for worker execution..."

# Create log directories
mkdir -p "$WORKER_DIR/logs"

# Create execution script that will run in Terminal.app
cat > "$WORKER_DIR/execute.sh" << 'EXEC_EOF'
#!/bin/bash
WORKER_DIR="$(dirname "$0")"
cd "$WORKER_DIR"

# Add NVM paths to ensure claude CLI is available in Terminal.app subprocess
export PATH="/Users/ryandahlberg/.nvm/versions/node/v24.11.0/bin:$PATH"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker execution starting..." | tee -a logs/stdout.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Working directory: $WORKER_DIR" | tee -a logs/stdout.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Prompt file: prompt.md" | tee -a logs/stdout.log

# Execute Claude Code with prompt file in non-interactive mode
# Use -p flag for headless/non-interactive execution
# Use --dangerously-skip-permissions for automated execution in controlled environment
# Redirect output to logs without using exec/process substitution to avoid TTY issues
cat prompt.md | claude -p --dangerously-skip-permissions >> logs/stdout.log 2>> logs/stderr.log

# Capture exit status
EXIT_CODE=$?

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Claude Code exited with code: $EXIT_CODE"

# Check for Ink TTY errors in stderr
if grep -q "Raw mode is not supported" logs/stderr.log 2>/dev/null; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: Ink TTY error detected"
    echo "{\"status\": \"failed\", \"error\": \"ink_tty_error\", \"exit_code\": $EXIT_CODE, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > status.json
    exit 1
fi

# Update completion status
if [ $EXIT_CODE -eq 0 ]; then
    echo "{\"status\": \"completed\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > status.json
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker completed successfully"
else
    echo "{\"status\": \"failed\", \"exit_code\": $EXIT_CODE, \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > status.json
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker failed with exit code: $EXIT_CODE"
fi

exit $EXIT_CODE
EXEC_EOF

chmod +x "$WORKER_DIR/execute.sh"

# Launch worker in TRUE HEADLESS mode (no Terminal.app)
log "Launching worker in HEADLESS mode (background process)..."

# Run execute.sh directly in background, redirecting to logs
nohup "$WORKER_DIR/execute.sh" >> "$WORKER_DIR/logs/launcher-output.log" 2>&1 &
WORKER_PID=$!

if [ $? -eq 0 ]; then
    log "✅ Worker launched successfully in headless mode (PID: $WORKER_PID)"
    log "Worker directory: $WORKER_DIR"
    log "Logs available at: $WORKER_DIR/logs/"

    # Save PID for tracking
    echo "$WORKER_PID" > "$WORKER_DIR/worker.pid"

    # Start heartbeat emitter in background
    HEARTBEAT_EMITTER="$SCRIPT_DIR/lib/worker-heartbeat-emitter.sh"
    if [ -f "$HEARTBEAT_EMITTER" ]; then
        log "Starting heartbeat emitter for worker..."
        nohup "$HEARTBEAT_EMITTER" "$WORKER_ID" "$WORKER_PID" >> "$WORKER_DIR/logs/heartbeat-emitter.log" 2>&1 &
        HEARTBEAT_PID=$!
        echo "$HEARTBEAT_PID" > "$WORKER_DIR/heartbeat.pid"
        log "✅ Heartbeat emitter started (PID: $HEARTBEAT_PID)"
    else
        log "⚠️ Heartbeat emitter not found, skipping heartbeat setup"
    fi
else
    log "ERROR: Failed to launch worker in headless mode"
    echo "{\"status\": \"failed\", \"error\": \"headless_launch_failed\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKER_DIR/status.json"

    # Update task status
    jq --arg tid "$TASK_ID" \
        '(.tasks[] | select(.id == $tid)).status = "failed"' \
        "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue.tmp && \
        mv /tmp/task-queue.tmp "$PROJECT_ROOT/coordination/task-queue.json"

    log "Worker failed: could not launch in headless mode"
    exit 1
fi

# Wait a moment for worker to initialize
sleep 2

# Verify worker started by checking if PID exists
if ps -p "$WORKER_PID" > /dev/null 2>&1; then
    log "✅ Worker process confirmed running (PID: $WORKER_PID)"
else
    log "⚠️ Worker process not running (may have already completed or failed)"
    # Check if it completed successfully
    if [[ -f "$WORKER_DIR/status.json" ]]; then
        STATUS=$(jq -r '.status' "$WORKER_DIR/status.json")
        log "Worker already finished with status: $STATUS"
    fi
fi

# Step 8: Update task status
log "Updating task completion status..."

if [[ -f "$WORKER_DIR/status.json" ]]; then
    STATUS=$(jq -r '.status' "$WORKER_DIR/status.json")
    log "Worker completed with status: $STATUS"

    # Update task queue
    jq --arg tid "$TASK_ID" --arg status "$STATUS" \
        '(.tasks[] | select(.id == $tid)).status = $status' \
        "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue.tmp && \
        mv /tmp/task-queue.tmp "$PROJECT_ROOT/coordination/task-queue.json"
else
    log "No status file found, worker may still be running"
fi

log "Worker launcher completed for $WORKER_ID"
log "============================================"
