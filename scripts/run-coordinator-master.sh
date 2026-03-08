#!/bin/bash

################################################################################
# Coordinator Master Agent
#
# Role: Central orchestration and task delegation across all specialist masters
# Responsibilities:
#   - Task intake and prioritization
#   - Master selection and task routing (MoE)
#   - Cross-master coordination
#   - Resource allocation and token budgeting
#   - Results aggregation from all masters
#
# ASI Implementation:
#   - Maintains global system state and context
#   - Makes high-level strategic decisions
#   - Learns from past task outcomes
#
# MoE Implementation:
#   - Routes tasks to appropriate specialist masters
#   - Balances workload across masters
#   - Determines when to involve multiple masters
#
# RAG Implementation:
#   - Retrieves relevant context from all master knowledge bases
#   - Augments task descriptions with historical outcomes
#   - Stores cross-master learnings
################################################################################

set -euo pipefail

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"

# Master identity
MASTER_ID="coordinator"
MASTER_NAME="Coordinator Master"
MASTER_CONTEXT_DIR="$SCRIPT_DIR/../coordination/masters/coordinator"
MASTER_KB_DIR="$MASTER_CONTEXT_DIR/knowledge-base"
MASTER_WORKERS_DIR="$MASTER_CONTEXT_DIR/workers"

