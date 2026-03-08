#!/bin/bash
# scripts/wizards/daemon-control.sh
# Interactive daemon management wizard
# Part of Phase 5: Developer Experience

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Daemon definitions
declare -A DAEMONS
DAEMONS[worker]="Worker Daemon|scripts/worker-daemon.sh|/tmp/commit-relay-worker.pid"
DAEMONS[pm]="PM Daemon|scripts/pm-daemon.sh|/tmp/commit-relay-pm.pid"
DAEMONS[health]="Health Monitor|scripts/daemons/heartbeat-monitor-daemon.sh|/tmp/commit-relay-heartbeat.pid"
DAEMONS[metrics]="Metrics Snapshot|scripts/metrics-snapshot-daemon.sh|/tmp/commit-relay-metrics.pid"
DAEMONS[coordinator]="Coordinator Daemon|scripts/coordinator-daemon.sh|/tmp/commit-relay-coordinator.pid"
DAEMONS[integration]="Integration Validator|scripts/integration-validator-daemon.sh|/tmp/commit-relay-integration.pid"
DAEMONS[pattern]="Pattern Detection|scripts/daemons/failure-pattern-daemon.sh|/tmp/commit-relay-failure-pattern.pid"
DAEMONS[restart]="Worker Restart|scripts/daemons/worker-restart-daemon.sh|/tmp/commit-relay-worker-restart.pid"
DAEMONS[autofix]="Auto-Fix Daemon|scripts/daemons/auto-fix-daemon.sh|/tmp/commit-relay-auto-fix.pid"

# Print functions
print_header() {
    clear
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${CYAN}Daemon Control Center${NC}                                 ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC}  $1"
}

