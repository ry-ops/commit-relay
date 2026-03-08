#!/bin/bash
# scripts/interactive-tutorial.sh
# Interactive tutorial for learning Commit-Relay
# Part of Phase 5: Developer Experience

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

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

# Tutorial state
TUTORIAL_STEP=0
TUTORIAL_COMPLETE=false

# Helper functions
print_header() {
    local text="$1"
    local width=80

    clear
    echo -e "${BOLD}${CYAN}"
    echo -e "${TL}$(printf "${H}%.0s" $(seq 1 $((width - 2))))${TR}"
    printf "${V}%-$((width - 2))s${V}\n" "  $text"
    echo -e "${BL}$(printf "${H}%.0s" $(seq 1 $((width - 2))))${BR}"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

print_step() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━ Step $1: $2 ━━━${NC}"
    echo ""
}

wait_for_enter() {
    echo ""
    read -p "$(echo -e ${DIM}Press Enter to continue...${NC})"
}

# Welcome
show_welcome() {
    print_header "Welcome to Commit-Relay Interactive Tutorial"

    echo ""
    echo -e "${BOLD}🎓 Learning Objectives:${NC}"
    echo ""
    echo "  By the end of this tutorial, you will know how to:"
    echo ""
    echo "  ✓ Understand Commit-Relay architecture"
    echo "  ✓ Start and monitor daemons"
    echo "  ✓ Create and track tasks"
    echo "  ✓ Spawn and monitor workers"
    echo "  ✓ Use dashboards and monitoring tools"
    echo "  ✓ Troubleshoot common issues"
    echo "  ✓ Navigate the self-healing system"
    echo ""
    echo -e "${BOLD}⏱  Estimated Time:${NC} 20-30 minutes"
    echo ""
    echo -e "${BOLD}📋 Prerequisites:${NC}"
    echo "  - Commit-Relay installed and configured"
    echo "  - Basic understanding of command line"
    echo "  - Terminal with 80+ columns recommended"
    echo ""

    wait_for_enter
}

# Lesson 1: Architecture Overview
lesson_architecture() {
    print_header "Lesson 1: Understanding Commit-Relay Architecture"

    print_step "1.1" "Core Components"

    echo "Commit-Relay is built on a distributed agent architecture:"
    echo ""
    echo -e "${BOLD}Master Agents${NC} (Specialists):"
    echo "  • development-master   - Code changes, bug fixes, features"
    echo "  • security-master      - Security scans, CVE remediation"
    echo "  • inventory-master     - Repository cataloging, docs"
    echo "  • cicd-master          - Builds, deployments, releases"
    echo "  • dashboard-agent      - System monitoring (read-only)"
    echo ""
    echo -e "${BOLD}Worker Agents${NC} (Task Executors):"
    echo "  • Spawned by masters to execute specific tasks"
    echo "  • Types: scan, fix, analysis, implementation, test, etc."
    echo "  • Autonomous: receive task, execute, report results"
    echo ""
    echo -e "${BOLD}Coordinator${NC}:"
    echo "  • Routes tasks to appropriate masters using MoE (Mixture of Experts)"
    echo "  • Learns from routing decisions over time"
    echo "  • Manages task queue and priority"
    echo ""

    wait_for_enter

    print_step "1.2" "System Daemons"

    echo "Nine daemons keep the system running:"
    echo ""
    echo -e "${CYAN}Core Daemons:${NC}"
    echo "  1. worker-daemon           - Worker lifecycle management"
    echo "  2. pm-daemon               - Process monitoring"
    echo "  3. coordinator-daemon      - Task routing and coordination"
    echo ""
    echo -e "${CYAN}Observability Daemons:${NC}"
    echo "  4. heartbeat-monitor       - Worker health tracking"
    echo "  5. metrics-snapshot        - System metrics collection"
    echo "  6. integration-validator   - System integrity checks"
    echo ""
    echo -e "${CYAN}Self-Healing Daemons:${NC}"
    echo "  7. failure-pattern         - Detect failure patterns"
    echo "  8. worker-restart          - Auto-restart failed workers"
    echo "  9. auto-fix                - Apply automatic fixes"
    echo ""

    wait_for_enter

    print_step "1.3" "Check System Status"

    echo "Let's check if daemons are running:"
    echo ""

    local running_daemons=0
    local total_daemons=9

    for daemon in worker-daemon pm-daemon coordinator-daemon heartbeat-monitor-daemon metrics-snapshot-daemon integration-validator-daemon failure-pattern-daemon worker-restart-daemon auto-fix-daemon; do
        local pidfile="/tmp/commit-relay-${daemon}.pid"
        if [ -f "$pidfile" ]; then
            local pid=$(cat "$pidfile")
            if ps -p "$pid" > /dev/null 2>&1; then
                print_success "$daemon is running (PID: $pid)"
                ((running_daemons++))
            else
                print_error "$daemon is NOT running"
            fi
        else
            print_error "$daemon is NOT running (no PID file)"
        fi
    done

    echo ""
    echo -e "${BOLD}Status:${NC} $running_daemons/$total_daemons daemons running"

    if [ $running_daemons -lt $total_daemons ]; then
        echo ""
        print_info "To start daemons, run: ./scripts/wizards/daemon-control.sh"
    fi

    wait_for_enter
}

