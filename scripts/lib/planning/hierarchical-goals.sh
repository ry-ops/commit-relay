#!/bin/bash
# Hierarchical Goal Decomposition
# Phase 5 Item #59: Nested task hierarchies with parent-child relationships

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
}

# Goals directory
GOALS_DIR="$COMMIT_RELAY_HOME/coordination/goals"
mkdir -p "$GOALS_DIR"

# Create a hierarchical goal
create_goal() {
    local goal_id="$1"
    local description="$2"
    local parent_id="${3:-}"

    local goal_file="$GOALS_DIR/${goal_id}.json"

    jq -n \
        --arg id "$goal_id" \
        --arg desc "$description" \
        --arg parent "$parent_id" \
        --arg created "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            goal_id: $id,
            description: $desc,
            parent_id: (if $parent == "" then null else $parent end),
            status: "pending",
            children: [],
            created_at: $created,
            progress: 0
        }' > "$goal_file"

    # Update parent if exists
    if [ -n "$parent_id" ]; then
        local parent_file="$GOALS_DIR/${parent_id}.json"
        if [ -f "$parent_file" ]; then
            jq --arg child "$goal_id" '.children += [$child]' "$parent_file" > "${parent_file}.tmp" && mv "${parent_file}.tmp" "$parent_file"
        fi
    fi

    echo "$goal_id"
}

# Decompose goal into subgoals
decompose_goal() {
    local goal_id="$1"
    shift
    local subgoals=("$@")

    local goal_file="$GOALS_DIR/${goal_id}.json"

    if [ ! -f "$goal_file" ]; then
        log_error "Goal not found: $goal_id"
        return 1
    fi

    for subgoal_desc in "${subgoals[@]}"; do
        local subgoal_id="${goal_id}-sub-$(date +%s%N | cut -c1-13)"
        create_goal "$subgoal_id" "$subgoal_desc" "$goal_id"
        log_info "Created subgoal: $subgoal_id"
    done

    # Update parent status
    jq '.status = "in_progress"' "$goal_file" > "${goal_file}.tmp" && mv "${goal_file}.tmp" "$goal_file"
}

# Get goal tree
get_goal_tree() {
    local goal_id="$1"
    local depth="${2:-0}"

    local goal_file="$GOALS_DIR/${goal_id}.json"

    if [ ! -f "$goal_file" ]; then
        echo '{"error": "Goal not found"}'
        return 1
    fi

    local goal=$(cat "$goal_file")
    local children=$(echo "$goal" | jq -r '.children[]' 2>/dev/null || true)

    # Recursively get children
    local children_tree='[]'
    for child_id in $children; do
        local child_tree=$(get_goal_tree "$child_id" $((depth + 1)))
        children_tree=$(echo "$children_tree" | jq --argjson c "$child_tree" '. + [$c]')
    done

    echo "$goal" | jq --argjson children "$children_tree" --argjson depth "$depth" \
        '. + {children_tree: $children, depth: $depth}'
}

# Update goal progress (propagates to parents)
update_progress() {
    local goal_id="$1"
    local progress="$2"

    local goal_file="$GOALS_DIR/${goal_id}.json"

    if [ ! -f "$goal_file" ]; then
        return 1
    fi

    # Update this goal
    jq --argjson progress "$progress" '.progress = $progress' "$goal_file" > "${goal_file}.tmp" && mv "${goal_file}.tmp" "$goal_file"

    # Mark complete if 100%
    if [ "$progress" -ge 100 ]; then
        jq '.status = "completed"' "$goal_file" > "${goal_file}.tmp" && mv "${goal_file}.tmp" "$goal_file"
    fi

    # Propagate to parent
    local parent_id=$(jq -r '.parent_id // empty' "$goal_file")
    if [ -n "$parent_id" ]; then
        recalculate_parent_progress "$parent_id"
    fi
}

# Recalculate parent progress from children
recalculate_parent_progress() {
    local parent_id="$1"
    local parent_file="$GOALS_DIR/${parent_id}.json"

    if [ ! -f "$parent_file" ]; then
        return 1
    fi

    local children=$(jq -r '.children[]' "$parent_file" 2>/dev/null || true)
    local total_progress=0
    local child_count=0

    for child_id in $children; do
        local child_file="$GOALS_DIR/${child_id}.json"
        if [ -f "$child_file" ]; then
            local child_progress=$(jq -r '.progress' "$child_file")
            total_progress=$((total_progress + child_progress))
            child_count=$((child_count + 1))
        fi
    done

    if [ "$child_count" -gt 0 ]; then
        local avg_progress=$((total_progress / child_count))
        update_progress "$parent_id" "$avg_progress"
    fi
}

# Get all root goals
get_root_goals() {
    local goals='[]'

    for goal_file in "$GOALS_DIR"/*.json; do
        [ -f "$goal_file" ] || continue

        local parent=$(jq -r '.parent_id // "null"' "$goal_file")
        if [ "$parent" = "null" ]; then
            local goal=$(cat "$goal_file")
            goals=$(echo "$goals" | jq --argjson g "$goal" '. + [$g]')
        fi
    done

    echo "$goals" | jq 'sort_by(.created_at) | reverse'
}

# Export functions
export -f create_goal
export -f decompose_goal
export -f get_goal_tree
export -f update_progress
export -f get_root_goals

# CLI
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        create)
            create_goal "$2" "$3" "${4:-}"
            ;;
        decompose)
            shift
            decompose_goal "$@"
            ;;
        tree)
            get_goal_tree "$2"
            ;;
        progress)
            update_progress "$2" "$3"
            ;;
        roots)
            get_root_goals
            ;;
        *)
            echo "Hierarchical Goal Decomposition"
            echo "Usage: hierarchical-goals.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  create <id> <description> [parent_id]"
            echo "  decompose <goal_id> <subgoal1> [subgoal2] ..."
            echo "  tree <goal_id>                Get goal tree"
            echo "  progress <goal_id> <pct>      Update progress"
            echo "  roots                         Get root goals"
            ;;
    esac
fi
