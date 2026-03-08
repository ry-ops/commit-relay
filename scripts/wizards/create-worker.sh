#!/bin/bash
# scripts/wizards/create-worker.sh
# Interactive wizard for creating and spawning workers
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
NC='\033[0m' # No Color

# Box drawing characters
TOP_LEFT="┌"
TOP_RIGHT="┐"
BOTTOM_LEFT="└"
BOTTOM_RIGHT="┘"
HORIZONTAL="─"
VERTICAL="│"
T_DOWN="┬"
T_UP="┴"
T_RIGHT="├"
T_LEFT="┤"
CROSS="┼"

# Print functions
print_header() {
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${CYAN}Worker Creation Wizard${NC}                                ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "\n${BOLD}${MAGENTA}▶ $1${NC}"
    echo -e "${BLUE}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${HORIZONTAL}${NC}"
}

print_option() {
    echo -e "  ${GREEN}[$1]${NC} $2"
}

print_info() {
    echo -e "${CYAN}ℹ${NC}  $1"
}

print_success() {
    echo -e "${GREEN}✓${NC}  $1"
}

print_error() {
    echo -e "${RED}✗${NC}  $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

# Read user input with prompt
read_input() {
    local prompt="$1"
    local default="$2"
    local value

    if [[ -n "$default" ]]; then
        echo -ne "${YELLOW}?${NC}  ${prompt} ${BLUE}[${default}]${NC}: "
    else
        echo -ne "${YELLOW}?${NC}  ${prompt}: "
    fi

    read value

    if [[ -z "$value" && -n "$default" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Display menu and get selection
select_option() {
    local title="$1"
    shift
    local options=("$@")
    local selection

    echo -e "\n${BOLD}${title}${NC}"

    for i in "${!options[@]}"; do
        print_option "$((i+1))" "${options[$i]}"
    done

    while true; do
        read_input "Select option (1-${#options[@]})" "" selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#options[@]} )); then
            echo "${options[$((selection-1))]}"
            return 0
        else
            print_error "Invalid selection. Please choose 1-${#options[@]}"
        fi
    done
}

# Check token budget
check_token_budget() {
    local budget_file="$COMMIT_RELAY_HOME/coordination/token-budget.json"

    if [[ ! -f "$budget_file" ]]; then
        print_warning "Token budget file not found. Skipping budget check."
        return 0
    fi

    local available
    available=$(jq -r '.available // 0' "$budget_file")

    echo -e "\n${BOLD}Token Budget Status:${NC}"
    echo -e "  Available: ${GREEN}$available tokens${NC}"

    if (( available < 10000 )); then
        print_warning "Low token budget! Consider cleaning up zombie workers."
        return 1
    fi

    return 0
}

# Get worker type details
get_worker_type_info() {
    local type="$1"

    case "$type" in
        scan-worker)
            echo "scan-worker|Security scanning and vulnerability detection|70000|15min"
            ;;
        fix-worker)
            echo "fix-worker|Apply fixes and remediation|70000|20min"
            ;;
        analysis-worker)
            echo "analysis-worker|Research and investigation|50000|15min"
            ;;
        implementation-worker)
            echo "implementation-worker|Feature development and coding|100000|45min"
            ;;
        test-worker)
            echo "test-worker|Test creation and validation|70000|20min"
            ;;
        review-worker)
            echo "review-worker|Code review and quality checks|50000|15min"
            ;;
        pr-worker)
            echo "pr-worker|Pull request creation|30000|10min"
            ;;
        documentation-worker)
            echo "documentation-worker|Documentation writing|70000|20min"
            ;;
        *)
            echo "unknown|Unknown worker type|50000|15min"
            ;;
    esac
}

# Display worker spec summary
show_spec_summary() {
    local worker_type="$1"
    local task_id="$2"
    local master="$3"
    local priority="$4"
    local repo="$5"

    # Get worker type info
    IFS='|' read -r type_name description budget timeout <<< "$(get_worker_type_info "$worker_type")"

    echo -e "\n${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Worker Specification Summary${NC}                          ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Type:        ${GREEN}$worker_type${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Description: $description"
    echo -e "${BOLD}${CYAN}║${NC}  Task ID:     ${YELLOW}$task_id${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Master:      ${MAGENTA}$master${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Priority:    ${BLUE}$priority${NC}"
    if [[ -n "$repo" ]]; then
        echo -e "${BOLD}${CYAN}║${NC}  Repository:  ${CYAN}$repo${NC}"
    fi
    echo -e "${BOLD}${CYAN}║${NC}  Budget:      ${GREEN}$budget tokens${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Timeout:     ${YELLOW}$timeout${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
}

