#!/bin/bash
# scripts/lib/git-automation.sh
# Git automation library for commit-relay workers
# Provides automatic commit, push, and PR creation capabilities

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Generate context-aware commit message
# Usage: generate_commit_message <worker_type> <task_id> <description> [files_changed]
generate_commit_message() {
    local worker_type="$1"
    local task_id="$2"
    local description="$3"
    local files_changed="${4:-}"

    # Determine commit type based on worker type
    local commit_type=""
    case "$worker_type" in
        implementation-worker|development-worker)
            commit_type="feat"
            ;;
        fix-worker|bugfix-worker)
            commit_type="fix"
            ;;
        test-worker)
            commit_type="test"
            ;;
        documentation-worker|docs-worker)
            commit_type="docs"
            ;;
        refactor-worker)
            commit_type="refactor"
            ;;
        security-*-worker)
            commit_type="security"
            ;;
        build-worker|deploy-worker)
            commit_type="build"
            ;;
        dashboard-update-worker)
            commit_type="chore"
            ;;
        *)
            commit_type="chore"
            ;;
    esac

    # Get file count if provided
    local file_info=""
    if [ -n "$files_changed" ]; then
        local file_count=$(echo "$files_changed" | wc -l | tr -d ' ')
        file_info=" ($file_count files)"
    fi

    # Build commit message
    cat <<EOF
$commit_type: $description

Task: $task_id
Worker: $worker_type$file_info
Autonomous: commit-relay CI/CD

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
}

# Validate that changes are safe to commit
# Usage: validate_changes
validate_changes() {
    local repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"

    if [ -z "$repo_root" ]; then
        echo -e "${RED}ERROR: Not in a git repository${NC}" >&2
        return 1
    fi

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        # Changes exist - this is expected
        return 0
    else
        echo -e "${YELLOW}WARNING: No changes detected to commit${NC}" >&2
        return 1
    fi
}

# Check for files that should never be committed
# Usage: check_sensitive_files <files>
check_sensitive_files() {
    local files="$1"
    local sensitive_patterns=(
        "\.env$"
        "\.env\."
        "credentials"
        "secrets"
        "id_rsa"
        "id_ed25519"
        "\.pem$"
        "\.key$"
        "password"
        "api[_-]?key"
    )

    local found_sensitive=false
    for pattern in "${sensitive_patterns[@]}"; do
        if echo "$files" | grep -iE "$pattern" >/dev/null 2>&1; then
            echo -e "${RED}ERROR: Detected sensitive file matching pattern: $pattern${NC}" >&2
            echo "$files" | grep -iE "$pattern" >&2
            found_sensitive=true
        fi
    done

    if [ "$found_sensitive" = "true" ]; then
        return 1
    fi

    return 0
}