# Initialization
init_coordinator_master() {
    log_section "Initializing $MASTER_NAME"

    # Create context structure
    mkdir -p "$MASTER_CONTEXT_DIR"/{context,knowledge-base,workers,handoffs}

    # Initialize master state file
    local state_file="$MASTER_CONTEXT_DIR/context/master-state.json"
    if [ ! -f "$state_file" ]; then
        cat > "$state_file" <<EOF
{
  "master_id": "$MASTER_ID",
  "master_name": "$MASTER_NAME",
  "initialized_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "session_id": "$(uuidgen)",
  "status": "initializing",
  "capabilities": [
    "task_routing",
    "resource_allocation",
    "cross_master_coordination",
    "priority_management",
    "results_aggregation"
  ],
  "specialist_masters": {
    "security": {
      "status": "available",
      "workload": 0,
      "last_contact": null
    },
    "development": {
      "status": "available",
      "workload": 0,
      "last_contact": null
    },
    "inventory": {
      "status": "available",
      "workload": 0,
      "last_contact": null
    }
  },
  "active_workers": [],
  "completed_tasks": 0,
  "tokens_used": 0
}
EOF
        log_success "Created master state file"
    fi

    # Initialize knowledge base
    local kb_index="$MASTER_KB_DIR/index.json"
    if [ ! -f "$kb_index" ]; then
        cat > "$kb_index" <<EOF
{
  "knowledge_base_id": "coordinator-kb",
  "created_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "categories": {
    "task_routing_rules": {
      "description": "Rules for routing tasks to specialist masters",
      "entries": []
    },
    "resource_allocation_history": {
      "description": "Historical resource allocation decisions and outcomes",
      "entries": []
    },
    "cross_master_patterns": {
      "description": "Patterns of successful cross-master collaboration",
      "entries": []
    },
    "priority_heuristics": {
      "description": "Learned heuristics for task prioritization",
      "entries": []
    }
  },
  "total_entries": 0,
  "last_updated": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
        log_success "Created knowledge base index"
    fi

    # Load default routing rules (MoE configuration)
    local routing_rules="$MASTER_KB_DIR/routing-rules.json"
    if [ ! -f "$routing_rules" ]; then
        cat > "$routing_rules" <<EOF
{
  "routing_rules": [
    {
      "rule_id": "security-scan",
      "pattern": "security|vulnerability|audit|cve|scan",
      "target_master": "security",
      "priority": "high",
      "confidence": 0.95
    },
    {
      "rule_id": "code-development",
      "pattern": "implement|develop|code|feature|bug.*fix|refactor",
      "target_master": "development",
      "priority": "medium",
      "confidence": 0.90
    },
    {
      "rule_id": "inventory-management",
      "pattern": "inventory|catalog|document|repository.*health|dependency.*update",
      "target_master": "inventory",
      "priority": "low",
      "confidence": 0.85
    },
    {
      "rule_id": "multi-master",
      "pattern": "comprehensive|full.*audit|major.*update",
      "target_master": "multiple",
      "involved_masters": ["security", "development", "inventory"],
      "priority": "high",
      "confidence": 0.80
    }
  ],
  "fallback_master": "development",
  "last_updated": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOF
        log_success "Created routing rules"
    fi

    update_master_state "status" "active"
    log_success "$MASTER_NAME initialized successfully"
}

# Core coordination logic
process_task_queue() {
    log_section "Processing Task Queue"

    local task_queue="$SCRIPT_DIR/../coordination/task-queue.json"
    local pending_tasks=$(jq -r '.tasks[] | select(.status == "pending") | .id' "$task_queue" 2>/dev/null || echo "")

    if [ -z "$pending_tasks" ]; then
        log_info "No pending tasks to process"
        return 0
    fi

    echo "$pending_tasks" | while read -r task_id; do
        route_task "$task_id"
    done
}

# MoE: Route task to appropriate specialist master
route_task() {
    local task_id="$1"
    log_info "Routing task: $task_id"

    local task_queue="$SCRIPT_DIR/../coordination/task-queue.json"
    local task=$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id)' "$task_queue")

    if [ -z "$task" ]; then
        log_error "Task not found: $task_id"
        return 1
    fi

    # CHECK FOR ORCHESTRATION REQUIREMENT (v4.0)
    local orch_required=$(echo "$task" | jq -r '.orchestration_required // false')
    local complexity=$(echo "$task" | jq -r '.complexity // "unknown"')

    if [ "$orch_required" = "true" ] || [ "$complexity" = "high" ]; then
        log_info "Task requires orchestration (complexity: $complexity)"
        log_info "Task Orchestrator daemon will handle decomposition"

        # Mark task as requiring orchestration (daemon will pick it up)
        update_task_status "$task_id" "pending" "{\"orchestration_required\": true, \"routed_by\": \"$MASTER_ID\"}"
        log_success "Task $task_id flagged for Task Orchestrator"

        # Log routing decision
        record_routing_decision "$task_id" "orchestrator" "orchestration-required"
        return 0
    fi

    local task_type=$(echo "$task" | jq -r '.type')
    local task_title=$(echo "$task" | jq -r '.title // ""')
    local task_description=$(echo "$task" | jq -r '.description // ""')
    local task_desc="$task_type: $task_title $task_description"

    # ========================================================================
    # NEW: Use MoE Router for intelligent routing with confidence scoring
    # ========================================================================
    log_info "Using MoE Router for intelligent task routing..."

    local moe_router="$MASTER_CONTEXT_DIR/lib/moe-router.sh"
    if [ -f "$moe_router" ]; then
        # Call MoE router with task description
        local routing_decision=$("$moe_router" "$task_id" "$task_desc" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$routing_decision" ]; then
            # Extract routing info from MoE decision
            local target_master=$(echo "$routing_decision" | jq -r '.decision.primary_expert')
            local confidence=$(echo "$routing_decision" | jq -r '.decision.primary_confidence')
            local strategy=$(echo "$routing_decision" | jq -r '.decision.strategy')
            local parallel_experts=$(echo "$routing_decision" | jq -r '.decision.parallel_experts[]' 2>/dev/null)

            log_success "MoE Routing: $target_master (confidence: $confidence, strategy: $strategy)"

            # Emit MoE routing event for dashboard
            local event_script="$SCRIPT_DIR/emit-event.sh"
            if [ -f "$event_script" ]; then
                local event_data=$(jq -nc \
                    --arg task "$task_id" \
                    --arg expert "$target_master" \
                    --arg conf "$confidence" \
                    --arg strat "$strategy" \
                    '{task_id: $task, expert: $expert, confidence: ($conf | tonumber), strategy: $strat}')
                "$event_script" "moe_routing_decision" "$event_data" "coordinator-master" 2>/dev/null || true
            fi

            # Handle parallel expert activation if needed
            if [ -n "$parallel_experts" ]; then
                log_info "Parallel experts detected: $parallel_experts"
                # Call parallel activation script
                local parallel_script="$SCRIPT_DIR/activate-experts-parallel.sh"
                if [ -f "$parallel_script" ]; then
                    "$parallel_script" "$task_id" "$task_desc" 2>/dev/null &
                    log_success "Triggered parallel expert activation"
                fi
            else
                # Single expert - assign task
                assign_task_to_master "$task_id" "$target_master" "$routing_decision"
            fi

            # Record MoE routing decision for learning
            record_moe_routing_decision "$task_id" "$routing_decision"

            # Update memory/learning system
            local memory_manager="$MASTER_CONTEXT_DIR/lib/memory-manager.sh"
            if [ -f "$memory_manager" ]; then
                "$memory_manager" analyze "$task_id" "$task_desc" "$routing_decision" 2>/dev/null &
                log_info "Triggered memory/learning update"
            fi

            return 0
        else
            log_warn "MoE router failed, falling back to pattern-based routing"
        fi
    else
        log_warn "MoE router not found, using legacy pattern-based routing"
    fi

    # ========================================================================
    # FALLBACK: Legacy pattern-based routing (kept for compatibility)
    # ========================================================================

    # Retrieve routing rules (RAG: retrieve from knowledge base)
    local routing_rules="$MASTER_KB_DIR/routing-rules.json"
    local target_master=""
    local matched_rule=""

    # Match against routing patterns
    while IFS= read -r rule; do
        local pattern=$(echo "$rule" | jq -r '.pattern')
        local master=$(echo "$rule" | jq -r '.target_master')

        if echo "$task_desc" | grep -iE "$pattern" > /dev/null 2>&1; then
            target_master="$master"
            matched_rule=$(echo "$rule" | jq -r '.rule_id')
            log_success "Matched routing rule: $matched_rule -> $target_master"
            break
        fi
    done < <(jq -c '.routing_rules[]' "$routing_rules")

    # Fallback to development if no match
    if [ -z "$target_master" ]; then
        target_master=$(jq -r '.fallback_master' "$routing_rules")
        log_info "No routing match, using fallback: $target_master"
    fi

    # Handle multi-master tasks
    if [ "$target_master" = "multiple" ]; then
        route_to_multiple_masters "$task_id" "$matched_rule"
        return $?
    fi

    # Assign task to specialist master
    assign_task_to_master "$task_id" "$target_master"

    # Record routing decision (ASI: learn from decisions)
    record_routing_decision "$task_id" "$target_master" "$matched_rule"
}

# Assign task to a specific specialist master
assign_task_to_master() {
    local task_id="$1"
    local target_master="$2"
    local routing_decision="${3:-}"  # Optional MoE routing decision

    log_info "Assigning $task_id to $target_master master"

    # Extract confidence and strategy if MoE decision provided
    local confidence="N/A"
    local strategy="pattern-based"
    local routing_reason="Pattern-based routing via MoE"

    if [ -n "$routing_decision" ]; then
        confidence=$(echo "$routing_decision" | jq -r '.decision.primary_confidence // "N/A"')
        strategy=$(echo "$routing_decision" | jq -r '.decision.strategy // "pattern-based"')
        routing_reason="MoE confidence-based routing (confidence: $confidence, strategy: $strategy)"
    fi

    # Update task with assignment
    update_task_status "$task_id" "assigned" "{\"assigned_to\": \"$target_master\", \"assigned_by\": \"$MASTER_ID\", \"assigned_at\": \"$(date +%Y-%m-%dT%H:%M:%S%z)\", \"routing_confidence\": \"$confidence\", \"routing_strategy\": \"$strategy\"}"

    # Create handoff for target master
    local handoff_file="$MASTER_CONTEXT_DIR/handoffs/to-${target_master}-${task_id}.json"
    local task_queue="$SCRIPT_DIR/../coordination/task-queue.json"
    local task=$(jq --arg id "$task_id" '.tasks[] | select(.id == $id)' "$task_queue")

    # Build handoff with routing metadata
    local handoff_content=$(jq -n \
        --arg handoff_id "coord-to-${target_master}-$(uuidgen)" \
        --arg from "$MASTER_ID" \
        --arg to "$target_master" \
        --arg tid "$task_id" \
        --argjson tdata "$task" \
        --arg reason "$routing_reason" \
        --arg priority "$(echo "$task" | jq -r '.priority // "medium"')" \
        --arg conf "$confidence" \
        --arg strat "$strategy" \
        --arg created "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            handoff_id: $handoff_id,
            from_master: $from,
            to_master: $to,
            task_id: $tid,
            task_data: $tdata,
            context: {
                routing_reason: $reason,
                priority: $priority,
                expected_outcome: "Task completion with results handoff",
                moe_metadata: {
                    confidence: $conf,
                    strategy: $strat,
                    routed_at: $created
                }
            },
            created_at: $created,
            status: "pending_pickup"
        }')

    echo "$handoff_content" > "$handoff_file"

    log_success "Created handoff for $target_master master (confidence: $confidence)"

    # Trigger target master (if daemon is running, it will pick this up)
    log_event "task_routed" "{\"task_id\": \"$task_id\", \"target_master\": \"$target_master\", \"confidence\": \"$confidence\"}"
}

# Handle multi-master tasks
route_to_multiple_masters() {
    local task_id="$1"
    local rule_id="$2"

    log_info "Routing $task_id to multiple masters"

    # Get involved masters from rule
    local routing_rules="$MASTER_KB_DIR/routing-rules.json"
    local masters=$(jq -r --arg rule "$rule_id" '.routing_rules[] | select(.rule_id == $rule) | .involved_masters[]' "$routing_rules")

    # Create sub-tasks for each master
    local subtask_num=1
    echo "$masters" | while read -r master; do
        local subtask_id="${task_id}-sub${subtask_num}"
        log_info "Creating subtask $subtask_id for $master"

        # Create subtask in task queue
        # TODO: Implement subtask creation logic

        subtask_num=$((subtask_num + 1))
    done

    log_success "Multi-master routing completed for $task_id"
}

# Update master state
update_master_state() {
    local key="$1"
    local value="$2"

    local state_file="$MASTER_CONTEXT_DIR/context/master-state.json"
    local updated=$(jq --arg key "$key" --arg val "$value" '.[$key] = $val' "$state_file")
    echo "$updated" > "$state_file"
}

# Record routing decision for learning (updated to use MoE-compatible format)
record_routing_decision() {
    local task_id="$1"
    local target_master="$2"
    local rule_id="$3"

    local decision_file="$MASTER_KB_DIR/routing-decisions.jsonl"

    # Use MoE-compatible format with decision object for consistent metrics
    local decision=$(jq -nc \
        --arg task "$task_id" \
        --arg master "$target_master" \
        --arg rule "$rule_id" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{
            task_id: $task,
            timestamp: $ts,
            routing_strategy: "pattern_fallback",
            decision: {
                primary_expert: $master,
                primary_confidence: 0.75,
                strategy: "pattern_match",
                parallel_experts: [],
                scores: {
                    development: (if $master == "development" then 0.75 else 0 end),
                    security: (if $master == "security" then 0.75 else 0 end),
                    inventory: (if $master == "inventory" then 0.75 else 0 end)
                }
            },
            rule_used: $rule
        }')

    echo "$decision" >> "$decision_file"
}

# Record MoE routing decision for learning and analytics
record_moe_routing_decision() {
    local task_id="$1"
    local routing_decision="$2"

    # Save to MoE-specific log (used by memory/learning system)
    local moe_log="$MASTER_CONTEXT_DIR/logs/routing-decisions.jsonl"
    mkdir -p "$(dirname "$moe_log")"

    # Extract key routing info
    local primary_expert=$(echo "$routing_decision" | jq -r '.decision.primary_expert')
    local confidence=$(echo "$routing_decision" | jq -r '.decision.primary_confidence')
    local strategy=$(echo "$routing_decision" | jq -r '.decision.strategy')

    # Create enriched log entry
    local log_entry=$(echo "$routing_decision" | jq \
        --arg task "$task_id" \
        '. + {enriched_metadata: {logged_by: "coordinator-master", logged_at: (now | strftime("%Y-%m-%dT%H:%M:%S%z"))}}')

    echo "$log_entry" >> "$moe_log"

    # v4.0: Removed legacy format logging - MoE router already records decision in proper format
    # This eliminates duplicate entries that were causing low confidence rate calculations

    log_info "Recorded MoE routing decision for task $task_id"
}

# Main execution
main() {
    log_section "Starting $MASTER_NAME"

    # Initialize if needed
    if [ ! -f "$MASTER_CONTEXT_DIR/context/master-state.json" ]; then
        init_coordinator_master
    else
        log_info "$MASTER_NAME already initialized, loading state..."
        update_master_state "status" "active"
        update_master_state "last_started" "$(date +%Y-%m-%dT%H:%M:%S%z)"
    fi

    # Process task queue
    process_task_queue

    # Update final state
    update_master_state "status" "idle"
    update_master_state "last_run" "$(date +%Y-%m-%dT%H:%M:%S%z)"

    log_success "$MASTER_NAME completed successfully"
}

# Execute
main "$@"