print_error() {
    echo -e "${RED}✗${NC}  $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC}  $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

# Get daemon status
get_daemon_status() {
    local daemon_key="$1"
    IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"

    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "running|$pid"
            return 0
        fi
    fi

    echo "stopped|N/A"
    return 1
}

# Calculate uptime
get_uptime() {
    local pid="$1"

    if [[ "$pid" == "N/A" ]]; then
        echo "N/A"
        return 1
    fi

    # Get process start time (platform-specific)
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        local start_time
        start_time=$(ps -p "$pid" -o lstart= 2>/dev/null | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" "+%s" 2>/dev/null || echo "")
    else
        # Linux
        local start_time
        start_time=$(ps -p "$pid" -o lstart= 2>/dev/null | xargs -I{} date -d "{}" "+%s" 2>/dev/null || echo "")
    fi

    if [[ -z "$start_time" ]]; then
        echo "N/A"
        return 1
    fi

    local now
    now=$(date +%s)
    local uptime_seconds=$((now - start_time))

    # Format uptime
    local days=$((uptime_seconds / 86400))
    local hours=$(( (uptime_seconds % 86400) / 3600 ))
    local minutes=$(( (uptime_seconds % 3600) / 60 ))

    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# Display all daemon statuses
show_daemon_status() {
    echo -e "\n${BOLD}Daemon Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    printf "%-25s %-12s %-10s %-12s\n" "Daemon" "Status" "PID" "Uptime"
    printf "%-25s %-12s %-10s %-12s\n" "───────" "──────" "───" "──────"

    local running_count=0
    local total_count=${#DAEMONS[@]}

    for daemon_key in "${!DAEMONS[@]}"; do
        IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"
        IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"

        local uptime
        uptime=$(get_uptime "$pid")

        if [[ "$status" == "running" ]]; then
            printf "${GREEN}%-25s %-12s %-10s %-12s${NC}\n" "$name" "✓ Running" "$pid" "$uptime"
            ((running_count++))
        else
            printf "${RED}%-25s %-12s %-10s %-12s${NC}\n" "$name" "✗ Stopped" "N/A" "N/A"
        fi
    done

    echo ""
    echo -e "Total: ${CYAN}$running_count${NC}/${CYAN}$total_count${NC} running"
}

# Start daemon
start_daemon() {
    local daemon_key="$1"
    IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"
    IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"

    if [[ "$status" == "running" ]]; then
        print_warning "$name is already running (PID: $pid)"
        return 1
    fi

    print_info "Starting $name..."

    local daemon_script="$COMMIT_RELAY_HOME/$script"

    if [[ ! -f "$daemon_script" ]]; then
        print_error "Daemon script not found: $daemon_script"
        return 1
    fi

    # Start daemon in background
    if bash "$daemon_script" > /dev/null 2>&1 & then
        sleep 2  # Give daemon time to start

        IFS='|' read -r new_status new_pid <<< "$(get_daemon_status "$daemon_key")"

        if [[ "$new_status" == "running" ]]; then
            print_success "$name started successfully (PID: $new_pid)"
            return 0
        else
            print_error "$name failed to start"
            return 1
        fi
    else
        print_error "Failed to execute $name"
        return 1
    fi
}

# Stop daemon
stop_daemon() {
    local daemon_key="$1"
    IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"
    IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"

    if [[ "$status" == "stopped" ]]; then
        print_warning "$name is not running"
        return 1
    fi

    print_info "Stopping $name (PID: $pid)..."

    # Try graceful shutdown first
    if kill -TERM "$pid" 2>/dev/null; then
        sleep 2

        # Check if still running
        if ps -p "$pid" > /dev/null 2>&1; then
            print_warning "Graceful shutdown failed, forcing..."
            kill -KILL "$pid" 2>/dev/null || true
        fi

        # Clean up PID file
        rm -f "$pidfile"

        print_success "$name stopped successfully"
        return 0
    else
        print_error "Failed to stop $name"
        return 1
    fi
}

# Restart daemon
restart_daemon() {
    local daemon_key="$1"
    IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"

    print_info "Restarting $name..."

    stop_daemon "$daemon_key" || true
    sleep 1
    start_daemon "$daemon_key"
}

# View daemon logs
view_daemon_logs() {
    local daemon_key="$1"
    IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"

    # Determine log file based on daemon type
    local log_file=""

    case "$daemon_key" in
        pattern)
            log_file="$COMMIT_RELAY_HOME/agents/logs/system/failure-pattern-daemon.log"
            ;;
        restart)
            log_file="$COMMIT_RELAY_HOME/agents/logs/system/worker-restart-daemon.log"
            ;;
        autofix)
            log_file="$COMMIT_RELAY_HOME/agents/logs/system/auto-fix-daemon.log"
            ;;
        health)
            log_file="$COMMIT_RELAY_HOME/agents/logs/system/heartbeat-monitor-daemon.log"
            ;;
        *)
            # Try to find log in common locations
            local log_name="${daemon_key}-daemon.log"
            if [[ -f "$COMMIT_RELAY_HOME/agents/logs/system/$log_name" ]]; then
                log_file="$COMMIT_RELAY_HOME/agents/logs/system/$log_name"
            fi
            ;;
    esac

    if [[ -z "$log_file" || ! -f "$log_file" ]]; then
        print_error "Log file not found for $name"
        return 1
    fi

    clear
    echo -e "${BOLD}${CYAN}Logs for $name${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Show last 50 lines
    tail -n 50 "$log_file"

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Log file: ${CYAN}$log_file${NC}"
    echo -e "Press ${YELLOW}Enter${NC} to return to menu..."
    read
}

# Main menu
show_main_menu() {
    print_header
    show_daemon_status

    echo ""
    echo -e "${BOLD}Actions${NC}"
    echo -e "  ${GREEN}[1]${NC} View daemon status (refresh)"
    echo -e "  ${GREEN}[2]${NC} Start daemon(s)"
    echo -e "  ${GREEN}[3]${NC} Stop daemon(s)"
    echo -e "  ${GREEN}[4]${NC} Restart daemon(s)"
    echo -e "  ${GREEN}[5]${NC} View daemon logs"
    echo -e "  ${GREEN}[6]${NC} Start all daemons"
    echo -e "  ${GREEN}[7]${NC} Stop all daemons"
    echo -e "  ${GREEN}[8]${NC} Health check"
    echo -e "  ${GREEN}[0]${NC} Exit"
    echo ""
    echo -ne "${YELLOW}?${NC}  Select action: "
}

