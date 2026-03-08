#!/bin/bash
# scripts/start-commit-relay.sh
# Main startup script for Commit-Relay system
# Automatically detects and launches pending workers

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"

cd "$COMMIT_RELAY_HOME"

log_section "Commit-Relay Startup"
log_info "Working Directory: $COMMIT_RELAY_HOME"
log_info "Date: $(date)"
log_info ""

# Pull latest coordination state
log_info "Pulling latest coordination state from GitHub..."
if git pull origin main --quiet 2>/dev/null; then
    log_success "Coordination state updated"
else
    log_warn "Could not pull latest state (may already be current)"
fi

log_info ""

# Note: Dashboard agent monitoring has been integrated into dashboard server
# The dashboard-agent-monitor.sh script is deprecated

# Launch Dashboard Server
log_section "Starting Dashboard Server"
DASHBOARD_PORT="${DASHBOARD_PORT:-5001}"
if lsof -i :$DASHBOARD_PORT > /dev/null 2>&1; then
    log_info "Dashboard server already running on port $DASHBOARD_PORT"
else
    log_info "Launching dashboard server on port $DASHBOARD_PORT..."
    mkdir -p "$COMMIT_RELAY_HOME/agents/logs/system"
    cd "$COMMIT_RELAY_HOME/dashboard"
    nohup node server/index.js > "$COMMIT_RELAY_HOME/agents/logs/system/dashboard-server.log" 2>&1 &
    DASHBOARD_SERVER_PID=$!
    cd "$COMMIT_RELAY_HOME"
    sleep 2
    if lsof -i :$DASHBOARD_PORT > /dev/null 2>&1; then
        log_success "Dashboard server started (PID: $DASHBOARD_SERVER_PID)"
        log_info "Dashboard UI: http://localhost:$DASHBOARD_PORT/"
    else
        log_warn "Dashboard server may have failed to start. Check logs at agents/logs/system/dashboard-server.log"
    fi
fi
log_info ""

# Start Core Daemons
log_section "Starting Core Daemons"

# Create logs directory if it doesn't exist
DAEMON_LOGS_DIR="$COMMIT_RELAY_HOME/logs/daemons"
mkdir -p "$DAEMON_LOGS_DIR"

# Define daemons to start
DAEMONS=(
    "pm-daemon:Process Manager"
    "health-monitor-daemon:Health Monitor"
    "metrics-snapshot-daemon:Metrics Snapshot"
    "coordinator-daemon:Coordinator"
    "integration-validator-daemon:Integration Validator"
    "worker-daemon:Worker Manager"
    "daemon-supervisor:Daemon Supervisor"
)

# Start each daemon
for daemon_entry in "${DAEMONS[@]}"; do
    IFS=: read -r daemon_script daemon_name <<< "$daemon_entry"

    # Check if daemon is already running
    if pgrep -f "${daemon_script}.sh" > /dev/null 2>&1; then
        log_info "$daemon_name already running"
    else
        log_info "Starting $daemon_name..."
        nohup "$SCRIPT_DIR/${daemon_script}.sh" > "$DAEMON_LOGS_DIR/${daemon_script}.log" 2>&1 &
        DAEMON_PID=$!
        sleep 1

        # Verify daemon started
        if ps -p $DAEMON_PID > /dev/null 2>&1; then
            log_success "$daemon_name started (PID: $DAEMON_PID)"
        else
            log_warn "$daemon_name may have failed to start. Check logs at logs/daemons/${daemon_script}.log"
        fi
    fi
done

log_info ""

# Verify agents are installed
log_section "Verifying Claude Code Agents"
AGENTS_DIR="$COMMIT_RELAY_HOME/.claude/agents"
REQUIRED_AGENTS=("coordinator-master" "security-master" "development-master" "inventory-master" "cicd-master")
MISSING_AGENTS=()