# Lesson 2: Daemon Management
lesson_daemons() {
    print_header "Lesson 2: Managing Daemons"

    print_step "2.1" "Daemon Control Center"

    echo "The daemon control center provides an interactive interface for:"
    echo ""
    echo "  • Viewing daemon status"
    echo "  • Starting/stopping individual daemons"
    echo "  • Starting/stopping all daemons"
    echo "  • Viewing daemon logs"
    echo "  • Running health checks"
    echo ""
    echo -e "${BOLD}Command:${NC} ./scripts/wizards/daemon-control.sh"
    echo ""

    read -p "$(echo -e ${CYAN}Would you like to open the daemon control center now? [y/N]:${NC} )" open_daemon

    if [[ "$open_daemon" = "y" || "$open_daemon" = "Y" ]]; then
        echo ""
        print_info "Opening daemon control center..."
        echo ""
        ./scripts/wizards/daemon-control.sh || true
        echo ""
    fi

    print_step "2.2" "Checking Daemon Logs"

    echo "Daemon logs are stored in:"
    echo "  ${CYAN}agents/logs/system/${NC}"
    echo ""
    echo "Example commands:"
    echo "  # View recent heartbeat monitor logs"
    echo "  tail -20 agents/logs/system/heartbeat-monitor-daemon.log"
    echo ""
    echo "  # Search for errors"
    echo "  grep -i error agents/logs/system/*.log"
    echo ""

    wait_for_enter
}

# Lesson 3: Task Management
lesson_tasks() {
    print_header "Lesson 3: Creating and Managing Tasks"

    print_step "3.1" "Task Lifecycle"

    echo "Tasks flow through these states:"
    echo ""
    echo "  queued → routed → in_progress → completed/failed"
    echo ""
    echo -e "${BOLD}Task Properties:${NC}"
    echo "  • task_id: Unique identifier"
    echo "  • description: What needs to be done"
    echo "  • priority: critical/high/medium/low"
    echo "  • task_type: security/development/inventory/cicd"
    echo "  • status: Current state"
    echo ""

    wait_for_enter

    print_step "3.2" "Creating a Task"

    echo "You can create tasks using the task creation wizard:"
    echo ""
    echo -e "${BOLD}Interactive Mode:${NC}"
    echo "  ./scripts/wizards/create-task.sh"
    echo ""
    echo -e "${BOLD}Quick Mode:${NC}"
    echo "  ./scripts/wizards/create-task.sh --quick \"description\" [priority] [type]"
    echo ""
    echo -e "${BOLD}Example:${NC}"
    echo "  ./scripts/wizards/create-task.sh --quick \\"
    echo "    \"Scan for vulnerabilities in auth module\" high security"
    echo ""

    read -p "$(echo -e ${CYAN}Create a demo task now? [y/N]:${NC} )" create_task

    if [[ "$create_task" = "y" || "$create_task" = "Y" ]]; then
        echo ""
        ./scripts/wizards/create-task.sh --quick "Tutorial demo task - Hello Commit-Relay!" medium development
        echo ""
        print_success "Demo task created!"
    fi

    wait_for_enter

    print_step "3.3" "Viewing Task Queue"

    echo "Check the current task queue:"
    echo ""

    if [ -f "$COMMIT_RELAY_HOME/coordination/task-queue.json" ]; then
        cat "$COMMIT_RELAY_HOME/coordination/task-queue.json" | jq '{
            total: (.tasks | length),
            queued: ([.tasks[] | select(.status == "queued")] | length),
            in_progress: ([.tasks[] | select(.status == "in_progress")] | length),
            completed: ([.tasks[] | select(.status == "completed")] | length)
        }'
    else
        print_info "Task queue not yet initialized"
    fi

    echo ""
    print_info "Monitor task queue: ./scripts/dashboards/task-queue-monitor.sh"

    wait_for_enter
}