# Smart git add - adds files while respecting .gitignore
# Usage: smart_git_add <file_patterns...>
smart_git_add() {
    local patterns=("$@")

    if [ ${#patterns[@]} -eq 0 ]; then
        echo -e "${YELLOW}No file patterns provided, adding all changes${NC}"
        git add -A
        return $?
    fi

    local files_added=0
    for pattern in "${patterns[@]}"; do
        if git add "$pattern" 2>/dev/null; then
            files_added=$((files_added + 1))
        fi
    done

    if [ $files_added -eq 0 ]; then
        echo -e "${YELLOW}No files matched patterns, adding all changes${NC}"
        git add -A
    fi

    return 0
}

# Automatic commit and push workflow for workers
# Usage: auto_commit_worker_changes <worker_type> <task_id> <description> [file_patterns...]
auto_commit_worker_changes() {
    local worker_type="$1"
    local task_id="$2"
    local description="$3"
    shift 3
    local file_patterns=("$@")

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Autonomous Git Workflow${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Validate we're in a git repo with changes
    if ! validate_changes; then
        echo -e "${YELLOW}No changes to commit, skipping git workflow${NC}"
        return 0
    fi

    # Smart add files
    echo -e "${BLUE}📁 Adding files to staging area...${NC}"
    if ! smart_git_add "${file_patterns[@]}"; then
        echo -e "${RED}ERROR: Failed to add files${NC}" >&2
        return 1
    fi

    # Get list of staged files
    local staged_files=$(git diff --cached --name-only)
    if [ -z "$staged_files" ]; then
        echo -e "${YELLOW}No files staged after git add, skipping commit${NC}"
        return 0
    fi

    echo -e "${GREEN}✓ Staged files:${NC}"
    echo "$staged_files" | sed 's/^/  /'
    echo ""

    # Check for sensitive files
    echo -e "${BLUE}🔒 Checking for sensitive files...${NC}"
    if ! check_sensitive_files "$staged_files"; then
        echo -e "${RED}ERROR: Sensitive files detected, aborting commit${NC}" >&2
        git reset HEAD >/dev/null 2>&1
        return 1
    fi
    echo -e "${GREEN}✓ No sensitive files detected${NC}"
    echo ""

    # Generate commit message
    local commit_msg=$(generate_commit_message "$worker_type" "$task_id" "$description" "$staged_files")

    # Create commit
    echo -e "${BLUE}💾 Creating commit...${NC}"
    if ! git commit -m "$commit_msg" --quiet; then
        echo -e "${RED}ERROR: Failed to create commit${NC}" >&2
        return 1
    fi

    local commit_hash=$(git rev-parse --short HEAD)
    echo -e "${GREEN}✓ Commit created: $commit_hash${NC}"
    echo ""

    # Push to remote
    echo -e "${BLUE}📤 Pushing to remote...${NC}"
    local current_branch=$(git rev-parse --abbrev-ref HEAD)

    if ! git push origin "$current_branch" --quiet 2>&1; then
        echo -e "${RED}ERROR: Failed to push to remote${NC}" >&2
        echo -e "${YELLOW}Commit created locally but not pushed${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Pushed to origin/$current_branch${NC}"
    echo ""

    # Summary
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✅ Autonomous Commit Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BLUE}Commit:${NC}  $commit_hash"
    echo -e "  ${BLUE}Branch:${NC}  $current_branch"
    echo -e "  ${BLUE}Files:${NC}   $(echo "$staged_files" | wc -l | tr -d ' ')"
    echo -e "  ${BLUE}Task:${NC}    $task_id"
    echo ""

    return 0
}

# Create a pull request (requires gh CLI)
# Usage: auto_create_pr <title> <body> [base_branch]
auto_create_pr() {
    local title="$1"
    local body="$2"
    local base_branch="${3:-main}"

    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        echo -e "${YELLOW}WARNING: gh CLI not installed, skipping PR creation${NC}" >&2
        echo -e "${YELLOW}Install: https://cli.github.com/${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}📋 Creating pull request...${NC}"

    # Create PR with gh CLI
    local pr_url=$(gh pr create --title "$title" --body "$body" --base "$base_branch" 2>&1)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Pull request created: $pr_url${NC}"
        echo "$pr_url"
        return 0
    else
        echo -e "${RED}ERROR: Failed to create PR${NC}" >&2
        echo "$pr_url" >&2
        return 1
    fi
}

# Record git operation in worker log
# Usage: record_git_operation <worker_id> <operation> <status> <details>
record_git_operation() {
    local worker_id="$1"
    local operation="$2"
    local status="$3"
    local details="$4"

    local timestamp=$(date +%Y-%m-%dT%H:%M:%S%z)
    local log_entry=$(jq -nc \
        --arg worker "$worker_id" \
        --arg op "$operation" \
        --arg status "$status" \
        --arg details "$details" \
        --arg ts "$timestamp" \
        '{
            timestamp: $ts,
            worker_id: $worker,
            operation: $op,
            status: $status,
            details: $details
        }')

    # Append to git operations log
    local log_file="coordination/git-operations.jsonl"
    echo "$log_entry" >> "$log_file"
}

# Export functions
export -f generate_commit_message
export -f validate_changes
export -f check_sensitive_files
export -f smart_git_add
export -f auto_commit_worker_changes
export -f auto_create_pr
export -f record_git_operation