if [ -d "$AGENTS_DIR" ]; then
    AGENT_COUNT=$(find "$AGENTS_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
    log_success "Found $AGENT_COUNT agents in .claude/agents/"

    # Check for required master agents
    for agent_name in "${REQUIRED_AGENTS[@]}"; do
        if [ -f "$AGENTS_DIR/${agent_name}.md" ]; then
            log_info "  ✓ $agent_name"
        else
            log_warn "  ✗ $agent_name (MISSING)"
            MISSING_AGENTS+=("$agent_name")
        fi
    done

    # Check for any additional agents
    for agent_file in "$AGENTS_DIR"/*.md; do
        if [ -f "$agent_file" ]; then
            agent_name=$(basename "$agent_file" .md)
            # Skip if already checked in required agents
            if [[ ! " ${REQUIRED_AGENTS[@]} " =~ " ${agent_name} " ]]; then
                log_info "  ✓ $agent_name"
            fi
        fi
    done

    # Warn if missing required agents
    if [ ${#MISSING_AGENTS[@]} -gt 0 ]; then
        log_warn "Missing ${#MISSING_AGENTS[@]} required master agent(s)"
        log_info "Run: ./scripts/install-agents.sh to install missing agents"
    fi
else
    log_warn "No agents directory found at .claude/agents/"
    log_info "Run: ./scripts/install-agents.sh to install agents"
fi
log_info ""

# Check for pending workers
log_section "Checking for Pending Workers"

ACTIVE_SPECS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/active"
PENDING_WORKERS=()

if [ -d "$ACTIVE_SPECS_DIR" ]; then
    # Find all pending workers
    for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
        if [ -f "$spec_file" ]; then
            WORKER_STATUS=$(jq -r '.status' "$spec_file")
            WORKER_ID=$(jq -r '.worker_id' "$spec_file")

            if [ "$WORKER_STATUS" = "pending" ]; then
                PENDING_WORKERS+=("$WORKER_ID")
            fi
        fi
    done
fi

PENDING_COUNT=${#PENDING_WORKERS[@]}

if [ "$PENDING_COUNT" -eq 0 ]; then
    log_info "No pending workers found"
    log_info ""
    log_section "System Status"
    log_info "Commit-Relay is ready"
    log_info "Dashboard agent is monitoring coordination state"
    log_info "Dashboard UI: http://localhost:${DASHBOARD_PORT:-5001}/"
    log_info ""
    log_info "To create tasks, use: scripts/create-task.sh"
    log_info "To run master agents, use: scripts/run-*-master.sh"
    exit 0
fi

log_info "Found $PENDING_COUNT pending worker(s):"
log_info ""

# Display pending workers with details
for i in "${!PENDING_WORKERS[@]}"; do
    WORKER_ID="${PENDING_WORKERS[$i]}"
    SPEC_PATH="$ACTIVE_SPECS_DIR/${WORKER_ID}.json"

    WORKER_TYPE=$(jq -r '.worker_type' "$SPEC_PATH")
    TASK_ID=$(jq -r '.task_id' "$SPEC_PATH")
    CREATED_BY=$(jq -r '.created_by' "$SPEC_PATH")
    TOKEN_BUDGET=$(jq -r '.resources.token_budget' "$SPEC_PATH")

    log_info "  [$((i+1))] $WORKER_ID"
    log_info "      Type: $WORKER_TYPE"
    log_info "      Task: $TASK_ID"
    log_info "      Master: $CREATED_BY"
    log_info "      Budget: ${TOKEN_BUDGET} tokens"
    log_info ""
done

# Auto-start mode or interactive mode
AUTO_START="${AUTO_START:-false}"

if [ "$AUTO_START" = "true" ]; then
    # Auto-start first pending worker
    FIRST_WORKER="${PENDING_WORKERS[0]}"
    log_section "Auto-Starting Worker: $FIRST_WORKER"
    exec "$SCRIPT_DIR/start-worker.sh" "$FIRST_WORKER"
else
    # Interactive mode - prompt user
    log_section "Worker Startup Options"
    log_info "To start a worker, run:"
    log_info "  ./scripts/start-worker.sh <worker-id>"
    log_info ""
    log_info "Examples:"
    for WORKER_ID in "${PENDING_WORKERS[@]}"; do
        log_info "  ./scripts/start-worker.sh $WORKER_ID"
    done
    log_info ""
    log_info "To auto-start the first pending worker:"
    log_info "  AUTO_START=true ./scripts/start-commit-relay.sh"
fi

log_info ""
log_section "Commit-Relay Ready"
