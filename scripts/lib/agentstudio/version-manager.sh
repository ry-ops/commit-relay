#!/usr/bin/env bash
#
# Version Manager Library
# Part of Q2 Week 25: Agent Versioning & Deployment
#
# Manages agent versions, deployments, and rollbacks
#

set -euo pipefail

if [[ -z "${VERSION_MANAGER_LOADED:-}" ]]; then
    readonly VERSION_MANAGER_LOADED=true
fi

# Directory setup
VERSION_DIR="${VERSION_DIR:-coordination/agentstudio/versions}"
DEPLOY_DIR="${DEPLOY_DIR:-coordination/agentstudio/deployments}"

#
# Initialize version management directories
#
init_version_manager() {
    mkdir -p "$VERSION_DIR"/{active,staged,deprecated,history}
    mkdir -p "$DEPLOY_DIR"/{development,staging,production}
    mkdir -p "$VERSION_DIR/indices"
}

#
# Get timestamp in milliseconds
#
get_timestamp_ms() {
    local ts=$(date +%s%3N 2>/dev/null)
    if [[ "$ts" =~ N$ ]]; then
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

#
# Generate version ID
#
generate_version_id() {
    local agent_id="$1"
    local version="$2"

    local hash=$(echo "${agent_id}-${version}-$(date +%s)" | shasum -a 256 | cut -c1-8)
    echo "${agent_id}-v${version}-${hash}"
}

#
# Calculate checksum of agent files
#
calculate_checksum() {
    local agent_path="$1"

    if [[ -d "$agent_path" ]]; then
        find "$agent_path" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | cut -d' ' -f1
    elif [[ -f "$agent_path" ]]; then
        shasum -a 256 "$agent_path" | cut -d' ' -f1
    else
        echo "unknown"
    fi
}

#
# Create new version
#
create_version() {
    local agent_id="$1"
    local version="$2"
    local summary="${3:-}"
    local template_id="${4:-}"

    init_version_manager

    local version_id=$(generate_version_id "$agent_id" "$version")
    local timestamp=$(get_timestamp_ms)

    # Get agent file path
    local agent_file=$(find coordination/agentstudio/registry -name "${agent_id}.json" 2>/dev/null | head -1)
    local checksum="unknown"

    if [[ -n "$agent_file" && -f "$agent_file" ]]; then
        local agent_dir=$(dirname "$agent_file")
        checksum=$(calculate_checksum "$agent_dir")
    fi

    # Create version record
    local version_file="$VERSION_DIR/active/${version_id}.json"

    cat > "$version_file" <<EOF
{
  "version_id": "$version_id",
  "agent_id": "$agent_id",
  "version": "$version",
  "status": "draft",
  "source": {
    "template_id": "$template_id",
    "commit_hash": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
    "branch": "$(git branch --show-current 2>/dev/null || echo 'unknown')",
    "checksum": "$checksum"
  },
  "configuration": {
    "parameters": {},
    "resource_limits": {
      "max_memory_mb": 256,
      "max_cpu_percent": 30,
      "max_token_budget": 50000
    },
    "dependencies": []
  },
  "deployment": {
    "environment": null,
    "deployed_at": null,
    "deployed_by": null,
    "instances": 0,
    "rollout_strategy": "immediate",
    "health_check": {
      "interval_seconds": 60,
      "timeout_seconds": 30,
      "healthy_threshold": 3,
      "unhealthy_threshold": 2
    }
  },
  "changelog": {
    "summary": "$summary",
    "changes": [],
    "breaking_changes": [],
    "migration_notes": ""
  },
  "metrics": {
    "tasks_completed": 0,
    "tasks_failed": 0,
    "success_rate": 0,
    "avg_execution_time_ms": 0,
    "p95_execution_time_ms": 0,
    "total_tokens_used": 0,
    "error_count": 0,
    "uptime_percent": 0
  },
  "rollback": null,
  "created_at": $timestamp,
  "updated_at": $timestamp,
  "created_by": "$(whoami)",
  "tags": [],
  "metadata": {}
}
EOF

    # Update index
    update_version_index "$version_id" "$agent_id" "$version"

    echo "$version_id"
}

#
# Update version index
#
update_version_index() {
    local version_id="$1"
    local agent_id="$2"
    local version="$3"

    local index_file="$VERSION_DIR/indices/by-agent.json"

    if [[ ! -f "$index_file" ]]; then
        echo "{}" > "$index_file"
    fi

    # Add version to agent's version list
    local current=$(cat "$index_file")
    local updated=$(echo "$current" | jq --arg agent "$agent_id" --arg ver "$version_id" \
        '.[$agent] = ((.[$agent] // []) + [$ver] | unique)')

    echo "$updated" > "$index_file"
}

#
# Get version by ID
#
get_version() {
    local version_id="$1"

    init_version_manager

    # Search in all directories
    for dir in active staged deprecated history; do
        local file="$VERSION_DIR/$dir/${version_id}.json"
        if [[ -f "$file" ]]; then
            cat "$file"
            return 0
        fi
    done

    echo "{\"error\": \"Version not found: $version_id\"}"
    return 1
}

#
# List versions for an agent
#
list_versions() {
    local agent_id="$1"
    local limit="${2:-10}"

    init_version_manager

    local index_file="$VERSION_DIR/indices/by-agent.json"

    if [[ ! -f "$index_file" ]]; then
        echo "[]"
        return 0
    fi

    local version_ids=$(cat "$index_file" | jq -r --arg agent "$agent_id" '.[$agent] // [] | .[]')

    local versions="[]"
    local count=0

    while IFS= read -r version_id; do
        if [[ -n "$version_id" && $count -lt $limit ]]; then
            local version_data=$(get_version "$version_id" 2>/dev/null || echo "")
            if [[ -n "$version_data" && ! "$version_data" =~ "error" ]]; then
                versions=$(echo "$versions" | jq --argjson v "$version_data" '. + [$v]')
                count=$((count + 1))
            fi
        fi
    done <<< "$version_ids"

    # Sort by created_at descending
    echo "$versions" | jq 'sort_by(.created_at) | reverse'
}

#
# Update version status
#
update_version_status() {
    local version_id="$1"
    local new_status="$2"

    init_version_manager

    # Find version file
    local version_file=""
    local current_dir=""

    for dir in active staged deprecated history; do
        if [[ -f "$VERSION_DIR/$dir/${version_id}.json" ]]; then
            version_file="$VERSION_DIR/$dir/${version_id}.json"
            current_dir="$dir"
            break
        fi
    done

    if [[ -z "$version_file" ]]; then
        echo "Error: Version not found: $version_id" >&2
        return 1
    fi

    # Update status and timestamp
    local timestamp=$(get_timestamp_ms)
    local updated=$(cat "$version_file" | jq --arg status "$new_status" --argjson ts "$timestamp" \
        '.status = $status | .updated_at = $ts')

    echo "$updated" > "$version_file"

    # Move to appropriate directory based on status
    local target_dir=""
    case "$new_status" in
        draft|testing|deployed)
            target_dir="active"
            ;;
        staged)
            target_dir="staged"
            ;;
        deprecated|rolled_back)
            target_dir="deprecated"
            ;;
    esac

    if [[ -n "$target_dir" && "$target_dir" != "$current_dir" ]]; then
        mv "$version_file" "$VERSION_DIR/$target_dir/${version_id}.json"
    fi

    echo "$version_id"
}

