#!/bin/bash
# scripts/wizards/debug-helper.sh
# Interactive troubleshooting wizard for Commit-Relay
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
DIM='\033[2m'
NC='\033[0m'

# Box drawing characters
TL='╔'
TR='╗'
BL='╚'
BR='╝'
H='═'
V='║'
VR='╠'
VL='╣'
HU='╩'
HD='╦'

# Helper functions
print_header() {
    local text="$1"
    local width=80

    echo -e "${BOLD}${CYAN}"
    echo -e "${TL}$(printf "${H}%.0s" $(seq 1 $((width - 2))))${TR}"
    printf "${V}%-$((width - 2))s${V}\n" "  $text"
    echo -e "${BL}$(printf "${H}%.0s" $(seq 1 $((width - 2))))${BR}"
    echo -e "${NC}"
}

print_section() {
    local text="$1"
    echo ""
    echo -e "${BOLD}${BLUE}▶ $text${NC}"
    echo -e "${BLUE}$(printf '─%.0s' $(seq 1 80))${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# Menu selection
select_option() {
    local prompt="$1"
    shift
    local options=("$@")

    echo ""
    echo -e "${BOLD}$prompt${NC}"
    echo ""

    for i in "${!options[@]}"; do
        echo -e "  ${CYAN}$((i + 1)).${NC} ${options[$i]}"
    done

    echo ""
    while true; do
        read -p "$(echo -e ${BOLD}Enter choice [1-${#options[@]}]:${NC} )" choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            return $((choice - 1))
        else
            print_error "Invalid choice. Please enter a number between 1 and ${#options[@]}"
        fi
    done
}

# Debug functions

debug_stuck_workers() {
    print_section "Finding Stuck Workers"

    local current_time
    current_time=$(date +%s)
    local stuck_threshold=7200  # 2 hours
    local found_stuck=false

    if [ ! -d "$COMMIT_RELAY_HOME/coordination/worker-specs/active" ]; then
        print_warning "No active workers directory found"
        return
    fi

    for spec in "$COMMIT_RELAY_HOME/coordination/worker-specs/active"/worker-*.json; do
        [ ! -f "$spec" ] && continue

        local worker_id created_at status
        worker_id=$(jq -r '.worker_id // "unknown"' "$spec")
        created_at=$(jq -r '.created_at // ""' "$spec")
        status=$(jq -r '.status // "unknown"' "$spec")

        if [ -z "$created_at" ]; then
            continue
        fi

        # Parse created_at timestamp
        local created_ts
        created_ts=$(date -d "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$created_at" +%s 2>/dev/null || echo "0")

        if [ "$created_ts" == "0" ]; then
            continue
        fi

        local age_seconds=$((current_time - created_ts))
        local age_hours=$((age_seconds / 3600))

        if [ $age_seconds -gt $stuck_threshold ]; then
            found_stuck=true
            local worker_type pid
            worker_type=$(jq -r '.worker_type // "unknown"' "$spec")
            pid=$(jq -r '.pid // ""' "$spec")

            print_warning "Worker: $worker_id"
            echo "  Type: $worker_type"
            echo "  Status: $status"
            echo "  Age: ${age_hours}h (${age_seconds}s)"
            echo "  PID: $pid"

            # Check if process still running
            if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
                print_info "  Process is still running"
            else
                print_error "  Process is NOT running (zombie candidate)"
            fi

            # Check logs
            local log_dir="$COMMIT_RELAY_HOME/agents/logs/workers/$(date +%Y-%m-%d)/$worker_id"
            if [ -d "$log_dir" ]; then
                echo "  Logs: $log_dir/worker.log"
                echo "  Last 3 log lines:"
                tail -3 "$log_dir/worker.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log data)"
            fi

            echo ""
        fi
    done

    if [ "$found_stuck" = false ]; then
        print_success "No stuck workers found"
    else
        echo ""
        print_info "To cleanup stuck workers, run: ./scripts/cleanup-zombie-workers.sh"
    fi
}

debug_failed_tasks() {
    print_section "Analyzing Failed Tasks"

    local task_queue="$COMMIT_RELAY_HOME/coordination/task-queue.json"

    if [ ! -f "$task_queue" ]; then
        print_warning "Task queue file not found"
        return
    fi

    local failed_count
    failed_count=$(jq '[.tasks[] | select(.status == "failed")] | length' "$task_queue")

    if [ "$failed_count" -eq 0 ]; then
        print_success "No failed tasks found"
        return
    fi

    print_warning "Found $failed_count failed tasks"
    echo ""

    jq -r '.tasks[] | select(.status == "failed") |
        "Task: \(.task_id // "unknown")\n" +
        "  Description: \(.description // "N/A")\n" +
        "  Priority: \(.priority // "N/A")\n" +
        "  Created: \(.created_at // "N/A")\n" +
        "  Error: \(.error // "N/A")\n"' "$task_queue"

    echo ""
    print_info "Check task logs in coordination/tasks/ for more details"
}

debug_daemon_health() {
    print_section "Checking Daemon Health"

    local daemons=(
        "worker-daemon:Worker Daemon"
        "pm-daemon:PM Daemon"
        "coordinator-daemon:Coordinator Daemon"
        "heartbeat-monitor-daemon:Heartbeat Monitor"
        "metrics-snapshot-daemon:Metrics Snapshot"
        "integration-validator-daemon:Integration Validator"
        "failure-pattern-daemon:Pattern Detection"
        "worker-restart-daemon:Worker Restart"
        "auto-fix-daemon:Auto-Fix"
    )

    local all_healthy=true

    for daemon_info in "${daemons[@]}"; do
        IFS=':' read -r daemon_name display_name <<< "$daemon_info"
        local pidfile="/tmp/commit-relay-${daemon_name}.pid"

        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")

            if ps -p "$pid" > /dev/null 2>&1; then
                # Get uptime
                local start_time uptime_seconds
                start_time=$(ps -o lstart= -p "$pid" 2>/dev/null | xargs -I {} date -d "{}" +%s 2>/dev/null || echo "0")
                uptime_seconds=$(($(date +%s) - start_time))
                local uptime_hours=$((uptime_seconds / 3600))

                print_success "$display_name (PID: $pid, Uptime: ${uptime_hours}h)"
            else
                print_error "$display_name (PID file exists but process not running)"
                all_healthy=false
            fi
        else
            print_error "$display_name (not running - no PID file)"
            all_healthy=false
        fi
    done

    echo ""
    if [ "$all_healthy" = true ]; then
        print_success "All daemons are healthy"
    else
        print_warning "Some daemons are not running"
        print_info "Use './scripts/wizards/daemon-control.sh' to manage daemons"
    fi
}

debug_logs() {
    print_section "Log Analysis"

    echo "Select log source to analyze:"
    echo ""
    echo "  1. All daemon logs (last 50 errors)"
    echo "  2. All worker logs (last 50 errors)"
    echo "  3. Specific daemon log"
    echo "  4. Specific worker log"
    echo "  5. Search all logs for pattern"
    echo ""

    read -p "$(echo -e ${BOLD}Enter choice [1-5]:${NC} )" log_choice

    case "$log_choice" in
        1)
            print_info "Searching daemon logs for errors..."
            grep -r -i "error" "$COMMIT_RELAY_HOME/agents/logs/system/"*.log 2>/dev/null | tail -50 || print_info "No errors found"
            ;;
        2)
            print_info "Searching worker logs for errors..."
            find "$COMMIT_RELAY_HOME/agents/logs/workers/" -name "worker.log" -exec grep -i "error" {} + 2>/dev/null | tail -50 || print_info "No errors found"
            ;;
        3)
            echo ""
            echo "Available daemon logs:"
            ls -1 "$COMMIT_RELAY_HOME/agents/logs/system/" 2>/dev/null || print_warning "No daemon logs found"
            echo ""
            read -p "Enter daemon log filename: " daemon_log
            if [ -f "$COMMIT_RELAY_HOME/agents/logs/system/$daemon_log" ]; then
                tail -50 "$COMMIT_RELAY_HOME/agents/logs/system/$daemon_log"
            else
                print_error "Log file not found"
            fi
            ;;
        4)
            echo ""
            read -p "Enter worker ID: " worker_id
            local worker_log_dir="$COMMIT_RELAY_HOME/agents/logs/workers/$(date +%Y-%m-%d)/$worker_id"
            if [ -d "$worker_log_dir" ]; then
                tail -50 "$worker_log_dir/worker.log" 2>/dev/null || print_error "No log file found"
            else
                print_error "Worker log directory not found: $worker_log_dir"
            fi
            ;;
        5)
            echo ""
            read -p "Enter search pattern: " search_pattern
            print_info "Searching all logs for: $search_pattern"
            echo ""
            grep -r -i "$search_pattern" "$COMMIT_RELAY_HOME/agents/logs/" 2>/dev/null | tail -50 || print_info "No matches found"
            ;;
        *)
            print_error "Invalid choice"
            ;;
    esac
}