# Lesson 4: Worker Management
lesson_workers() {
    print_header "Lesson 4: Workers - The Task Executors"

    print_step "4.1" "Worker Types"

    echo "Different worker types for different tasks:"
    echo ""
    echo -e "${BOLD}Worker Type          Purpose                   Budget    Duration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "scan-worker          Security scanning         70,000    15 min"
    echo "fix-worker           Apply fixes               70,000    20 min"
    echo "analysis-worker      Research/investigation    50,000    15 min"
    echo "implementation-worker Feature development      100,000   45 min"
    echo "test-worker          Test creation             70,000    20 min"
    echo "documentation-worker Write documentation       70,000    20 min"
    echo ""

    wait_for_enter

    print_step "4.2" "Spawning a Worker"

    echo "Use the create-worker wizard to spawn workers:"
    echo ""
    echo -e "${BOLD}Command:${NC} ./scripts/wizards/create-worker.sh"
    echo ""
    echo "The wizard will guide you through:"
    echo "  1. Selecting worker type"
    echo "  2. Assigning task ID"
    echo "  3. Setting priority"
    echo "  4. Configuring repository"
    echo "  5. Reviewing specification"
    echo ""

    read -p "$(echo -e ${CYAN}Open create-worker wizard? [y/N]:${NC} )" create_worker

    if [[ "$create_worker" = "y" || "$create_worker" = "Y" ]]; then
        echo ""
        ./scripts/wizards/create-worker.sh || true
        echo ""
    fi

    print_step "4.3" "Monitoring Workers"

    echo "Check active workers:"
    echo ""

    local active_count=$(ls "$COMMIT_RELAY_HOME/coordination/worker-specs/active/" 2>/dev/null | wc -l)
    echo -e "${BOLD}Active workers:${NC} $active_count"
    echo ""

    if [ $active_count -gt 0 ]; then
        echo "Recent workers:"
        ls -lt "$COMMIT_RELAY_HOME/coordination/worker-specs/active/" | head -5
    fi

    echo ""
    print_info "Worker monitor dashboard: ./scripts/dashboards/worker-monitor.sh"

    wait_for_enter
}

# Lesson 5: Monitoring and Dashboards
lesson_dashboards() {
    print_header "Lesson 5: Dashboards and Monitoring"

    print_step "5.1" "System Dashboard"

    echo "The system dashboard provides a real-time overview:"
    echo ""
    echo -e "${BOLD}Shows:${NC}"
    echo "  • Daemon status (all 9 daemons)"
    echo "  • Active workers count"
    echo "  • Task queue status"
    echo "  • Token budget (available/used)"
    echo "  • Recent system events"
    echo "  • Worker health summary"
    echo ""
    echo -e "${BOLD}Command:${NC} ./scripts/dashboards/system-live.sh"
    echo "  • Auto-refreshes every 5 seconds"
    echo "  • Press 'q' to quit"
    echo ""

    read -p "$(echo -e ${CYAN}Open system dashboard? [y/N]:${NC} )" open_dash

    if [[ "$open_dash" = "y" || "$open_dash" = "Y" ]]; then
        echo ""
        print_info "Opening system dashboard (press Ctrl+C to exit)..."
        sleep 2
        ./scripts/dashboards/system-live.sh || true
        echo ""
    fi

    wait_for_enter

    print_step "5.2" "Specialized Dashboards"

    echo "Additional monitoring dashboards:"
    echo ""
    echo -e "${BOLD}1. Worker Monitor${NC}"
    echo "   ./scripts/dashboards/worker-monitor.sh"
    echo "   • Detailed worker status by type"
    echo "   • Health scores and uptime"
    echo "   • Filter by status or type"
    echo ""
    echo -e "${BOLD}2. Task Queue Monitor${NC}"
    echo "   ./scripts/dashboards/task-queue-monitor.sh"
    echo "   • Real-time task queue view"
    echo "   • Task age and duration"
    echo "   • Priority distribution"
    echo ""
    echo -e "${BOLD}3. Web Dashboard${NC}"
    echo "   http://localhost:3000"
    echo "   • Browser-based interface"
    echo "   • Historical metrics"
    echo "   • Advanced visualizations"
    echo ""

    wait_for_enter
}

