#!/bin/bash
# scripts/wizards/create-task.sh
# Interactive task creation wizard for Commit-Relay
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

# Generate task ID
generate_task_id() {
    local prefix="$1"
    local timestamp=$(date +%s%3N)
    echo "${prefix}-${timestamp}"
}

# Task creation wizard
create_task_wizard() {
    clear
    print_header "Task Creation Wizard"

    # Step 1: Task type
    print_section "Step 1: Select Task Type"

    local task_types=(
        "security - Security scan, vulnerability assessment, CVE remediation"
        "development - Feature implementation, bug fix, code refactoring"
        "inventory - Repository cataloging, documentation, dependency analysis"
        "cicd - Build, test, deployment, release workflow"
        "custom - Custom task with manual master selection"
    )

    select_option "What type of task do you want to create?" "${task_types[@]}"
    local task_type_idx=$?
    local task_type

    case $task_type_idx in
        0) task_type="security" ;;
        1) task_type="development" ;;
        2) task_type="inventory" ;;
        3) task_type="cicd" ;;
        4) task_type="custom" ;;
    esac

    # Step 2: Task description
    print_section "Step 2: Task Description"

    echo ""
    echo -e "${BOLD}Enter a clear, detailed task description:${NC}"
    echo -e "${DIM}(Include relevant keywords like 'scan', 'implement', 'fix', etc.)${NC}"
    echo ""

    local task_description
    read -p "Description: " task_description

    if [ -z "$task_description" ]; then
        print_error "Task description cannot be empty"
        return 1
    fi

    # Step 3: Priority
    print_section "Step 3: Set Priority"

    local priorities=(
        "critical - Immediate action required, system down"
        "high - Important, should be addressed soon"
        "medium - Normal priority, standard workflow"
        "low - Nice to have, no urgency"
    )

    select_option "What is the task priority?" "${priorities[@]}"
    local priority_idx=$?
    local priority

    case $priority_idx in
        0) priority="critical" ;;
        1) priority="high" ;;
        2) priority="medium" ;;
        3) priority="low" ;;
    esac

    # Step 4: Repository (optional)
    print_section "Step 4: Target Repository (Optional)"

    echo ""
    echo -e "${BOLD}Enter target repository:${NC}"
    echo -e "${DIM}(Format: owner/repo or leave blank for system-wide task)${NC}"
    echo ""

    local repository
    read -p "Repository: " repository

    # Step 5: Master selection (for custom tasks)
    local target_master=""
    if [ "$task_type" = "custom" ]; then
        print_section "Step 5: Select Target Master"

        local masters=(
            "development-master - Feature implementation, bug fixes"
            "security-master - Security scanning, CVE remediation"
            "inventory-master - Repository cataloging, documentation"
            "cicd-master - Build, deployment, release workflows"
            "dashboard-agent - Monitoring, metrics (read-only)"
        )

        select_option "Which master should handle this task?" "${masters[@]}"
        local master_idx=$?

        case $master_idx in
            0) target_master="development-master" ;;
            1) target_master="security-master" ;;
            2) target_master="inventory-master" ;;
            3) target_master="cicd-master" ;;
            4) target_master="dashboard-agent" ;;
        esac
    fi

    # Step 6: Additional metadata
    print_section "Step 6: Additional Metadata (Optional)"

    echo ""
    echo -e "${BOLD}Tags (comma-separated):${NC}"
    echo -e "${DIM}(e.g., bug,authentication,urgent)${NC}"
    echo ""

    local tags
    read -p "Tags: " tags

    echo ""
    echo -e "${BOLD}Assigned to (user/team):${NC}"
    echo -e "${DIM}(Leave blank for auto-assignment)${NC}"
    echo ""

    local assigned_to
    read -p "Assigned to: " assigned_to

    # Step 7: Review and confirm
    print_section "Step 7: Review Task"

    local task_id=$(generate_task_id "task")

    echo ""
    echo -e "${BOLD}Task Summary:${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Task ID:${NC}      $task_id"
    echo -e "  ${BOLD}Type:${NC}         $task_type"
    echo -e "  ${BOLD}Priority:${NC}     ${priority}"
    echo -e "  ${BOLD}Description:${NC}  $task_description"
    [ -n "$repository" ] && echo -e "  ${BOLD}Repository:${NC}   $repository"
    [ -n "$target_master" ] && echo -e "  ${BOLD}Master:${NC}       $target_master"
    [ -n "$tags" ] && echo -e "  ${BOLD}Tags:${NC}         $tags"
    [ -n "$assigned_to" ] && echo -e "  ${BOLD}Assigned to:${NC}  $assigned_to"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    read -p "$(echo -e ${BOLD}Create this task? [y/N]:${NC} )" confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warning "Task creation cancelled"
        return 0
    fi

    # Step 8: Create task file
    print_section "Step 8: Creating Task"

    local task_file="$COMMIT_RELAY_HOME/coordination/tasks/${task_id}.json"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Build tags array
    local tags_json="[]"
    if [ -n "$tags" ]; then
        tags_json=$(echo "$tags" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
    fi

    # Create task JSON
    cat > "$task_file" <<EOF
{
  "task_id": "$task_id",
  "task_type": "$task_type",
  "description": "$task_description",
  "priority": "$priority",
  "status": "queued",
  "created_at": "$timestamp",
  "updated_at": "$timestamp",
  "created_by": "$(whoami)",
  "repository": "${repository:-null}",
  "target_master": "${target_master:-null}",
  "tags": $tags_json,
  "assigned_to": "${assigned_to:-null}",
  "metadata": {
    "created_via": "wizard",
    "wizard_version": "1.0"
  }
}
EOF

    print_success "Task file created: $task_file"

    # Step 9: Add to task queue
    print_info "Adding task to queue..."

    local task_queue="$COMMIT_RELAY_HOME/coordination/task-queue.json"

    # Read current queue
    if [ ! -f "$task_queue" ]; then
        # Initialize task queue if doesn't exist
        echo '{"tasks": [], "last_updated": "'$timestamp'"}' > "$task_queue"
    fi

    # Add task to queue
    local task_json=$(cat "$task_file")
    jq --argjson task "$task_json" \
       '.tasks += [$task] | .last_updated = "'$timestamp'"' \
       "$task_queue" > "${task_queue}.tmp"

    mv "${task_queue}.tmp" "$task_queue"

    print_success "Task added to queue"

    # Step 10: Log event
    local event_log="$COMMIT_RELAY_HOME/coordination/dashboard-events.jsonl"

    cat >> "$event_log" <<EOF
{"event_type":"task_created","task_id":"$task_id","priority":"$priority","task_type":"$task_type","timestamp":"$timestamp","created_by":"$(whoami)","source":"wizard"}
EOF

    print_success "Task creation logged"

    # Step 11: Show next steps
    print_section "Next Steps"

    echo ""
    print_info "Task created successfully!"
    echo ""
    echo -e "${BOLD}What happens next?${NC}"
    echo ""
    echo "  1. The Coordinator daemon will pick up this task"
    if [ -z "$target_master" ]; then
        echo "  2. MoE router will analyze and route to appropriate master"
    else
        echo "  2. Task will be routed to: $target_master"
    fi
    echo "  3. Master will spawn appropriate worker to execute task"
    echo "  4. Monitor progress in dashboard or task queue"
    echo ""

    print_info "Monitor task status:"
    echo "  - Dashboard:   ./scripts/dashboards/system-live.sh"
    echo "  - Task queue:  ./scripts/dashboards/task-queue-monitor.sh"
    echo "  - Task file:   cat $task_file | jq ."
    echo ""

    # Option to create another task
    echo ""
    read -p "$(echo -e ${BOLD}Create another task? [y/N]:${NC} )" another

    if [[ "$another" = "y" || "$another" = "Y" ]]; then
        create_task_wizard
    fi
}