debug_token_budget() {
    print_section "Token Budget Analysis"

    local budget_file="$COMMIT_RELAY_HOME/coordination/token-budget.json"

    if [ ! -f "$budget_file" ]; then
        print_error "Token budget file not found"
        return
    fi

    local total used available percentage
    total=$(jq -r '.total // 0' "$budget_file")
    used=$(jq -r '.used // 0' "$budget_file")
    available=$(jq -r '.available // 0' "$budget_file")
    percentage=$(( (available * 100) / total ))

    echo "Token Budget Status:"
    echo "  Total:     $total"
    echo "  Used:      $used"
    echo "  Available: $available ($percentage%)"
    echo ""

    # Color-code status
    if [ $percentage -lt 10 ]; then
        print_error "CRITICAL: Token budget critically low!"
    elif [ $percentage -lt 30 ]; then
        print_warning "WARNING: Token budget low"
    else
        print_success "Token budget healthy"
    fi

    echo ""
    print_info "Token allocation by worker:"
    echo ""

    # Active workers
    local active_total=0
    for spec in "$COMMIT_RELAY_HOME/coordination/worker-specs/active"/worker-*.json; do
        [ ! -f "$spec" ] && continue

        local worker_id allocated
        worker_id=$(jq -r '.worker_id // "unknown"' "$spec")
        allocated=$(jq -r '.token_budget.allocated // 0' "$spec")
        active_total=$((active_total + allocated))

        echo "  $worker_id: $allocated tokens"
    done

    # Zombie workers (should be 0)
    local zombie_total=0
    local zombie_count=0
    for zombie in "$COMMIT_RELAY_HOME/coordination/worker-specs/zombie"/worker-*.json 2>/dev/null; do
        [ ! -f "$zombie" ] && continue

        local worker_id allocated
        worker_id=$(basename "$zombie" .json)
        allocated=$(jq -r '.token_budget.allocated // 0' "$zombie")
        zombie_total=$((zombie_total + allocated))
        zombie_count=$((zombie_count + 1))

        print_warning "  $worker_id (ZOMBIE): $allocated tokens"
    done

    echo ""
    echo "Summary:"
    echo "  Active workers total: $active_total tokens"

    if [ $zombie_count -gt 0 ]; then
        print_warning "  Zombie workers total: $zombie_total tokens ($zombie_count zombies)"
        echo ""
        print_info "Run './scripts/cleanup-zombie-workers.sh' to recover tokens"
    fi

    # Check for accounting mismatch
    local total_allocated=$((active_total + zombie_total))
    if [ $total_allocated -ne $used ]; then
        echo ""
        print_error "Token accounting mismatch detected!"
        echo "  Calculated: $total_allocated"
        echo "  Budget shows: $used"
        echo "  Difference: $((used - total_allocated))"
    fi
}

