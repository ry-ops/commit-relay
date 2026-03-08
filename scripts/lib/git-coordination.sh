#!/bin/bash
# scripts/lib/git-coordination.sh
# Multi-file commit coordination and feature branch management
# Used by CI/CD master to coordinate git operations across multiple workers

# Prevent re-sourcing
if [ -n "${GIT_COORDINATION_LIB_LOADED:-}" ]; then
    return 0
fi
GIT_COORDINATION_LIB_LOADED=1

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/git-automation.sh"

# Coordination settings
MIN_FILES_FOR_BRANCH=5  # Create feature branch if 5+ files changed
MIN_WORKERS_FOR_PR=2     # Create PR if 2+ workers contributed

# Wait for multiple workers to complete and collect their commits
# Usage: wait_for_workers <task_id> <expected_worker_count> <timeout_minutes>
wait_for_workers() {
    local task_id="$1"
    local expected_count="$2"
    local timeout_minutes="${3:-30}"
    local timeout_seconds=$((timeout_minutes * 60))
    local start_time=$(date +%s)

    echo -e "${BLUE}Waiting for $expected_count workers to complete for task $task_id...${NC}"

    local completed_workers=()

    while true; do
        # Check timeout
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -gt $timeout_seconds ]; then
            echo -e "${YELLOW}WARNING: Timeout waiting for workers${NC}"
            break
        fi

        # Count completed workers for this task
        local completed_count=0
        local git_ops_file="coordination/git-operations.jsonl"

        if [ -f "$git_ops_file" ]; then
            # Get unique workers that completed for this task
            completed_workers=($(cat "$git_ops_file" | \
                jq -r "select(.details | contains(\"$task_id\")) | .worker_id" | \
                sort -u))
            completed_count=${#completed_workers[@]}
        fi

        echo -e "${BLUE}Progress: $completed_count/$expected_count workers completed${NC}"

        if [ $completed_count -ge $expected_count ]; then
            echo -e "${GREEN}✓ All workers completed!${NC}"
            break
        fi

        # Wait before next check
        sleep 10
    done

    # Return the list of worker IDs
    echo "${completed_workers[@]}"
}

