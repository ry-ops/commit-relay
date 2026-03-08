#!/bin/bash

################################################################################
# CI/CD Master Agent
#
# Role: Continuous Integration/Continuous Deployment automation
# Responsibilities:
#   - Build automation and orchestration
#   - Test suite execution and coordination
#   - Deployment strategy implementation
#   - Release management and versioning
#   - Pipeline optimization and monitoring
#   - Environment management
#   - Rollback coordination
#
# ASI Implementation:
#   - Learns from past deployment patterns
#   - Improves pipeline efficiency based on metrics
#   - Builds knowledge of deployment strategies
#
# MoE Implementation:
#   - Specializes in CI/CD workflows
#   - Spawns specialized workers for build/test/deploy stages
#   - Coordinates with Development and Security Masters
#
# RAG Implementation:
#   - Retrieves successful deployment patterns
#   - References environment configurations
#   - Learns from pipeline performance data
################################################################################

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"

# Master identity
MASTER_ID="cicd"
MASTER_NAME="CI/CD Master"
MASTER_CONTEXT_DIR="$SCRIPT_DIR/../coordination/masters/cicd"
MASTER_KB_DIR="$MASTER_CONTEXT_DIR/knowledge-base"
MASTER_WORKERS_DIR="$MASTER_CONTEXT_DIR/workers"