# Main wizard flow
main() {
    clear
    print_header

    print_info "This wizard will guide you through creating and spawning a worker."
    print_info "You can exit at any time by pressing Ctrl+C."

    # Step 1: Check token budget
    print_section "Step 1: Token Budget Check"
    if ! check_token_budget; then
        read_input "Continue anyway? (y/n)" "n" continue
        if [[ "$continue" != "y" ]]; then
            print_warning "Wizard cancelled by user."
            exit 0
        fi
    fi

    # Step 2: Select master agent
    print_section "Step 2: Select Master Agent"
    masters=(
        "development-master"
        "security-master"
        "inventory-master"
        "cicd-master"
        "coordinator-master"
    )
    master=$(select_option "Which master is spawning this worker?" "${masters[@]}")
    print_success "Selected master: $master"

    # Step 3: Select worker type
    print_section "Step 3: Select Worker Type"
    worker_types=(
        "scan-worker"
        "fix-worker"
        "analysis-worker"
        "implementation-worker"
        "test-worker"
        "review-worker"
        "pr-worker"
        "documentation-worker"
    )
    worker_type=$(select_option "What type of worker do you need?" "${worker_types[@]}")

    # Show worker type details
    IFS='|' read -r type_name description budget timeout <<< "$(get_worker_type_info "$worker_type")"
    print_success "Selected: $worker_type"
    print_info "Description: $description"
    print_info "Default budget: $budget tokens"
    print_info "Typical duration: $timeout"

    # Step 4: Enter task ID
    print_section "Step 4: Task Association"
    task_id=$(read_input "Enter task ID" "")
    while [[ -z "$task_id" ]]; do
        print_error "Task ID is required"
        task_id=$(read_input "Enter task ID" "")
    done
    print_success "Task ID: $task_id"

    # Step 5: Set priority
    print_section "Step 5: Set Priority"
    priorities=("critical" "high" "medium" "low")
    priority=$(select_option "Select worker priority:" "${priorities[@]}")
    print_success "Priority: $priority"

    # Step 6: Repository (optional)
    print_section "Step 6: Repository (Optional)"
    print_info "Format: owner/repo (e.g., ry-ops/commit-relay)"
    repository=$(read_input "Enter repository" "")
    if [[ -n "$repository" ]]; then
        print_success "Repository: $repository"
    else
        print_info "No repository specified"
    fi

    # Step 7: Review specification
    print_section "Step 7: Review Specification"
    show_spec_summary "$worker_type" "$task_id" "$master" "$priority" "$repository"

    # Step 8: Confirm and spawn
    print_section "Step 8: Spawn Worker"
    spawn_choice=$(read_input "Spawn this worker now? (y/n)" "y")

    if [[ "$spawn_choice" != "y" ]]; then
        print_warning "Worker not spawned. Specification saved for reference."
        echo ""
        echo "To spawn manually, run:"
        echo -e "${CYAN}$COMMIT_RELAY_HOME/scripts/spawn-worker.sh \\${NC}"
        echo -e "${CYAN}  --type $worker_type \\${NC}"
        echo -e "${CYAN}  --task-id $task_id \\${NC}"
        echo -e "${CYAN}  --master $master \\${NC}"
        echo -e "${CYAN}  --priority $priority${NC}"
        if [[ -n "$repository" ]]; then
            echo -e "${CYAN}  --repo $repository${NC}"
        fi
        exit 0
    fi

    # Build spawn command
    spawn_cmd="$COMMIT_RELAY_HOME/scripts/spawn-worker.sh"
    spawn_args=(
        "--type" "$worker_type"
        "--task-id" "$task_id"
        "--master" "$master"
        "--priority" "$priority"
    )

    if [[ -n "$repository" ]]; then
        spawn_args+=("--repo" "$repository")
    fi

    print_info "Spawning worker..."
    echo ""

    # Execute spawn command
    if "$spawn_cmd" "${spawn_args[@]}"; then
        echo ""
        print_success "${GREEN}${BOLD}Worker spawned successfully!${NC}"
        echo ""
        print_info "Check worker status with:"
        echo -e "  ${CYAN}$COMMIT_RELAY_HOME/scripts/worker-status.sh${NC}"
        echo ""
        print_info "View worker logs in:"
        echo -e "  ${CYAN}$COMMIT_RELAY_HOME/agents/logs/workers/${NC}"
        echo ""
        print_info "Monitor system with dashboard:"
        echo -e "  ${CYAN}$COMMIT_RELAY_HOME/scripts/dashboards/system-live.sh${NC}"
    else
        echo ""
        print_error "${RED}${BOLD}Failed to spawn worker!${NC}"
        print_info "Check logs for details"
        exit 1
    fi
}

# Run wizard
main "$@"
