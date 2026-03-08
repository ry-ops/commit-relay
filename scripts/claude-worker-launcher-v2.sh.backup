#!/bin/bash

# Claude Worker Launcher v2 - With Service Management
# Enhanced launcher that ensures all services are running before worker execution

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

log "============================================"
log "Starting enhanced worker launcher for $WORKER_ID"
log "Task: $TASK_ID, Type: $WORKER_TYPE"

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
if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
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
    "launcher_version": "v2"
}
EOF

# Step 4: Read task requirements
log "Loading task requirements..."

TASK_FILE="$PROJECT_ROOT/coordination/tasks/task-$TASK_ID.json"
REQUIREMENTS_FILE="$PROJECT_ROOT/agents/workers/$WORKER_ID/requirements.txt"

if [[ -f "$TASK_FILE" ]]; then
    TASK_TITLE=$(jq -r '.title // "Unknown task"' "$TASK_FILE")
    TASK_CONTEXT=$(jq -r '.context // {}' "$TASK_FILE")
    log "Task: $TASK_TITLE"
else
    TASK_TITLE="Task $TASK_ID"
    TASK_CONTEXT="{}"
    log "Task file not found, using defaults"
fi

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
- Dashboard API: http://localhost:3000/api/ (health, metrics, events, tasks, etc.)
- Worker coordination files in: /Users/ryandahlberg/Projects/commit-relay/coordination/
- System health status in: /Users/ryandahlberg/Projects/commit-relay/coordination/system-health.json

If you encounter service issues during execution:
1. Check service health: curl http://localhost:3000/api/health
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

# Replace placeholders
sed -i '' "s/WORKER_ID_PLACEHOLDER/$WORKER_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_ID_PLACEHOLDER/$TASK_ID/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/TASK_TITLE_PLACEHOLDER/$TASK_TITLE/g" "$WORKER_DIR/prompt.md"
sed -i '' "s/WORKER_TYPE_PLACEHOLDER/$WORKER_TYPE/g" "$WORKER_DIR/prompt.md"
echo "$TASK_CONTEXT" >> "$WORKER_DIR/prompt.md"

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

# Redirect all output to log files
exec > >(tee logs/stdout.log) 2> >(tee logs/stderr.log >&2)

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Worker execution starting..."
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Working directory: $WORKER_DIR"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Prompt file: prompt.md"

# Execute Claude Code with prompt file
# Pass prompt content as positional argument
claude "$(cat prompt.md)"

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

# Launch worker in Terminal.app with real TTY
log "Launching worker in Terminal.app with TTY support..."
osascript -e "tell application \"Terminal\" to do script \"cd '$WORKER_DIR' && ./execute.sh; exit\"" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    log "✅ Worker launched successfully in Terminal.app"
    log "Worker directory: $WORKER_DIR"
    log "Logs available at: $WORKER_DIR/logs/"
else
    log "ERROR: Failed to launch Terminal.app"
    echo "{\"status\": \"failed\", \"error\": \"terminal_launch_failed\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$WORKER_DIR/status.json"

    # Update task status
    jq --arg tid "$TASK_ID" \
        '(.tasks[] | select(.id == $tid)).status = "failed"' \
        "$PROJECT_ROOT/coordination/task-queue.json" > /tmp/task-queue.tmp && \
        mv /tmp/task-queue.tmp "$PROJECT_ROOT/coordination/task-queue.json"

    log "Worker failed: could not launch Terminal.app"
    exit 1
fi

# Wait a moment for worker to initialize
sleep 2

# Verify worker started by checking for execute.sh process
if pgrep -f "$WORKER_DIR/execute.sh" > /dev/null 2>&1; then
    log "✅ Worker process confirmed running"
else
    log "⚠️ Worker process not detected (may have already completed or failed)"
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