# Quick task creation (non-interactive)
create_task_quick() {
    local description="$1"
    local priority="${2:-medium}"
    local task_type="${3:-development}"

    local task_id=$(generate_task_id "task")
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local task_file="$COMMIT_RELAY_HOME/coordination/tasks/${task_id}.json"

    cat > "$task_file" <<EOF
{
  "task_id": "$task_id",
  "task_type": "$task_type",
  "description": "$description",
  "priority": "$priority",
  "status": "queued",
  "created_at": "$timestamp",
  "updated_at": "$timestamp",
  "created_by": "$(whoami)",
  "metadata": {
    "created_via": "cli",
    "wizard_version": "1.0"
  }
}
EOF

    # Add to queue
    local task_queue="$COMMIT_RELAY_HOME/coordination/task-queue.json"
    local task_json=$(cat "$task_file")

    jq --argjson task "$task_json" \
       '.tasks += [$task] | .last_updated = "'$timestamp'"' \
       "$task_queue" > "${task_queue}.tmp"

    mv "${task_queue}.tmp" "$task_queue"

    echo "Task created: $task_id"
    echo "Task file: $task_file"
}

# Main
main() {
    if [ $# -eq 0 ]; then
        # Interactive mode
        create_task_wizard
    else
        # Quick mode
        case "$1" in
            --quick)
                if [ -z "${2:-}" ]; then
                    echo "Usage: $0 --quick \"<description>\" [priority] [task_type]"
                    echo "Example: $0 --quick \"Fix authentication bug\" high development"
                    exit 1
                fi
                create_task_quick "$2" "${3:-medium}" "${4:-development}"
                ;;
            --help|-h)
                echo "Task Creation Wizard"
                echo ""
                echo "Usage:"
                echo "  $0                    # Interactive wizard mode"
                echo "  $0 --quick \"desc\" [priority] [type]   # Quick mode"
                echo ""
                echo "Priority: critical, high, medium, low (default: medium)"
                echo "Type: security, development, inventory, cicd (default: development)"
                echo ""
                echo "Examples:"
                echo "  $0                    # Start interactive wizard"
                echo "  $0 --quick \"Scan for CVE-2024-12345\" high security"
                echo "  $0 --quick \"Implement new API endpoint\" medium development"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    fi
}

# Run wizard
main "$@"
