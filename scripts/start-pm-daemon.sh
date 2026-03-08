#!/bin/bash
# scripts/start-pm-daemon.sh
# Wrapper script to start PM daemon with proper process priority
# Ensures daemon runs with normal priority (not low/nice)

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PID_FILE="/tmp/pm-daemon.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/pm-daemon.log"

# Check if already running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "PM daemon already running with PID $OLD_PID"
        echo "Use 'kill $OLD_PID' to stop it first"
        exit 1
    else
        echo "Removing stale PID file"
        rm -f "$PID_FILE"
    fi
fi

echo "Starting PM daemon..."
echo "Working directory: $COMMIT_RELAY_HOME"
echo "Log file: $LOG_FILE"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Start daemon with normal priority (renice to 0)
# Use nohup to detach from terminal
cd "$COMMIT_RELAY_HOME"
nohup nice -n 0 bash "$SCRIPT_DIR/pm-daemon.sh" > /dev/null 2>&1 &
DAEMON_PID=$!

# Wait a moment for startup
sleep 2

# Verify it started
if ps -p "$DAEMON_PID" > /dev/null 2>&1; then
    echo "PM daemon started successfully (PID: $DAEMON_PID)"
    echo "View logs: tail -f $LOG_FILE"
    echo "Stop daemon: kill $DAEMON_PID"
    exit 0
else
    echo "ERROR: PM daemon failed to start"
    echo "Check logs at: $LOG_FILE"
    exit 1
fi
