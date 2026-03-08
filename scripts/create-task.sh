#!/bin/bash
# scripts/create-task.sh
# Task Management CLI - Easy task creation for commit-relay
# Supports both interactive mode and command-line mode

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"
source "$SCRIPT_DIR/lib/access-check.sh"

# Colors for interactive mode
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
TASK_TYPE=""
REPOSITORY=""
PRIORITY="high"
BRANCH="main"
DESCRIPTION=""
SCAN_TYPES='["dependencies", "static-analysis", "secrets"]'
BATCH_FILE=""
INTERACTIVE=false

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Task Management CLI for Commit-Relay

MODES:
  Interactive:  $0                           (no arguments)
  CLI:          $0 --type TYPE --repo REPO [OPTIONS]
  Batch:        $0 --batch FILE

OPTIONS:
  --type TYPE              Task type (security-scan, security-fix, development, catalog)
  --repo REPO              Repository (e.g., ry-ops/mcp-server-unifi)
  --priority PRIORITY      Priority: critical, high, medium, low (default: high)
  --branch BRANCH          Branch name (default: main)
  --description DESC       Task description
  --scan-types TYPES       Scan types as JSON array (default: ["dependencies", "static-analysis", "secrets"])
  --batch FILE             Process tasks from JSON file
  -h, --help               Show this help message

EXAMPLES:
  # Interactive mode
  $0

  # Quick security scan
  $0 --type security-scan --repo ry-ops/mcp-server-unifi

  # Security scan with custom description
  $0 --type security-scan \\
     --repo ry-ops/n8n-mcp-server \\
     --priority critical \\
     --description "Weekly vulnerability scan"

  # Development task
  $0 --type development \\
     --repo ry-ops/commit-relay \\
     --description "Add new feature: task scheduling"

  # Batch processing
  $0 --batch tasks.json

TASK TYPES:
  security-scan    - Run security scans (dependencies, static-analysis, secrets)
  security-fix     - Apply security fixes to vulnerabilities
  development      - Development tasks (features, bugs, refactoring)
  catalog          - Repository discovery and cataloging

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        --type)
            TASK_TYPE="$2"
            shift 2
            ;;
        --repo|--repository)
            REPOSITORY="$2"
            shift 2
            ;;
        --priority)
            PRIORITY="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --description)
            DESCRIPTION="$2"
            shift 2
            ;;
        --scan-types)
            SCAN_TYPES="$2"
            shift 2
            ;;
        --batch)
            BATCH_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Interactive mode if no arguments
if [ -z "$TASK_TYPE" ] && [ -z "$BATCH_FILE" ]; then
    INTERACTIVE=true
fi

# Generate next task ID
generate_task_id() {
    cd "$COMMIT_RELAY_HOME"

    # Find highest task number from unique IDs
    HIGHEST=$(jq -r '.tasks[].id' coordination/task-queue.json | \
              sort -u | \
              grep -o '[0-9]\+$' | \
              sed 's/^0*//' | \
              sort -n | \
              tail -1)

    if [ -z "$HIGHEST" ]; then
        HIGHEST=0
    fi

    NEXT=$((HIGHEST + 1))
    printf "task-%03d" "$NEXT"
}

# Validate repository exists (optional check via GitHub API)
validate_repository() {
    local repo=$1

    # Basic format check
    if ! echo "$repo" | grep -q '^[a-zA-Z0-9_-]\+/[a-zA-Z0-9_.-]\+$'; then
        echo "Invalid repository format. Expected: owner/repo"
        return 1
    fi

    # Optional: Check if repo exists via gh CLI
    if command -v gh &> /dev/null; then
        if ! gh repo view "$repo" &> /dev/null; then
            echo "Warning: Repository $repo not found or not accessible"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi

    return 0
}

# Validate task type
validate_task_type() {
    local type=$1
    case "$type" in
        security-scan|security-fix|development|catalog)
            return 0
            ;;
        *)
            echo "Invalid task type: $type"
            echo "Valid types: security-scan, security-fix, development, catalog"
            return 1
            ;;
    esac
}

# Validate priority
validate_priority() {
    local pri=$1
    case "$pri" in
        critical|high|medium|low)
            return 0
            ;;
        *)
            echo "Invalid priority: $pri"
            echo "Valid priorities: critical, high, medium, low"
            return 1
            ;;
    esac
}

# Interactive mode prompts
interactive_mode() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Commit-Relay Task Creation${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Task type
    echo -e "${CYAN}Task Type:${NC}"
    echo "  1) security-scan    - Security vulnerability scanning"
    echo "  2) security-fix     - Apply security fixes"
    echo "  3) development      - Feature/bug development"
    echo "  4) catalog          - Repository cataloging"
    echo ""
    read -p "Select type (1-4): " type_choice

    case "$type_choice" in
        1) TASK_TYPE="security-scan" ;;
        2) TASK_TYPE="security-fix" ;;
        3) TASK_TYPE="development" ;;
        4) TASK_TYPE="catalog" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac

    echo ""

    # Repository
    echo -e "${CYAN}Repository:${NC}"
    read -p "Enter repository (e.g., ry-ops/mcp-server-unifi): " REPOSITORY

    if ! validate_repository "$REPOSITORY"; then
        exit 1
    fi

    echo ""

    # Priority
    echo -e "${CYAN}Priority:${NC}"
    echo "  1) critical"
    echo "  2) high (default)"
    echo "  3) medium"
    echo "  4) low"
    echo ""
    read -p "Select priority (1-4, default=2): " priority_choice

    case "${priority_choice:-2}" in
        1) PRIORITY="critical" ;;
        2) PRIORITY="high" ;;
        3) PRIORITY="medium" ;;
        4) PRIORITY="low" ;;
        *) PRIORITY="high" ;;
    esac

    echo ""

    # Branch
    read -p "Branch (default: main): " branch_input
    BRANCH="${branch_input:-main}"

    echo ""

    # Description
    echo -e "${CYAN}Description:${NC}"
    read -p "Enter task description: " DESCRIPTION

    if [ -z "$DESCRIPTION" ]; then
        DESCRIPTION="Automated $TASK_TYPE for $REPOSITORY"
    fi

    echo ""
}