# Get all commits from workers for a specific task
# Usage: get_worker_commits <task_id>
get_worker_commits() {
    local task_id="$1"
    local git_ops_file="coordination/git-operations.jsonl"

    if [ ! -f "$git_ops_file" ]; then
        echo ""
        return
    fi

    # Extract commit hashes from git operations
    cat "$git_ops_file" | \
        jq -r "select(.details | contains(\"$task_id\")) |
               select(.details | contains(\"Commit:\")) |
               .details" | \
        grep -oE '[0-9a-f]{7,}' || echo ""
}

# Determine if feature branch is needed based on changes
# Usage: should_use_feature_branch <task_id>
should_use_feature_branch() {
    local task_id="$1"

    # Get list of all changed files from recent commits
    local commits=$(get_worker_commits "$task_id")

    if [ -z "$commits" ]; then
        return 1  # No commits, no branch needed
    fi

    # Count total files changed
    local total_files=0
    for commit in $commits; do
        local files=$(git show --name-only --format= "$commit" 2>/dev/null | wc -l)
        total_files=$((total_files + files))
    done

    # Check if we should create a feature branch
    if [ $total_files -ge $MIN_FILES_FOR_BRANCH ]; then
        echo -e "${BLUE}$total_files files changed - feature branch recommended${NC}"
        return 0
    else
        echo -e "${BLUE}$total_files files changed - direct to main${NC}"
        return 1
    fi
}

# Create feature branch for task
# Usage: create_feature_branch <task_id> <description>
create_feature_branch() {
    local task_id="$1"
    local description="$2"

    # Sanitize description for branch name
    local branch_suffix=$(echo "$description" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9]/-/g' | \
        sed 's/--*/-/g' | \
        cut -c1-40)

    local branch_name="feature/${task_id}-${branch_suffix}"

    echo -e "${BLUE}Creating feature branch: $branch_name${NC}"

    # Create and checkout branch
    git checkout -b "$branch_name" 2>/dev/null || {
        echo -e "${YELLOW}Branch $branch_name already exists, checking out${NC}"
        git checkout "$branch_name"
    }

    echo "$branch_name"
}

# Create consolidated PR from multiple worker commits
# Usage: create_consolidated_pr <task_id> <description> <worker_ids...>
create_consolidated_pr() {
    local task_id="$1"
    local description="$2"
    shift 2
    local worker_ids=("$@")

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Creating Consolidated Pull Request${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Get all commits for this task
    local commits=$(get_worker_commits "$task_id")
    local commit_count=$(echo "$commits" | wc -w)

    # Build PR body
    local pr_body="## Summary\n\n"
    pr_body+="Autonomous implementation of task **${task_id}**: ${description}\n\n"
    pr_body+="This PR was created automatically by the commit-relay CI/CD system.\n\n"
    pr_body+="### Worker Contributions\n\n"

    for worker_id in "${worker_ids[@]}"; do
        pr_body+="- ✅ **${worker_id}**\n"
    done

    pr_body+="\n### Commits\n\n"
    pr_body+="This PR consolidates **${commit_count} commits** from ${#worker_ids[@]} autonomous workers.\n\n"

    for commit in $commits; do
        local commit_msg=$(git log --format=%s -n 1 "$commit" 2>/dev/null || echo "Unknown")
        pr_body+="- \`${commit}\` ${commit_msg}\n"
    done

    pr_body+="\n### Files Changed\n\n"

    # Get unique files from all commits
    local all_files=$(for commit in $commits; do
        git show --name-only --format= "$commit" 2>/dev/null
    done | sort -u)

    local file_count=$(echo "$all_files" | wc -l)
    pr_body+="**${file_count} files** modified across all workers:\n\n"

    echo "$all_files" | head -20 | while read file; do
        pr_body+="- \`${file}\`\n"
    done

    if [ $file_count -gt 20 ]; then
        pr_body+="\n_...and $((file_count - 20)) more files_\n"
    fi

    pr_body+="\n### Testing\n\n"
    pr_body+="- [ ] Manual code review\n"
    pr_body+="- [ ] Run test suite\n"
    pr_body+="- [ ] Verify no breaking changes\n\n"
    pr_body+="---\n\n"
    pr_body+="🤖 **Generated with [Claude Code](https://claude.com/claude-code)**\n\n"
    pr_body+="_This PR was autonomously created by commit-relay CI/CD system._"

    # Create PR title
    local pr_title="feat(${task_id}): ${description}"

    # Use gh CLI to create PR
    if command -v gh &> /dev/null; then
        echo -e "${BLUE}Creating PR via GitHub CLI...${NC}"

        # Get current branch
        local current_branch=$(git rev-parse --abbrev-ref HEAD)

        # Push branch first
        git push origin "$current_branch" --quiet

        # Create PR
        echo -e "$pr_body" | gh pr create \
            --title "$pr_title" \
            --body-file - \
            --base main

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Pull request created successfully${NC}"
            return 0
        else
            echo -e "${RED}ERROR: Failed to create pull request${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}WARNING: gh CLI not installed, skipping PR creation${NC}"
        echo -e "${BLUE}To install: https://cli.github.com/${NC}"
        echo ""
        echo -e "${BLUE}PR Title:${NC} $pr_title"
        echo -e "${BLUE}PR Body:${NC}"
        echo -e "$pr_body"
        return 1
    fi
}

# Main coordination workflow
# Usage: coordinate_multi_worker_task <task_id> <description> <worker_count>
coordinate_multi_worker_task() {
    local task_id="$1"
    local description="$2"
    local expected_workers="${3:-1}"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Multi-Worker Git Coordination${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}Task:${NC}     $task_id"
    echo -e "${BLUE}Workers:${NC}  $expected_workers expected"
    echo ""

    # Wait for all workers to complete
    local completed_workers=$(wait_for_workers "$task_id" "$expected_workers" 30)
    local worker_array=($completed_workers)
    local actual_count=${#worker_array[@]}

    echo -e "${BLUE}Completed workers: ${worker_array[*]}${NC}"
    echo ""

    # Decide on branching strategy
    if [ $actual_count -ge $MIN_WORKERS_FOR_PR ]; then
        echo -e "${BLUE}Multiple workers detected - checking if feature branch needed${NC}"

        if should_use_feature_branch "$task_id"; then
            # Create feature branch and PR
            local branch=$(create_feature_branch "$task_id" "$description")

            echo -e "${GREEN}✓ Feature branch created: $branch${NC}"
            echo ""

            # Create consolidated PR
            create_consolidated_pr "$task_id" "$description" "${worker_array[@]}"
        else
            echo -e "${BLUE}Changes small enough - already pushed to main${NC}"
            echo -e "${BLUE}No PR needed${NC}"
        fi
    else
        echo -e "${BLUE}Single worker or small changes - already pushed to main${NC}"
        echo -e "${BLUE}No additional coordination needed${NC}"
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Coordination Complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Export functions
export -f wait_for_workers
export -f get_worker_commits
export -f should_use_feature_branch
export -f create_feature_branch
export -f create_consolidated_pr
export -f coordinate_multi_worker_task
