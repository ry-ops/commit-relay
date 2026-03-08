#!/bin/bash
# scripts/lib/task-spec-builder.sh
# Task Specification Builder - Safe task creation with validation
#
# Purpose:
# - Provide safe API for creating task specifications
# - Automatic validation before adding to queue
# - Atomic updates to task-queue.json
# - Prevents malformed tasks
#
# Usage:
#   source scripts/lib/task-spec-builder.sh
#   build_task_spec --title "Fix bug" --type "security-fix" \
#                   --priority "high" --repository "ry-ops/repo"

set -eo pipefail

# Prevent re-sourcing
if [ -n "${TASK_SPEC_BUILDER_LOADED:-}" ]; then
    return 0
fi
TASK_SPEC_BUILDER_LOADED=1

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Simple validation functions
validate_json_syntax() {
    local json_data="$1"
    echo "$json_data" | jq empty 2>/dev/null
}

safe_write_json() {
    local json_data="$1"
    local output_path="$2"

    if ! validate_json_syntax "$json_data"; then
        echo "ERROR: Invalid JSON syntax" >&2
        return 1
    fi

    local temp_file="${output_path}.tmp.$$"
    echo "$json_data" | jq -c '.' > "$temp_file" || return 1
    mv "$temp_file" "$output_path" || return 1
    return 0
}

# Generate next task ID
generate_task_id() {
    cd "$COMMIT_RELAY_HOME"

    # Find highest task number
    local highest=$(jq -r '.tasks[].id' coordination/task-queue.json 2>/dev/null | \
                   sort -u | \
                   grep -o '[0-9]\+$' | \
                   sed 's/^0*//' | \
                   sort -n | \
                   tail -1 || echo "0")

    if [ -z "$highest" ]; then
        highest=0
    fi

    local next=$((highest + 1))
    printf "task-%010d" "$next"
}

# Build task specification
# Returns: JSON string (validated)
build_task_spec() {
    local task_id=""
    local title=""
    local task_type=""
    local priority="medium"
    local repository=""
    local branch="main"
    local description=""
    local scan_types='["dependencies","static-analysis","secrets"]'
    local context_json="{}"
    local auto_generate_id=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --task-id)
                task_id="$2"
                shift 2
                ;;
            --title)
                title="$2"
                shift 2
                ;;
            --type)
                task_type="$2"
                shift 2
                ;;
            --priority)
                priority="$2"
                shift 2
                ;;
            --repository)
                repository="$2"
                shift 2
                ;;
            --branch)
                branch="$2"
                shift 2
                ;;
            --description)
                description="$2"
                shift 2
                ;;
            --scan-types)
                scan_types="$2"
                shift 2
                ;;
            --context)
                context_json="$2"
                shift 2
                ;;
            --auto-id)
                auto_generate_id=true
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Auto-generate task ID if requested
    if [ "$auto_generate_id" = "true" ]; then
        task_id=$(generate_task_id)
    fi

    # Validate required fields
    if [ -z "$task_id" ]; then
        echo "ERROR: --task-id is required (or use --auto-id)" >&2
        return 1
    fi

    if [ -z "$title" ]; then
        echo "ERROR: --title is required" >&2
        return 1
    fi

    if [ -z "$task_type" ]; then
        echo "ERROR: --type is required" >&2
        return 1
    fi

    # Validate priority
    case "$priority" in
        critical|high|medium|low) ;;
        *)
            echo "ERROR: Invalid priority: $priority" >&2
            echo "Must be: critical, high, medium, or low" >&2
            return 1
            ;;
    esac

    # Build context based on task type if not provided
    if [ "$context_json" = "{}" ] && [ -n "$repository" ]; then
        case "$task_type" in
            security-scan)
                context_json=$(jq -nc \
                    --arg repo "$repository" \
                    --arg branch "$branch" \
                    --arg desc "$description" \
                    --argjson scan_types "$scan_types" \
                    '{
                        repository: $repo,
                        branch: $branch,
                        description: $desc,
                        scan_types: $scan_types
                    }')
                ;;
            security-fix)
                context_json=$(jq -nc \
                    --arg repo "$repository" \
                    --arg branch "$branch" \
                    --arg desc "$description" \
                    '{
                        repository: $repo,
                        branch: $branch,
                        description: $desc,
                        vulnerabilities: []
                    }')
                ;;
            development)
                context_json=$(jq -nc \
                    --arg repo "$repository" \
                    --arg branch "$branch" \
                    --arg desc "$description" \
                    '{
                        repository: $repo,
                        branch: $branch,
                        description: $desc,
                        requirements: []
                    }')
                ;;
            catalog)
                context_json=$(jq -nc \
                    --arg repo "$repository" \
                    --arg desc "$description" \
                    '{
                        repository: $repo,
                        description: $desc,
                        catalog_depth: "deep"
                    }')
                ;;
        esac
    fi

    # Validate context is valid JSON
    if ! echo "$context_json" | jq empty 2>/dev/null; then
        echo "ERROR: --context is not valid JSON" >&2
        return 1
    fi

    # Build the task spec
    local created_at=$(date +%Y-%m-%dT%H:%M:%S%z)

    local task_spec=$(jq -nc \
        --arg id "$task_id" \
        --arg title "$title" \
        --arg type "$task_type" \
        --arg priority "$priority" \
        --arg created_at "$created_at" \
        --argjson context "$context_json" \
        '{
            id: $id,
            title: $title,
            type: $type,
            priority: $priority,
            status: "pending",
            assigned_to: null,
            created_at: $created_at,
            created_by: "task-spec-builder",
            context: $context
        }')

    # Validate the generated JSON
    if ! validate_json_syntax "$task_spec"; then
        echo "ERROR: Generated task spec has invalid JSON syntax" >&2
        return 1
    fi

    # Output the task spec
    echo "$task_spec"
    return 0
}

