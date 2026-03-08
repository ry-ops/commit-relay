#!/bin/bash
# scripts/daemons/ingestion-daemon.sh
# RAG ingestion daemon for scheduled connector runs
# Part of commit-relay automation system

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PID_FILE="$PROJECT_ROOT/coordination/pids/ingestion-daemon.pid"
LOG_FILE="$PROJECT_ROOT/coordination/logs/ingestion-daemon.log"
CONFIG_FILE="$PROJECT_ROOT/coordination/config/connectors.json"
SCHEDULER="$PROJECT_ROOT/lib/rag/connectors/ingestion-scheduler.js"

# Ensure directories exist
mkdir -p "$(dirname "$PID_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"daemon\":\"ingestion\",\"message\":\"$message\"}" >> "$LOG_FILE"
    echo "[$timestamp] [$level] $message"
}

# Check if daemon is running
is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Start the daemon
start() {
    if is_running; then
        log "WARN" "Daemon is already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi

    log "INFO" "Starting ingestion daemon..."

    # Check dependencies
    if ! command -v node &> /dev/null; then
        log "ERROR" "Node.js is not installed"
        exit 1
    fi

    if [[ ! -f "$SCHEDULER" ]]; then
        log "ERROR" "Scheduler not found: $SCHEDULER"
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    # Start daemon in background
    nohup "$0" run >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    log "INFO" "Daemon started with PID: $pid"
    echo "Ingestion daemon started (PID: $pid)"
}

# Stop the daemon
stop() {
    if ! is_running; then
        log "WARN" "Daemon is not running"
        exit 0
    fi

    local pid=$(cat "$PID_FILE")
    log "INFO" "Stopping daemon (PID: $pid)..."

    kill "$pid" 2>/dev/null || true

    # Wait for process to stop
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
        sleep 1
        ((count++))
    done

    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        log "WARN" "Force killing daemon..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    log "INFO" "Daemon stopped"
    echo "Ingestion daemon stopped"
}

# Restart the daemon
restart() {
    stop
    sleep 2
    start
}

# Show daemon status
status() {
    if is_running; then
        local pid=$(cat "$PID_FILE")
        echo "Ingestion daemon is running (PID: $pid)"

        # Show connector status
        if [[ -f "$PROJECT_ROOT/coordination/memory/ingestion-state.json" ]]; then
            echo ""
            echo "Connector status:"
            node -e "
                const state = require('$PROJECT_ROOT/coordination/memory/ingestion-state.json');
                console.log('  Last update:', state.lastUpdate);
                console.log('  Connectors:', state.connectors?.length || 0);
                console.log('  Queue:', state.queue?.length || 0);
            " 2>/dev/null || echo "  Unable to read state"
        fi
    else
        echo "Ingestion daemon is not running"
        exit 1
    fi
}

# Run the daemon loop
run() {
    log "INFO" "Ingestion daemon starting main loop"

    # Initialize scheduler
    cd "$PROJECT_ROOT"
    node "$SCHEDULER" init

    # Main daemon loop
    while true; do
        # Load config to get global interval
        local interval=$(node -e "
            const config = require('$CONFIG_FILE');
            console.log(config.global?.checkInterval || 60);
        " 2>/dev/null || echo "60")

        # Check for pending jobs and run
        node "$SCHEDULER" run 2>&1 | while IFS= read -r line; do
            log "INFO" "$line"
        done

        # Health check
        if (( RANDOM % 10 == 0 )); then
            log "INFO" "Running health check..."
            node "$SCHEDULER" health 2>&1 | while IFS= read -r line; do
                log "INFO" "Health: $line"
            done
        fi

        # Sleep until next check
        sleep "$interval"
    done
}

# Run a specific connector
run_connector() {
    local connector="$1"

    if [[ -z "$connector" ]]; then
        echo "Usage: $0 run-connector <connector-name>"
        exit 1
    fi

    log "INFO" "Running connector: $connector"
    cd "$PROJECT_ROOT"
    node "$SCHEDULER" run "$connector"
}

# Show connector health
health() {
    cd "$PROJECT_ROOT"
    node "$SCHEDULER" health
}

# Show recent logs
logs() {
    local lines="${1:-50}"

    if [[ -f "$LOG_FILE" ]]; then
        tail -n "$lines" "$LOG_FILE"
    else
        echo "No logs found"
    fi
}

# Clean up old logs
cleanup() {
    log "INFO" "Cleaning up old logs..."

    # Rotate log file if too large (>10MB)
    if [[ -f "$LOG_FILE" ]]; then
        local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        if [[ $size -gt 10485760 ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
            log "INFO" "Rotated log file"
        fi
    fi

    # Clean up old rotated logs (keep last 5)
    ls -t "${LOG_FILE}."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

    echo "Cleanup complete"
}

# Show help
show_help() {
    cat << EOF
Ingestion Daemon - RAG connector scheduler

Usage: $0 <command> [options]

Commands:
  start           Start the daemon
  stop            Stop the daemon
  restart         Restart the daemon
  status          Show daemon status
  run             Run daemon loop (internal use)
  run-connector   Run a specific connector
  health          Check connector health
  logs [n]        Show last n log lines (default: 50)
  cleanup         Clean up old logs
  help            Show this help

Examples:
  $0 start                    # Start the daemon
  $0 status                   # Check if running
  $0 run-connector github-commit-relay  # Run specific connector
  $0 logs 100                 # Show last 100 log lines

Environment Variables:
  GITHUB_TOKEN              GitHub API token
  CONFLUENCE_BASE_URL       Confluence instance URL
  CONFLUENCE_USERNAME       Confluence username
  CONFLUENCE_API_TOKEN      Confluence API token
  SLACK_BOT_TOKEN          Slack bot token

Configuration:
  Config file: $CONFIG_FILE
  PID file:    $PID_FILE
  Log file:    $LOG_FILE

EOF
}

# Main command handler
case "${1:-help}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    run)
        run
        ;;
    run-connector)
        run_connector "$2"
        ;;
    health)
        health
        ;;
    logs)
        logs "$2"
        ;;
    cleanup)
        cleanup
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run '$0 help' for usage"
        exit 1
        ;;
esac