# Create task in coordination file
create_task() {
    local task_id=$(generate_task_id)
    local created_at=$(date +%Y-%m-%dT%H:%M:%S%z)

    # Permission check: Can create-task-cli write to task queue?
    check_permission "create-task-cli" "task-queue" "write" || {
        echo -e "${RED}ERROR: Permission denied to create tasks${NC}"
        exit 1
    }

    # Build context based on task type
    local context=""
    case "$TASK_TYPE" in
        security-scan)
            context=$(jq -nc \
                --arg repo "$REPOSITORY" \
                --arg branch "$BRANCH" \
                --arg desc "$DESCRIPTION" \
                --argjson scan_types "$SCAN_TYPES" \
                '{
                    repository: $repo,
                    branch: $branch,
                    description: $desc,
                    scan_types: $scan_types
                }')
            ;;
        security-fix)
            context=$(jq -nc \
                --arg repo "$REPOSITORY" \
                --arg branch "$BRANCH" \
                --arg desc "$DESCRIPTION" \
                '{
                    repository: $repo,
                    branch: $branch,
                    description: $desc,
                    vulnerabilities: []
                }')
            ;;
        development)
            context=$(jq -nc \
                --arg repo "$REPOSITORY" \
                --arg branch "$BRANCH" \
                --arg desc "$DESCRIPTION" \
                '{
                    repository: $repo,
                    branch: $branch,
                    description: $desc,
                    requirements: []
                }')
            ;;
        catalog)
            context=$(jq -nc \
                --arg repo "$REPOSITORY" \
                --arg desc "$DESCRIPTION" \
                '{
                    repository: $repo,
                    description: $desc,
                    catalog_depth: "deep"
                }')
            ;;
    esac

    # Create task object
    local task=$(jq -nc \
        --arg id "$task_id" \
        --arg title "$DESCRIPTION" \
        --arg type "$TASK_TYPE" \
        --arg priority "$PRIORITY" \
        --arg created_at "$created_at" \
        --argjson context "$context" \
        '{
            id: $id,
            title: $title,
            type: $type,
            priority: $priority,
            status: "pending",
            assigned_to: null,
            created_at: $created_at,
            created_by: "create-task-cli",
            context: $context
        }')

    # Add task to queue
    cd "$COMMIT_RELAY_HOME"
    jq --argjson task "$task" \
       '.tasks += [$task] | .updated_at = "'$(date +%Y-%m-%dT%H:%M:%S%z)'"' \
       coordination/task-queue.json > /tmp/task-queue-updated.json
    mv /tmp/task-queue-updated.json coordination/task-queue.json

    echo "$task_id"
}

# Main execution
main() {
    cd "$COMMIT_RELAY_HOME"

    # Interactive mode
    if [ "$INTERACTIVE" = "true" ]; then
        interactive_mode
    fi

    # Batch mode
    if [ -n "$BATCH_FILE" ]; then
        echo "Batch mode not yet implemented"
        exit 1
    fi

    # Validate inputs
    if ! validate_task_type "$TASK_TYPE"; then
        exit 1
    fi

    if ! validate_priority "$PRIORITY"; then
        exit 1
    fi

    if [ -z "$REPOSITORY" ]; then
        echo "Error: Repository is required"
        exit 1
    fi

    if [ -z "$DESCRIPTION" ]; then
        DESCRIPTION="Automated $TASK_TYPE for $REPOSITORY"
    fi

    # Create task
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Creating Task...${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    TASK_ID=$(create_task)

    # Commit and push
    git add coordination/task-queue.json
    git commit -m "task: create $TASK_ID - $DESCRIPTION" --quiet
    git push origin main --quiet

    # Success message
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✅ Task Created Successfully!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${CYAN}Task ID:${NC}      $TASK_ID"
    echo -e "  ${CYAN}Type:${NC}         $TASK_TYPE"
    echo -e "  ${CYAN}Repository:${NC}   $REPOSITORY"
    echo -e "  ${CYAN}Priority:${NC}     $PRIORITY"
    echo -e "  ${CYAN}Branch:${NC}       $BRANCH"
    echo -e "  ${CYAN}Status:${NC}       pending"
    echo ""
    echo -e "${YELLOW}⏱️  Daemon will launch worker within 30 seconds${NC}"
    echo ""
    echo -e "Monitor progress:"
    echo -e "  ${CYAN}Dashboard:${NC}    http://localhost:3000"
    echo -e "  ${CYAN}Logs:${NC}         tail -f agents/logs/system/worker-daemon.log"
    echo -e "  ${CYAN}Status:${NC}       ./scripts/daemon-control.sh status"
    echo ""
}

# Run main
main