# Lesson 6: Troubleshooting
lesson_troubleshooting() {
    print_header "Lesson 6: Debugging and Troubleshooting"

    print_step "6.1" "Debug Helper"

    echo "The debug helper wizard provides diagnostic tools:"
    echo ""
    echo -e "${BOLD}Available Diagnostics:${NC}"
    echo "  1. Find stuck workers (>2h runtime)"
    echo "  2. Analyze failed tasks"
    echo "  3. Check daemon health"
    echo "  4. Analyze logs"
    echo "  5. Check token budget"
    echo "  6. Find zombie workers"
    echo "  7. View failure patterns"
    echo "  8. Check auto-fix history"
    echo "  9. Run full diagnostic"
    echo ""
    echo -e "${BOLD}Command:${NC} ./scripts/wizards/debug-helper.sh"
    echo ""

    read -p "$(echo -e ${CYAN}Open debug helper? [y/N]:${NC} )" open_debug

    if [[ "$open_debug" = "y" || "$open_debug" = "Y" ]]; then
        echo ""
        ./scripts/wizards/debug-helper.sh || true
        echo ""
    fi

    wait_for_enter

    print_step "6.2" "Operational Runbooks"

    echo "Detailed runbooks for common issues:"
    echo ""
    echo "  • docs/runbooks/worker-failure.md"
    echo "  • docs/runbooks/daemon-failure.md"
    echo "  • docs/runbooks/token-budget-exhaustion.md"
    echo "  • docs/runbooks/circuit-breaker-tripped.md"
    echo "  • docs/runbooks/performance-troubleshooting.md"
    echo "  • docs/runbooks/emergency-recovery.md"
    echo ""
    print_info "Use 'cat docs/runbooks/<name>.md' to view"

    wait_for_enter
}

# Lesson 7: Self-Healing System
lesson_selfhealing() {
    print_header "Lesson 7: The Self-Healing System"

    print_step "7.1" "Autonomous Recovery"

    echo "Commit-Relay includes five self-healing subsystems:"
    echo ""
    echo -e "${BOLD}1. Heartbeat Monitoring${NC}"
    echo "   • Tracks worker health every 30 seconds"
    echo "   • Detects stuck or unresponsive workers"
    echo "   • Health scoring (0-100)"
    echo ""
    echo -e "${BOLD}2. Zombie Detection & Cleanup${NC}"
    echo "   • Identifies zombie workers (no heartbeat >5 min)"
    echo "   • Automatic cleanup and token recovery"
    echo "   • Prevents resource leaks"
    echo ""
    echo -e "${BOLD}3. Automatic Worker Restart${NC}"
    echo "   • Restarts failed workers automatically"
    echo "   • Exponential backoff (prevent restart loops)"
    echo "   • Circuit breaker protection"
    echo ""
    echo -e "${BOLD}4. Failure Pattern Detection${NC}"
    echo "   • Analyzes worker failures"
    echo "   • Detects patterns (resource, timeout, config, dependency, code)"
    echo "   • Confidence scoring"
    echo ""
    echo -e "${BOLD}5. Auto-Fix Framework${NC}"
    echo "   • Applies automatic fixes for known patterns"
    echo "   • 8 built-in fixes"
    echo "   • Safety scoring before application"
    echo ""

    wait_for_enter

    print_step "7.2" "Self-Healing in Action"

    echo "Example self-healing workflow:"
    echo ""
    echo "  1. Worker fails to send heartbeat"
    echo "  2. Heartbeat monitor detects (>5 min threshold)"
    echo "  3. Worker marked as zombie"
    echo "  4. Zombie cleanup daemon archives worker"
    echo "  5. Token budget recovered"
    echo "  6. Failure pattern daemon analyzes cause"
    echo "  7. Pattern detected: 'timeout'"
    echo "  8. Worker restart daemon attempts restart"
    echo "  9. Auto-fix applies timeout increase"
    echo " 10. Worker restarts successfully"
    echo ""

    print_info "See full guide: docs/runbooks/self-healing-system.md"

    wait_for_enter
}