# Add task to queue (atomic operation)
add_task_to_queue() {
    local task_json="$1"
    local queue_file="${2:-coordination/task-queue.json}"

    cd "$COMMIT_RELAY_HOME"

    # Validate task JSON
    if ! validate_json_syntax "$task_json"; then
        echo "ERROR: Task JSON is invalid" >&2
        return 1
    fi

    # Validate queue file exists and is valid
    if [ ! -f "$queue_file" ]; then
        echo "ERROR: Queue file not found: $queue_file" >&2
        return 1
    fi

    if ! jq empty "$queue_file" 2>/dev/null; then
        echo "ERROR: Queue file is not valid JSON: $queue_file" >&2
        return 1
    fi

    # Create updated queue (atomic)
    local temp_queue="/tmp/task-queue-update-$$.json"
    local updated_at=$(date +%Y-%m-%dT%H:%M:%S%z)

    jq --argjson task "$task_json" \
       --arg updated_at "$updated_at" \
       '.tasks += [$task] | .updated_at = $updated_at' \
       "$queue_file" > "$temp_queue"

    # Validate updated queue
    if ! jq empty "$temp_queue" 2>/dev/null; then
        rm -f "$temp_queue"
        echo "ERROR: Updated queue is not valid JSON" >&2
        return 1
    fi

    # Atomic move
    mv "$temp_queue" "$queue_file"

    return 0
}

# Create and add task in one operation
create_task() {
    # Build task spec
    local task_spec=$(build_task_spec "$@")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Add to queue
    if ! add_task_to_queue "$task_spec"; then
        return 1
    fi

    # Return task ID
    echo "$task_spec" | jq -r '.id'
    return 0
}

# Export functions
export -f build_task_spec 2>/dev/null || true
export -f add_task_to_queue 2>/dev/null || true
export -f create_task 2>/dev/null || true
export -f generate_task_id 2>/dev/null || true

# Log that builder is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[BUILDER] Task spec builder loaded" >&2
fi