debug_zombies() {
    print_section "Zombie Worker Analysis"

    local zombie_dir="$COMMIT_RELAY_HOME/coordination/worker-specs/zombie"

    if [ ! -d "$zombie_dir" ]; then
        print_warning "No zombie directory found"
        return
    fi

    local zombie_count
    zombie_count=$(find "$zombie_dir" -name "worker-*.json" 2>/dev/null | wc -l)

    if [ "$zombie_count" -eq 0 ]; then
        print_success "No zombie workers found"
        return
    fi

    print_warning "Found $zombie_count zombie workers"
    echo ""

    for zombie in "$zombie_dir"/worker-*.json; do
        [ ! -f "$zombie" ] && continue

        local worker_id worker_type created_at allocated pid
        worker_id=$(jq -r '.worker_id // "unknown"' "$zombie")
        worker_type=$(jq -r '.worker_type // "unknown"' "$zombie")
        created_at=$(jq -r '.created_at // "N/A"' "$zombie")
        allocated=$(jq -r '.token_budget.allocated // 0' "$zombie")
        pid=$(jq -r '.pid // ""' "$zombie")

        echo "Worker: $worker_id"
        echo "  Type: $worker_type"
        echo "  Created: $created_at"
        echo "  Tokens: $allocated"
        echo "  PID: $pid"

        # Check if process still running
        if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
            print_warning "  Process STILL RUNNING (requires force kill)"
        else
            print_info "  Process terminated"
        fi

        echo ""
    done

    print_info "To cleanup zombies, run: ./scripts/cleanup-zombie-workers.sh"
}

