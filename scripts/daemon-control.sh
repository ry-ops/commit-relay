#!/bin/bash
# scripts/daemon-control.sh
# Control script for commit-relay worker daemon
# Usage: daemon-control.sh {start|stop|restart|status|install|uninstall}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DAEMON_SCRIPT="$SCRIPT_DIR/worker-daemon.sh"
PID_FILE="/tmp/commit-relay-worker-daemon.pid"
LOG_FILE="$COMMIT_RELAY_HOME/agents/logs/system/worker-daemon.log"
PLIST_FILE="$HOME/Library/LaunchAgents/com.ryops.commit-relay.worker-daemon.plist"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[commit-relay]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[commit-relay]${NC} ✅ $1"
}

print_error() {
    echo -e "${RED}[commit-relay]${NC} ❌ $1"
}

print_warning() {
    echo -e "${YELLOW}[commit-relay]${NC} ⚠️  $1"
}

# Check if daemon is running
is_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Check if launchd service is installed
is_installed() {
    [ -f "$PLIST_FILE" ]
}

# Start daemon
start_daemon() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        print_warning "Daemon already running (PID $PID)"
        return 0
    fi

    print_status "Starting worker daemon..."

    # Start daemon in background
    nohup "$DAEMON_SCRIPT" > /dev/null 2>&1 &

    # Wait a moment and check if it started
    sleep 2

    if is_running; then
        PID=$(cat "$PID_FILE")
        print_success "Daemon started (PID $PID)"
        print_status "Logs: $LOG_FILE"
        return 0
    else
        print_error "Failed to start daemon"
        print_status "Check logs: $LOG_FILE"
        return 1
    fi
}

# Stop daemon
stop_daemon() {
    if ! is_running; then
        print_warning "Daemon is not running"
        return 0
    fi

    PID=$(cat "$PID_FILE")
    print_status "Stopping worker daemon (PID $PID)..."

    kill "$PID" 2>/dev/null || true

    # Wait for process to stop
    for i in {1..10}; do
        if ! is_running; then
            rm -f "$PID_FILE"
            print_success "Daemon stopped"
            return 0
        fi
        sleep 1
    done

    # Force kill if still running
    if is_running; then
        print_warning "Force killing daemon..."
        kill -9 "$PID" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi

    print_success "Daemon stopped"
}

# Show daemon status
show_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Commit-Relay Worker Daemon Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if is_running; then
        PID=$(cat "$PID_FILE")
        echo -e "  ${GREEN}Status:${NC}       ✅ Running"
        echo -e "  ${BLUE}PID:${NC}          $PID"

        # Get process info
        UPTIME=$(ps -p "$PID" -o etime= | xargs)
        MEM=$(ps -p "$PID" -o rss= | xargs)
        MEM_MB=$((MEM / 1024))

        echo -e "  ${BLUE}Uptime:${NC}       $UPTIME"
        echo -e "  ${BLUE}Memory:${NC}       ${MEM_MB} MB"
    else
        echo -e "  ${RED}Status:${NC}       ❌ Not running"
    fi

    echo ""
    echo -e "  ${BLUE}Log File:${NC}     $LOG_FILE"
    echo -e "  ${BLUE}PID File:${NC}     $PID_FILE"
    echo ""

    if is_installed; then
        echo -e "  ${BLUE}LaunchAgent:${NC}  ✅ Installed"
        echo -e "  ${BLUE}Plist File:${NC}   $PLIST_FILE"

        # Check if launchd service is loaded
        if launchctl list | grep -q "com.ryops.commit-relay.worker-daemon"; then
            echo -e "  ${BLUE}LaunchD:${NC}      ✅ Loaded"
        else
            echo -e "  ${BLUE}LaunchD:${NC}      ⚠️  Not loaded"
        fi
    else
        echo -e "  ${BLUE}LaunchAgent:${NC}  ❌ Not installed"
    fi

    echo ""

    # Show recent log entries
    if [ -f "$LOG_FILE" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Recent Log Entries (last 10 lines)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        tail -n 10 "$LOG_FILE" | sed 's/^/  /'
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Install launchd service
install_service() {
    print_status "Installing worker daemon as macOS LaunchAgent..."

    # Create LaunchAgents directory if it doesn't exist
    mkdir -p "$HOME/Library/LaunchAgents"

    # Create plist file
    cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ryops.commit-relay.worker-daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_SCRIPT</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>

    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>

    <key>WorkingDirectory</key>
    <string>$COMMIT_RELAY_HOME</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>COMMIT_RELAY_HOME</key>
        <string>$COMMIT_RELAY_HOME</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin</string>
    </dict>

    <key>ThrottleInterval</key>
    <integer>30</integer>
</dict>
</plist>
EOF

    print_success "LaunchAgent plist created: $PLIST_FILE"

    # Load the service
    launchctl load "$PLIST_FILE" 2>/dev/null || print_warning "Failed to load service (may already be loaded)"

    print_success "Worker daemon installed successfully!"
    print_status ""
    print_status "The daemon will now:"
    print_status "  • Start automatically on login"
    print_status "  • Monitor for pending workers every 30 seconds"
    print_status "  • Launch workers automatically in new Terminal tabs"
    print_status "  • Restart automatically if it crashes"
    print_status ""
    print_status "To check status: $0 status"
    print_status "To view logs: tail -f $LOG_FILE"
}

# Uninstall launchd service
uninstall_service() {
    print_status "Uninstalling worker daemon LaunchAgent..."

    # Stop daemon first
    stop_daemon

    # Unload service
    if is_installed; then
        launchctl unload "$PLIST_FILE" 2>/dev/null || print_warning "Service not loaded"
        rm -f "$PLIST_FILE"
        print_success "LaunchAgent removed"
    else
        print_warning "LaunchAgent not installed"
    fi

    print_success "Worker daemon uninstalled"
}

# Main command handler
case "${1:-}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 2
        start_daemon
        ;;
    status)
        show_status
        ;;
    install)
        install_service
        ;;
    uninstall)
        uninstall_service
        ;;
    logs)
        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            print_error "Log file not found: $LOG_FILE"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|install|uninstall|logs}"
        echo ""
        echo "Commands:"
        echo "  start      - Start the worker daemon"
        echo "  stop       - Stop the worker daemon"
        echo "  restart    - Restart the worker daemon"
        echo "  status     - Show daemon status and recent logs"
        echo "  install    - Install as macOS LaunchAgent (auto-start on login)"
        echo "  uninstall  - Remove macOS LaunchAgent"
        echo "  logs       - Tail the daemon log file"
        exit 1
        ;;
esac