# Select daemon menu
select_daemon() {
    local action="$1"

    echo ""
    echo -e "${BOLD}Select Daemon for $action${NC}"
    echo ""

    local i=1
    local daemon_keys=()

    for daemon_key in "${!DAEMONS[@]}"; do
        IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"
        echo -e "  ${GREEN}[$i]${NC} $name"
        daemon_keys+=("$daemon_key")
        ((i++))
    done

    echo ""
    echo -ne "${YELLOW}?${NC}  Select daemon (1-${#daemon_keys[@]}) or 0 to cancel: "
    read selection

    if [[ "$selection" == "0" ]]; then
        return 1
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#daemon_keys[@]} )); then
        echo "${daemon_keys[$((selection-1))]}"
        return 0
    else
        print_error "Invalid selection"
        sleep 1
        return 1
    fi
}

# Health check all daemons
health_check() {
    print_header
    echo -e "${BOLD}${CYAN}Daemon Health Check${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local unhealthy_count=0

    for daemon_key in "${!DAEMONS[@]}"; do
        IFS='|' read -r name script pidfile <<< "${DAEMONS[$daemon_key]}"
        IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"

        if [[ "$status" == "running" ]]; then
            print_success "$name is healthy (PID: $pid)"
        else
            print_error "$name is unhealthy (not running)"
            ((unhealthy_count++))
        fi
    done

    echo ""

    if (( unhealthy_count == 0 )); then
        echo -e "${GREEN}${BOLD}✓ All daemons are healthy!${NC}"
    else
        echo -e "${RED}${BOLD}✗ $unhealthy_count daemon(s) are unhealthy${NC}"
        echo ""
        echo -ne "Restart unhealthy daemons? (y/n): "
        read restart_choice

        if [[ "$restart_choice" == "y" ]]; then
            for daemon_key in "${!DAEMONS[@]}"; do
                IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"
                if [[ "$status" == "stopped" ]]; then
                    start_daemon "$daemon_key"
                fi
            done
        fi
    fi

    echo ""
    echo -e "Press ${YELLOW}Enter${NC} to return to menu..."
    read
}

# Main loop
main() {
    while true; do
        show_main_menu
        read action

        case "$action" in
            1)
                # Refresh - loop will redraw
                ;;
            2)
                # Start daemon
                if daemon_key=$(select_daemon "Start"); then
                    start_daemon "$daemon_key"
                    sleep 2
                fi
                ;;
            3)
                # Stop daemon
                if daemon_key=$(select_daemon "Stop"); then
                    stop_daemon "$daemon_key"
                    sleep 2
                fi
                ;;
            4)
                # Restart daemon
                if daemon_key=$(select_daemon "Restart"); then
                    restart_daemon "$daemon_key"
                    sleep 2
                fi
                ;;
            5)
                # View logs
                if daemon_key=$(select_daemon "View Logs"); then
                    view_daemon_logs "$daemon_key"
                fi
                ;;
            6)
                # Start all
                print_info "Starting all daemons..."
                for daemon_key in "${!DAEMONS[@]}"; do
                    IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"
                    if [[ "$status" == "stopped" ]]; then
                        start_daemon "$daemon_key"
                    fi
                done
                sleep 3
                ;;
            7)
                # Stop all
                echo -ne "${YELLOW}⚠${NC}  Are you sure you want to stop all daemons? (y/n): "
                read confirm
                if [[ "$confirm" == "y" ]]; then
                    print_info "Stopping all daemons..."
                    for daemon_key in "${!DAEMONS[@]}"; do
                        IFS='|' read -r status pid <<< "$(get_daemon_status "$daemon_key")"
                        if [[ "$status" == "running" ]]; then
                            stop_daemon "$daemon_key"
                        fi
                    done
                    sleep 3
                fi
                ;;
            8)
                # Health check
                health_check
                ;;
            0)
                print_info "Exiting daemon control center..."
                exit 0
                ;;
            *)
                print_error "Invalid action"
                sleep 1
                ;;
        esac
    done
}

# Run main loop
main "$@"