debug_patterns() {
    print_section "Failure Pattern Analysis"

    local patterns_file="$COMMIT_RELAY_HOME/coordination/patterns/failure-patterns.jsonl"

    if [ ! -f "$patterns_file" ]; then
        print_warning "No failure patterns file found"
        return
    fi

    local pattern_count
    pattern_count=$(wc -l < "$patterns_file")

    if [ "$pattern_count" -eq 0 ]; then
        print_success "No failure patterns detected"
        return
    fi

    print_info "Found $pattern_count failure patterns"
    echo ""

    # Show high-confidence patterns
    print_info "High-confidence patterns (>70%):"
    echo ""

    local high_conf_count=0
    while IFS= read -r pattern; do
        local pattern_id category confidence severity
        pattern_id=$(echo "$pattern" | jq -r '.pattern_id // "unknown"')
        category=$(echo "$pattern" | jq -r '.category // "unknown"')
        confidence=$(echo "$pattern" | jq -r '.confidence // 0')
        severity=$(echo "$pattern" | jq -r '.severity // "unknown"')

        # Convert confidence to percentage
        local conf_pct=$(echo "$confidence * 100" | bc 2>/dev/null | cut -d. -f1)

        if [ "$conf_pct" -gt 70 ]; then
            high_conf_count=$((high_conf_count + 1))
            echo "Pattern: $pattern_id"
            echo "  Category: $category"
            echo "  Confidence: ${conf_pct}%"
            echo "  Severity: $severity"
            echo ""
        fi
    done < "$patterns_file"

    if [ $high_conf_count -eq 0 ]; then
        print_info "No high-confidence patterns"
    fi

    # Pattern categories summary
    echo ""
    print_info "Patterns by category:"
    echo ""
    jq -s 'group_by(.category) | map({category: .[0].category, count: length})' "$patterns_file" 2>/dev/null || print_error "Failed to parse patterns"
}

debug_autofix() {
    print_section "Auto-Fix History"

    local fix_history="$COMMIT_RELAY_HOME/coordination/auto-fix/fix-history.jsonl"

    if [ ! -f "$fix_history" ]; then
        print_warning "No auto-fix history found"
        return
    fi

    local fix_count
    fix_count=$(wc -l < "$fix_history")

    if [ "$fix_count" -eq 0 ]; then
        print_info "No auto-fixes attempted yet"
        return
    fi

    print_info "Found $fix_count auto-fix attempts"
    echo ""

    # Show recent fixes
    print_info "Recent fixes (last 10):"
    echo ""

    tail -10 "$fix_history" | while IFS= read -r fix; do
        local fix_id pattern_id status timestamp
        fix_id=$(echo "$fix" | jq -r '.fix_id // "unknown"')
        pattern_id=$(echo "$fix" | jq -r '.pattern_id // "unknown"')
        status=$(echo "$fix" | jq -r '.status // "unknown"')
        timestamp=$(echo "$fix" | jq -r '.timestamp // "N/A"')

        echo "Fix: $fix_id"
        echo "  Pattern: $pattern_id"
        echo "  Status: $status"
        echo "  Time: $timestamp"
        echo ""
    done

    # Success rate
    echo ""
    print_info "Fix success rate:"
    jq -s 'group_by(.status) | map({status: .[0].status, count: length})' "$fix_history" 2>/dev/null || print_error "Failed to calculate success rate"
}

# Main menu
main_menu() {
    while true; do
        clear
        print_header "Commit-Relay Debug Helper"

        echo "Select debugging task:"
        echo ""
        echo "  ${CYAN}1.${NC} Find stuck workers (>2h runtime)"
        echo "  ${CYAN}2.${NC} Analyze failed tasks"
        echo "  ${CYAN}3.${NC} Check daemon health"
        echo "  ${CYAN}4.${NC} Analyze logs"
        echo "  ${CYAN}5.${NC} Check token budget"
        echo "  ${CYAN}6.${NC} Find zombie workers"
        echo "  ${CYAN}7.${NC} View failure patterns"
        echo "  ${CYAN}8.${NC} Check auto-fix history"
        echo "  ${CYAN}9.${NC} Run all checks (full diagnostic)"
        echo "  ${CYAN}0.${NC} Exit"
        echo ""

        read -p "$(echo -e ${BOLD}Enter choice [0-9]:${NC} )" choice

        case "$choice" in
            1)
                debug_stuck_workers
                ;;
            2)
                debug_failed_tasks
                ;;
            3)
                debug_daemon_health
                ;;
            4)
                debug_logs
                ;;
            5)
                debug_token_budget
                ;;
            6)
                debug_zombies
                ;;
            7)
                debug_patterns
                ;;
            8)
                debug_autofix
                ;;
            9)
                print_section "Running Full System Diagnostic"
                debug_daemon_health
                debug_token_budget
                debug_stuck_workers
                debug_zombies
                debug_failed_tasks
                debug_patterns
                debug_autofix
                ;;
            0)
                echo ""
                print_success "Debug helper exited"
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac

        echo ""
        echo ""
        read -p "$(echo -e ${DIM}Press Enter to return to menu...${NC})"
    done
}

# Run main menu
main_menu