# Lesson 8: Daily Operations
lesson_daily_ops() {
    print_header "Lesson 8: Daily Operations"

    print_step "8.1" "Morning Checklist"

    echo "Daily health check (10-15 minutes):"
    echo ""
    echo -e "${BOLD}1. Check Daemons (2 min)${NC}"
    echo "   ./scripts/wizards/daemon-control.sh"
    echo "   → Health check option"
    echo ""
    echo -e "${BOLD}2. Review Token Budget (2 min)${NC}"
    echo "   cat coordination/token-budget.json | jq ."
    echo "   → Should be >30% available"
    echo ""
    echo -e "${BOLD}3. Check Worker Health (3 min)${NC}"
    echo "   ./scripts/dashboards/worker-monitor.sh"
    echo "   → Look for stuck or zombie workers"
    echo ""
    echo -e "${BOLD}4. Review Task Queue (2 min)${NC}"
    echo "   ./scripts/dashboards/task-queue-monitor.sh"
    echo "   → Check for old queued tasks"
    echo ""
    echo -e "${BOLD}5. Check Recent Alerts (2 min)${NC}"
    echo "   cat coordination/health-alerts.json | jq '.alerts[-10:]'"
    echo "   → Address any critical alerts"
    echo ""

    wait_for_enter

    print_step "8.2" "Weekly Maintenance"

    echo "Weekly tasks (30 minutes):"
    echo ""
    echo "  □ Archive large log files (>50MB)"
    echo "  □ Trim JSONL event logs (keep last 10K lines)"
    echo "  □ Review failure patterns"
    echo "  □ Review auto-fix success rate"
    echo "  □ Check disk space usage"
    echo "  □ Review performance metrics"
    echo ""

    print_info "See detailed checklist: docs/runbooks/daily-operations.md"

    wait_for_enter
}

# Tutorial Complete
show_completion() {
    print_header "Tutorial Complete! 🎉"

    echo ""
    echo -e "${BOLD}${GREEN}Congratulations!${NC} You've completed the Commit-Relay tutorial."
    echo ""
    echo -e "${BOLD}You learned:${NC}"
    echo ""
    print_success "Commit-Relay architecture and components"
    print_success "How to manage daemons"
    print_success "Creating and tracking tasks"
    print_success "Spawning and monitoring workers"
    print_success "Using dashboards and monitoring tools"
    print_success "Troubleshooting with debug tools"
    print_success "Understanding the self-healing system"
    print_success "Daily operations and maintenance"
    echo ""

    echo -e "${BOLD}Next Steps:${NC}"
    echo ""
    echo "  1. Explore the command cheatsheet:"
    echo "     cat docs/CHEATSHEET.md"
    echo ""
    echo "  2. Read the quick start guide:"
    echo "     cat docs/QUICK-START.md"
    echo ""
    echo "  3. Review operational runbooks:"
    echo "     ls docs/runbooks/"
    echo ""
    echo "  4. Try creating a real task:"
    echo "     ./scripts/wizards/create-task.sh"
    echo ""
    echo "  5. Monitor your system:"
    echo "     ./scripts/dashboards/system-live.sh"
    echo ""

    echo -e "${BOLD}${CYAN}Resources:${NC}"
    echo ""
    echo "  📖 Documentation:  docs/"
    echo "  🛠️  Wizards:        scripts/wizards/"
    echo "  📊 Dashboards:     scripts/dashboards/"
    echo "  📋 Runbooks:       docs/runbooks/"
    echo "  🌐 Web Dashboard:  http://localhost:3000"
    echo ""

    echo -e "${BOLD}Thank you for learning Commit-Relay!${NC}"
    echo ""
}

# Main tutorial flow
main() {
    show_welcome
    lesson_architecture
    lesson_daemons
    lesson_tasks
    lesson_workers
    lesson_dashboards
    lesson_troubleshooting
    lesson_selfhealing
    lesson_daily_ops
    show_completion
}

# Run tutorial
main