#
# Stage version for deployment
#
stage_version() {
    local version_id="$1"
    local environment="${2:-staging}"

    update_version_status "$version_id" "staged"

    # Update deployment info
    local version_file="$VERSION_DIR/staged/${version_id}.json"
    if [[ -f "$version_file" ]]; then
        local timestamp=$(get_timestamp_ms)
        local updated=$(cat "$version_file" | jq \
            --arg env "$environment" \
            --argjson ts "$timestamp" \
            '.deployment.environment = $env | .deployment.staged_at = $ts')
        echo "$updated" > "$version_file"
    fi

    echo "Version $version_id staged for $environment"
}

#
# Deploy version
#
deploy_version() {
    local version_id="$1"
    local environment="${2:-production}"
    local instances="${3:-1}"
    local strategy="${4:-immediate}"

    init_version_manager

    # Get version data
    local version_data=$(get_version "$version_id")
    if [[ "$version_data" =~ "error" ]]; then
        echo "Error: Version not found" >&2
        return 1
    fi

    local agent_id=$(echo "$version_data" | jq -r '.agent_id')
    local timestamp=$(get_timestamp_ms)

    # Deprecate current deployed version for this agent in this environment
    local current_deployed=$(find "$VERSION_DIR/active" -name "*.json" -exec grep -l "\"agent_id\": \"$agent_id\"" {} \; 2>/dev/null | while read f; do
        if jq -e ".status == \"deployed\" and .deployment.environment == \"$environment\"" "$f" >/dev/null 2>&1; then
            basename "$f" .json
        fi
    done | head -1)

    if [[ -n "$current_deployed" ]]; then
        update_version_status "$current_deployed" "deprecated"
    fi

    # Update version with deployment info
    update_version_status "$version_id" "deployed"

    local version_file="$VERSION_DIR/active/${version_id}.json"
    if [[ -f "$version_file" ]]; then
        local updated=$(cat "$version_file" | jq \
            --arg env "$environment" \
            --argjson ts "$timestamp" \
            --arg by "$(whoami)" \
            --argjson inst "$instances" \
            --arg strat "$strategy" \
            '.deployment.environment = $env |
             .deployment.deployed_at = $ts |
             .deployment.deployed_by = $by |
             .deployment.instances = $inst |
             .deployment.rollout_strategy = $strat')
        echo "$updated" > "$version_file"
    fi

    # Create deployment record
    local deploy_file="$DEPLOY_DIR/$environment/${agent_id}-${version_id}.json"
    mkdir -p "$(dirname "$deploy_file")"

    cat > "$deploy_file" <<EOF
{
  "deployment_id": "${agent_id}-${environment}-${timestamp}",
  "version_id": "$version_id",
  "agent_id": "$agent_id",
  "environment": "$environment",
  "deployed_at": $timestamp,
  "deployed_by": "$(whoami)",
  "instances": $instances,
  "strategy": "$strategy",
  "status": "active",
  "previous_version": "${current_deployed:-null}"
}
EOF

    echo "Deployed $version_id to $environment with $instances instance(s)"
}

#
# Rollback to previous version
#
rollback_version() {
    local agent_id="$1"
    local environment="${2:-production}"
    local reason="${3:-Manual rollback}"

    init_version_manager

    # Find current deployed version
    local current_version=""
    local current_file=""

    for file in "$VERSION_DIR/active"/*.json; do
        if [[ -f "$file" ]]; then
            local file_agent=$(jq -r '.agent_id' "$file")
            local file_status=$(jq -r '.status' "$file")
            local file_env=$(jq -r '.deployment.environment' "$file")

            if [[ "$file_agent" == "$agent_id" && "$file_status" == "deployed" && "$file_env" == "$environment" ]]; then
                current_version=$(jq -r '.version_id' "$file")
                current_file="$file"
                break
            fi
        fi
    done

    if [[ -z "$current_version" ]]; then
        echo "Error: No deployed version found for $agent_id in $environment" >&2
        return 1
    fi

    # Find previous version from deployment history
    local deploy_files=$(ls -t "$DEPLOY_DIR/$environment/${agent_id}-"*.json 2>/dev/null | head -2)
    local previous_version=""

    while IFS= read -r deploy_file; do
        if [[ -f "$deploy_file" ]]; then
            local ver=$(jq -r '.version_id' "$deploy_file")
            if [[ "$ver" != "$current_version" ]]; then
                previous_version="$ver"
                break
            fi
        fi
    done <<< "$deploy_files"

    if [[ -z "$previous_version" ]]; then
        echo "Error: No previous version to rollback to" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)

    # Mark current version as rolled back
    local updated=$(cat "$current_file" | jq \
        --argjson ts "$timestamp" \
        --arg by "$(whoami)" \
        --arg reason "$reason" \
        --arg prev "$previous_version" \
        '.status = "rolled_back" |
         .rollback = {
           "rolled_back_at": $ts,
           "rolled_back_by": $by,
           "reason": $reason,
           "previous_version": $prev
         }')
    echo "$updated" > "$current_file"
    mv "$current_file" "$VERSION_DIR/deprecated/${current_version}.json"

    # Deploy previous version
    deploy_version "$previous_version" "$environment"

    echo "Rolled back $agent_id from $current_version to $previous_version"
}

#
# Add changelog entry
#
add_changelog_entry() {
    local version_id="$1"
    local change_type="$2"
    local description="$3"
    local issue_ref="${4:-}"

    local version_data=$(get_version "$version_id")
    if [[ "$version_data" =~ "error" ]]; then
        return 1
    fi

    # Find version file
    local version_file=""
    for dir in active staged deprecated history; do
        if [[ -f "$VERSION_DIR/$dir/${version_id}.json" ]]; then
            version_file="$VERSION_DIR/$dir/${version_id}.json"
            break
        fi
    done

    if [[ -z "$version_file" ]]; then
        return 1
    fi

    local timestamp=$(get_timestamp_ms)
    local updated=$(cat "$version_file" | jq \
        --arg type "$change_type" \
        --arg desc "$description" \
        --arg ref "$issue_ref" \
        --argjson ts "$timestamp" \
        '.changelog.changes += [{"type": $type, "description": $desc, "issue_ref": $ref}] | .updated_at = $ts')

    echo "$updated" > "$version_file"
}

#
# Tag version
#
tag_version() {
    local version_id="$1"
    local tag="$2"

    local version_file=""
    for dir in active staged deprecated history; do
        if [[ -f "$VERSION_DIR/$dir/${version_id}.json" ]]; then
            version_file="$VERSION_DIR/$dir/${version_id}.json"
            break
        fi
    done

    if [[ -z "$version_file" ]]; then
        echo "Error: Version not found" >&2
        return 1
    fi

    local timestamp=$(get_timestamp_ms)
    local updated=$(cat "$version_file" | jq \
        --arg tag "$tag" \
        --argjson ts "$timestamp" \
        '.tags = (.tags + [$tag] | unique) | .updated_at = $ts')

    echo "$updated" > "$version_file"
    echo "Tagged $version_id as $tag"
}

#
# Get latest version for agent
#
get_latest_version() {
    local agent_id="$1"
    local tag="${2:-}"

    local versions=$(list_versions "$agent_id" 100)

    if [[ -n "$tag" ]]; then
        # Filter by tag
        echo "$versions" | jq --arg tag "$tag" '[.[] | select(.tags | contains([$tag]))] | .[0] // null'
    else
        echo "$versions" | jq '.[0] // null'
    fi
}

#
# Compare versions
#
compare_versions() {
    local version_id_1="$1"
    local version_id_2="$2"

    local v1=$(get_version "$version_id_1")
    local v2=$(get_version "$version_id_2")

    if [[ "$v1" =~ "error" || "$v2" =~ "error" ]]; then
        echo "Error: One or both versions not found" >&2
        return 1
    fi

    cat <<EOF
{
  "version_1": {
    "version_id": $(echo "$v1" | jq '.version_id'),
    "version": $(echo "$v1" | jq '.version'),
    "status": $(echo "$v1" | jq '.status'),
    "metrics": $(echo "$v1" | jq '.metrics')
  },
  "version_2": {
    "version_id": $(echo "$v2" | jq '.version_id'),
    "version": $(echo "$v2" | jq '.version'),
    "status": $(echo "$v2" | jq '.status'),
    "metrics": $(echo "$v2" | jq '.metrics')
  },
  "comparison": {
    "success_rate_diff": $(echo "$v1" "$v2" | jq -s '.[1].metrics.success_rate - .[0].metrics.success_rate'),
    "avg_time_diff_ms": $(echo "$v1" "$v2" | jq -s '.[1].metrics.avg_execution_time_ms - .[0].metrics.avg_execution_time_ms'),
    "error_count_diff": $(echo "$v1" "$v2" | jq -s '.[1].metrics.error_count - .[0].metrics.error_count')
  }
}
EOF
}

#
# Update version metrics
#
update_version_metrics() {
    local version_id="$1"
    local tasks_completed="${2:-0}"
    local tasks_failed="${3:-0}"
    local execution_time_ms="${4:-0}"
    local tokens_used="${5:-0}"

    local version_file=""
    for dir in active staged deprecated history; do
        if [[ -f "$VERSION_DIR/$dir/${version_id}.json" ]]; then
            version_file="$VERSION_DIR/$dir/${version_id}.json"
            break
        fi
    done

    if [[ -z "$version_file" ]]; then
        return 1
    fi

    local current=$(cat "$version_file")
    local current_completed=$(echo "$current" | jq -r '.metrics.tasks_completed')
    local current_failed=$(echo "$current" | jq -r '.metrics.tasks_failed')
    local current_tokens=$(echo "$current" | jq -r '.metrics.total_tokens_used')
    local current_avg=$(echo "$current" | jq -r '.metrics.avg_execution_time_ms')

    local new_completed=$((current_completed + tasks_completed))
    local new_failed=$((current_failed + tasks_failed))
    local new_tokens=$((current_tokens + tokens_used))
    local total_tasks=$((new_completed + new_failed))

    local success_rate=0
    local new_avg=0

    if [[ $total_tasks -gt 0 ]]; then
        success_rate=$(echo "scale=4; $new_completed / $total_tasks" | bc)
    fi

    if [[ $new_completed -gt 0 ]]; then
        # Weighted average
        new_avg=$(echo "scale=2; (($current_avg * $current_completed) + ($execution_time_ms * $tasks_completed)) / $new_completed" | bc)
    fi

    local timestamp=$(get_timestamp_ms)
    local updated=$(cat "$version_file" | jq \
        --argjson comp "$new_completed" \
        --argjson fail "$new_failed" \
        --argjson rate "$success_rate" \
        --argjson avg "$new_avg" \
        --argjson tok "$new_tokens" \
        --argjson ts "$timestamp" \
        '.metrics.tasks_completed = $comp |
         .metrics.tasks_failed = $fail |
         .metrics.success_rate = $rate |
         .metrics.avg_execution_time_ms = $avg |
         .metrics.total_tokens_used = $tok |
         .updated_at = $ts')

    echo "$updated" > "$version_file"
}

# Export functions
export -f init_version_manager
export -f get_timestamp_ms
export -f generate_version_id
export -f calculate_checksum
export -f create_version
export -f get_version
export -f list_versions
export -f update_version_status
export -f stage_version
export -f deploy_version
export -f rollback_version
export -f add_changelog_entry
export -f tag_version
export -f get_latest_version
export -f compare_versions
export -f update_version_metrics