# Initialization
init_cicd_master() {
    log_section "Initializing $MASTER_NAME"

    # Create context structure
    mkdir -p "$MASTER_CONTEXT_DIR"/{context,knowledge-base,workers,handoffs}

    # Initialize master state
    local state_file="$MASTER_CONTEXT_DIR/context/master-state.json"
    if [ ! -f "$state_file" ]; then
        cat > "$state_file" <<EOF
{
  "master_id": "$MASTER_ID",
  "master_name": "$MASTER_NAME",
  "initialized_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "session_id": "$(uuidgen)",
  "status": "initializing",
  "expertise": {
    "build_tools": ["npm", "docker", "webpack", "rollup", "esbuild"],
    "test_frameworks": ["jest", "mocha", "pytest", "cypress", "playwright"],
    "deployment_platforms": ["aws", "vercel", "netlify", "docker", "kubernetes"],
    "specializations": [
      "build_automation",
      "test_orchestration",
      "deployment_strategies",
      "release_management",
      "pipeline_optimization"
    ]
  },
  "workforce_stream": {
    "stream_id": "stream-d",
    "stream_name": "CI/CD Pipeline",
    "priority": 1,
    "max_workers": 5,
    "active_workers": 0
  },
  "active_workers": [],
  "completed_tasks": 0,
  "tokens_used": 0,
  "performance_metrics": {
    "pipelines_executed": 0,
    "builds_succeeded": 0,
    "builds_failed": 0,
    "deployments_completed": 0,
    "deployments_failed": 0,
    "tests_executed": 0,
    "avg_pipeline_duration_minutes": 0,
    "success_rate": 0,
    "deployment_success_rate": 0
  }
}
EOF
        log_success "Created master state file"
    fi

    # Initialize knowledge base
    local kb_index="$MASTER_KB_DIR/index.json"
    if [ ! -f "$kb_index" ]; then
        cat > "$kb_index" <<EOF
{
  "knowledge_base_id": "cicd-kb",
  "created_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "categories": {
    "deployment_patterns": {
      "description": "Successful deployment strategies and patterns",
      "entries": []
    },
    "pipeline_optimizations": {
      "description": "Pipeline performance improvements",
      "entries": []
    },
    "rollback_procedures": {
      "description": "Emergency rollback strategies",
      "entries": []
    },
    "environment_configs": {
      "description": "Environment-specific configurations",
      "entries": []
    },
    "build_strategies": {
      "description": "Successful build patterns and optimizations",
      "entries": []
    },
    "test_patterns": {
      "description": "Effective test execution strategies",
      "entries": []
    }
  },
  "total_entries": 0,
  "last_updated": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
        log_success "Created knowledge base index"
    fi

    # Initialize worker types registry
    local worker_types="$MASTER_KB_DIR/worker-types.json"
    if [ ! -f "$worker_types" ]; then
        cat > "$worker_types" <<EOF
{
  "worker_types": [
    {
      "type_id": "build-worker",
      "description": "Executes build automation tasks",
      "specialization": "build_automation",
      "typical_token_allocation": 12000,
      "skills": ["npm", "docker", "webpack", "compilation"]
    },
    {
      "type_id": "test-worker",
      "description": "Orchestrates test suite execution",
      "specialization": "test_orchestration",
      "typical_token_allocation": 15000,
      "skills": ["unit_tests", "integration_tests", "e2e_tests"]
    },
    {
      "type_id": "deploy-worker",
      "description": "Executes deployment strategies",
      "specialization": "deployment_execution",
      "typical_token_allocation": 18000,
      "skills": ["deployment_strategies", "infrastructure", "monitoring"]
    },
    {
      "type_id": "release-worker",
      "description": "Manages release processes",
      "specialization": "release_management",
      "typical_token_allocation": 10000,
      "skills": ["versioning", "changelogs", "tagging", "publishing"]
    },
    {
      "type_id": "pipeline-optimizer",
      "description": "Optimizes pipeline performance",
      "specialization": "pipeline_optimization",
      "typical_token_allocation": 13000,
      "skills": ["performance_tuning", "caching", "parallelization"]
    }
  ],
  "last_updated": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
        log_success "Created worker types registry"
    fi

    update_master_state "status" "active"
    log_success "$MASTER_NAME initialized successfully"
}

# Process assigned tasks
process_assigned_tasks() {
    log_section "Processing Assigned Tasks"

    # Check for handoffs from Coordinator
    local handoffs_dir="$SCRIPT_DIR/../coordination/masters/coordinator/handoffs"
    if [ ! -d "$handoffs_dir" ]; then
        log_info "Coordinator handoffs directory not found"
        return 0
    fi

    local pending_handoffs=$(find "$handoffs_dir" -name "to-${MASTER_ID}-*.json" 2>/dev/null | grep -v "\.processed$" || true)

    if [ -z "$pending_handoffs" ]; then
        log_info "No pending handoffs"
        return 0
    fi

    echo "$pending_handoffs" | while read -r handoff_file; do
        process_handoff "$handoff_file"
    done
}

# Process a handoff from Coordinator
process_handoff() {
    local handoff_file="$1"
    log_info "Processing handoff: $(basename "$handoff_file")"

    local task_id=$(jq -r '.task_id' "$handoff_file")
    local task_data=$(jq -r '.task_data' "$handoff_file")
    local task_type=$(echo "$task_data" | jq -r '.type')

    # Select appropriate worker type based on task
    local worker_type=$(select_worker_type "$task_type" "$task_data")

    # Spawn worker for this task
    spawn_cicd_worker "$task_id" "$worker_type" "$task_data"

    # Mark handoff as processed
    mv "$handoff_file" "${handoff_file}.processed"
}

# MoE: Select appropriate worker type for task
select_worker_type() {
    local task_type="$1"
    local task_data="$2"

    local worker_type="build-worker" # default

    # Match task to worker specialization
    case "$task_type" in
        *build*|*compile*|*bundle*)
            worker_type="build-worker"
            ;;
        *test*|*spec*|*e2e*)
            worker_type="test-worker"
            ;;
        *deploy*|*release*|*publish*)
            # Further distinguish between deploy and release
            if [[ "$task_type" == *"release"* ]] || [[ "$task_type" == *"version"* ]]; then
                worker_type="release-worker"
            else
                worker_type="deploy-worker"
            fi
            ;;
        *optimize*|*pipeline*|*performance*)
            worker_type="pipeline-optimizer"
            ;;
    esac

    log_info "Selected worker type: $worker_type for task type: $task_type"
    echo "$worker_type"
}

