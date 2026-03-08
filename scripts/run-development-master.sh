#!/bin/bash

################################################################################
# Development Master Agent
#
# Role: Code development, implementation, and technical improvements
# Responsibilities:
#   - Feature implementation
#   - Bug fixes and code improvements
#   - Refactoring and optimization
#   - Code review and quality assurance
#   - Technical debt management
#
# ASI Implementation:
#   - Learns from past implementation patterns
#   - Improves code quality based on feedback
#   - Builds knowledge of codebase architecture
#
# MoE Implementation:
#   - Specializes in code-related tasks
#   - Spawns specialized workers for different languages/frameworks
#   - Coordinates with Security Master for security-aware development
#
# RAG Implementation:
#   - Retrieves similar past implementations
#   - References codebase documentation and patterns
#   - Learns from code review feedback
################################################################################

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"
source "$SCRIPT_DIR/lib/em-spawning.sh"

# Master identity
MASTER_ID="development"
MASTER_NAME="Development Master"
MASTER_CONTEXT_DIR="$SCRIPT_DIR/../coordination/masters/development"
MASTER_KB_DIR="$MASTER_CONTEXT_DIR/knowledge-base"
MASTER_WORKERS_DIR="$MASTER_CONTEXT_DIR/workers"

# Initialization
init_development_master() {
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
    "languages": ["bash", "javascript", "python", "typescript"],
    "frameworks": ["node.js", "express", "alpine.js"],
    "specializations": [
      "feature_implementation",
      "bug_fixing",
      "code_refactoring",
      "performance_optimization",
      "technical_debt_resolution"
    ]
  },
  "active_workers": [],
  "completed_tasks": 0,
  "tokens_used": 0,
  "performance_metrics": {
    "avg_implementation_time": 0,
    "success_rate": 0,
    "code_quality_score": 0
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
  "knowledge_base_id": "development-kb",
  "created_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "categories": {
    "implementation_patterns": {
      "description": "Successful code implementation patterns",
      "entries": []
    },
    "bug_fix_strategies": {
      "description": "Effective bug fixing approaches",
      "entries": []
    },
    "refactoring_techniques": {
      "description": "Proven refactoring methods",
      "entries": []
    },
    "codebase_architecture": {
      "description": "Understanding of system architecture",
      "entries": []
    },
    "performance_optimizations": {
      "description": "Successful performance improvements",
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
      "type_id": "feature-implementer",
      "description": "Implements new features and functionality",
      "specialization": "feature_development",
      "typical_token_allocation": 15000,
      "skills": ["design", "implementation", "testing"]
    },
    {
      "type_id": "bug-fixer",
      "description": "Diagnoses and fixes bugs",
      "specialization": "bug_resolution",
      "typical_token_allocation": 10000,
      "skills": ["debugging", "root_cause_analysis", "testing"]
    },
    {
      "type_id": "refactorer",
      "description": "Refactors and improves code quality",
      "specialization": "code_improvement",
      "typical_token_allocation": 12000,
      "skills": ["refactoring", "design_patterns", "best_practices"]
    },
    {
      "type_id": "optimizer",
      "description": "Optimizes performance and resource usage",
      "specialization": "performance",
      "typical_token_allocation": 13000,
      "skills": ["profiling", "optimization", "benchmarking"]
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

    # v4.0: Check if task requires Execution Manager
    if should_spawn_execution_manager "$task_data"; then
        log_info "Task complexity requires Execution Manager coordination"
        spawn_execution_manager "$task_id" "$task_data"
    else
        # Select appropriate worker type based on task
        local worker_type=$(select_worker_type "$task_type" "$task_data")

        # Spawn worker for this task
        spawn_development_worker "$task_id" "$worker_type" "$task_data"
    fi

    # Mark handoff as processed
    mv "$handoff_file" "${handoff_file}.processed"
}

# MoE: Select appropriate worker type for task
select_worker_type() {
    local task_type="$1"
    local task_data="$2"

    local worker_type="implementation-worker" # default

    # Match task to worker specialization
    case "$task_type" in
        *feature*|*implement*)
            worker_type="implementation-worker"
            ;;
        *bug*|*fix*|*error*)
            worker_type="fix-worker"
            ;;
        *refactor*|*improve*|*cleanup*)
            worker_type="implementation-worker"
            ;;
        *optimize*|*performance*|*speed*)
            worker_type="implementation-worker"
            ;;
    esac

    log_info "Selected worker type: $worker_type for task type: $task_type"
    echo "$worker_type"
}

# v4.0: Spawn Execution Manager for complex tasks
# Uses shared library function
spawn_execution_manager() {
    local task_id="$1"
    local task_data="$2"
    spawn_execution_manager_for_master "$task_id" "$task_data" "development"
}

# Spawn a development worker
spawn_development_worker() {
    local task_id="$1"
    local worker_type="$2"
    local task_data="$3"

    local worker_id="dev-worker-$(uuidgen | cut -d'-' -f1)"
    log_section "Spawning Development Worker: $worker_id"

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
  "prompt_template": "agents/prompts/workers/implementation-worker.md",
  "parent_master": "$MASTER_ID",
  "task_id": "$task_id",
  "task_data": $task_data,
  "context": {
    "master_session": "$(jq -r '.session_id' "$MASTER_CONTEXT_DIR/context/master-state.json")",
    "expertise_area": "$(echo "$worker_config" | jq -r '.specialization')",
    "skills_required": $(echo "$worker_config" | jq -r '.skills'),
    "knowledge_base_refs": {
      "implementation_patterns": "$MASTER_KB_DIR/implementation-patterns.jsonl",
      "architecture_docs": "$MASTER_KB_DIR/codebase-architecture.json"
    }
  },
  "resources": {
    "token_allocation": $token_allocation,
    "time_limit_minutes": 60
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
    log_event "worker_spawned" "{\"worker_id\": \"$worker_id\", \"task_id\": \"$task_id\", \"master\": \"$MASTER_ID\"}"
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
        init_development_master
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