# Spawn a CI/CD worker
spawn_cicd_worker() {
    local task_id="$1"
    local worker_type="$2"
    local task_data="$3"

    local worker_id="cicd-worker-$(uuidgen | cut -d'-' -f1)"
    log_section "Spawning CI/CD Worker: $worker_id"

    # Get worker type configuration
    local worker_types="$MASTER_KB_DIR/worker-types.json"
    local worker_config=$(jq --arg type "$worker_type" '.worker_types[] | select(.type_id == $type)' "$worker_types")
    local token_allocation=$(echo "$worker_config" | jq -r '.typical_token_allocation')

    # Create worker spec with rich context (RAG: augment with knowledge)
    local worker_spec_dir="$SCRIPT_DIR/../coordination/worker-specs/active"
    mkdir -p "$worker_spec_dir"

    local worker_spec="$worker_spec_dir/${worker_id}.json"
    cat > "$worker_spec" <<EOF
{
  "worker_id": "$worker_id",
  "worker_type": "$worker_type",
  "parent_master": "$MASTER_ID",
  "task_id": "$task_id",
  "task_data": $task_data,
  "workforce_stream": "stream-d",
  "context": {
    "master_session": "$(jq -r '.session_id' "$MASTER_CONTEXT_DIR/context/master-state.json")",
    "expertise_area": "$(echo "$worker_config" | jq -r '.specialization')",
    "skills_required": $(echo "$worker_config" | jq -r '.skills'),
    "knowledge_base_refs": {
      "deployment_patterns": "$MASTER_KB_DIR/deployment-patterns.jsonl",
      "pipeline_optimizations": "$MASTER_KB_DIR/pipeline-optimizations.json",
      "environment_configs": "$MASTER_KB_DIR/environment-configs.json"
    }
  },
  "resources": {
    "token_allocation": $token_allocation,
    "time_limit_minutes": 90
  },
  "status": "pending",
  "created_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "created_by": "$MASTER_ID"
}
EOF

    # Register worker in master's context
    register_worker "$worker_id" "$worker_type"

    # Update task status
    update_task_status "$task_id" "worker_spawned" "{\"worker_id\": \"$worker_id\", \"worker_type\": \"$worker_type\"}"

    log_success "Spawned worker $worker_id for task $task_id"
    log_event "worker_spawned" "{\"worker_id\": \"$worker_id\", \"task_id\": \"$task_id\", \"master\": \"$MASTER_ID\", \"stream\": \"stream-d\"}"
}

# Register worker in master's context
register_worker() {
    local worker_id="$1"
    local worker_type="$2"

    local state_file="$MASTER_CONTEXT_DIR/context/master-state.json"
    local worker_entry=$(jq -nc \
        --arg id "$worker_id" \
        --arg type "$worker_type" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{worker_id: $id, worker_type: $type, spawned_at: $ts, status: "active"}')

    local updated=$(jq --argjson worker "$worker_entry" '.active_workers += [$worker]' "$state_file")
    echo "$updated" > "$state_file"

    log_info "Registered worker $worker_id in master context"
}

# Update master state
update_master_state() {
    local key="$1"
    local value="$2"

    local state_file="$MASTER_CONTEXT_DIR/context/master-state.json"
    local updated=$(jq --arg key "$key" --arg val "$value" '.[$key] = $val' "$state_file")
    echo "$updated" > "$state_file"
}

# Main execution
main() {
    log_section "Starting $MASTER_NAME"

    # Initialize if needed
    if [ ! -f "$MASTER_CONTEXT_DIR/context/master-state.json" ]; then
        init_cicd_master
    else
        log_info "$MASTER_NAME already initialized, loading state..."
        update_master_state "status" "active"
        update_master_state "last_started" "$(date +%Y-%m-%dT%H:%M:%S%z)"
    fi

    # Process assigned tasks
    process_assigned_tasks

    # Update final state
    update_master_state "status" "idle"
    update_master_state "last_run" "$(date +%Y-%m-%dT%H:%M:%S%z)"

    log_success "$MASTER_NAME completed successfully"
}

# Execute
main "$@"
