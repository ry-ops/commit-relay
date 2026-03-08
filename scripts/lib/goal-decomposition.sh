#!/bin/bash
# scripts/lib/goal-decomposition.sh
# Goal Decomposition with Verification Checkpoints - Phase 4 Item 23
#
# Purpose:
# - Decompose complex goals into verifiable sub-goals
# - Add verification checkpoints for multi-step tasks
# - Integrate with task-spec-builder
# - Track progress through goal hierarchy
#
# Usage:
#   source scripts/lib/goal-decomposition.sh
#   decompose_goal "$task_json" | checkpoint_verification

set -eo pipefail

# Prevent re-sourcing
if [ -n "${GOAL_DECOMPOSITION_LOADED:-}" ]; then
    return 0
fi
GOAL_DECOMPOSITION_LOADED=1

# Load dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Verification checkpoint storage
CHECKPOINTS_DIR="$COMMIT_RELAY_HOME/coordination/checkpoints"
DECOMPOSITION_LOG="$COMMIT_RELAY_HOME/coordination/goal-decompositions.jsonl"

# Ensure directories exist
mkdir -p "$CHECKPOINTS_DIR"
mkdir -p "$(dirname "$DECOMPOSITION_LOG")"

##############################################################################
# decompose_goal: Break down a complex goal into verifiable sub-goals
#
# Arguments:
#   $1 - Task specification JSON
#
# Returns:
#   JSON object with decomposed goals and checkpoints
##############################################################################
decompose_goal() {
    local task_spec="$1"

    # Parse task information
    local task_id=$(echo "$task_spec" | jq -r '.id // .task_id // "unknown"')
    local task_title=$(echo "$task_spec" | jq -r '.title // .description // "Untitled"')
    local task_type=$(echo "$task_spec" | jq -r '.type // "general"')
    local task_priority=$(echo "$task_spec" | jq -r '.priority // "medium"')
    local task_complexity=$(estimate_complexity "$task_spec")

    # Generate decomposition ID
    local decomp_id="decomp-$(date +%s)-$(openssl rand -hex 3 2>/dev/null || echo $RANDOM)"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Determine decomposition strategy based on task type
    local sub_goals
    case "$task_type" in
        implementation|feature-development)
            sub_goals=$(decompose_implementation "$task_spec" "$task_complexity")
            ;;
        security-scan|analysis)
            sub_goals=$(decompose_analysis "$task_spec" "$task_complexity")
            ;;
        bug-fix|security-fix)
            sub_goals=$(decompose_fix "$task_spec" "$task_complexity")
            ;;
        documentation|catalog)
            sub_goals=$(decompose_documentation "$task_spec" "$task_complexity")
            ;;
        *)
            sub_goals=$(decompose_generic "$task_spec" "$task_complexity")
            ;;
    esac

    # Build decomposition result
    local result=$(cat <<EOF
{
  "decomposition_id": "$decomp_id",
  "task_id": "$task_id",
  "task_title": "$task_title",
  "task_type": "$task_type",
  "complexity": "$task_complexity",
  "created_at": "$timestamp",
  "status": "pending",
  "sub_goals": $sub_goals,
  "verification_checkpoints": $(generate_checkpoints "$sub_goals" "$task_type"),
  "dependencies": $(analyze_dependencies "$sub_goals"),
  "estimated_total_time": $(estimate_total_time "$sub_goals"),
  "metadata": {
    "decomposer_version": "1.0.0",
    "strategy": "hierarchical",
    "verification_enabled": true
  }
}
EOF
)

    # Log decomposition
    echo "$result" >> "$DECOMPOSITION_LOG"

    # Output result
    echo "$result"
}

##############################################################################
# estimate_complexity: Determine task complexity for decomposition depth
##############################################################################
estimate_complexity() {
    local task_spec="$1"
    local score=0

    # Factor: Description length
    local desc=$(echo "$task_spec" | jq -r '.description // .title // ""')
    local desc_len=${#desc}

    if [ "$desc_len" -gt 300 ]; then
        score=$((score + 3))
    elif [ "$desc_len" -gt 150 ]; then
        score=$((score + 2))
    elif [ "$desc_len" -gt 50 ]; then
        score=$((score + 1))
    fi

    # Factor: Number of files mentioned
    local file_count=$(echo "$task_spec" | jq -r '.context.files // [] | length')
    if [ "$file_count" -gt 10 ]; then
        score=$((score + 3))
    elif [ "$file_count" -gt 5 ]; then
        score=$((score + 2))
    elif [ "$file_count" -gt 0 ]; then
        score=$((score + 1))
    fi

    # Factor: Priority
    local priority=$(echo "$task_spec" | jq -r '.priority // "medium"')
    case "$priority" in
        critical) score=$((score + 2)) ;;
        high) score=$((score + 1)) ;;
    esac

    # Convert score to complexity
    if [ "$score" -ge 7 ]; then
        echo "very-high"
    elif [ "$score" -ge 5 ]; then
        echo "high"
    elif [ "$score" -ge 3 ]; then
        echo "medium"
    else
        echo "low"
    fi
}

##############################################################################
# decompose_implementation: Decompose implementation tasks
##############################################################################
decompose_implementation() {
    local task_spec="$1"
    local complexity="$2"

    case "$complexity" in
        very-high|high)
            cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Requirements Analysis",
    "description": "Analyze and document requirements",
    "order": 1,
    "estimated_tokens": 3000,
    "verification": {
      "type": "artifact",
      "criteria": "Requirements document exists with acceptance criteria"
    }
  },
  {
    "id": "sg-2",
    "name": "Design & Architecture",
    "description": "Design solution architecture",
    "order": 2,
    "estimated_tokens": 4000,
    "verification": {
      "type": "review",
      "criteria": "Design document with component diagrams"
    }
  },
  {
    "id": "sg-3",
    "name": "Test Specification",
    "description": "Define test cases and test data",
    "order": 3,
    "estimated_tokens": 3000,
    "verification": {
      "type": "artifact",
      "criteria": "Test cases defined with expected outcomes"
    }
  },
  {
    "id": "sg-4",
    "name": "Core Implementation",
    "description": "Implement core functionality",
    "order": 4,
    "estimated_tokens": 8000,
    "verification": {
      "type": "test",
      "criteria": "Core tests passing"
    }
  },
  {
    "id": "sg-5",
    "name": "Integration",
    "description": "Integrate with existing systems",
    "order": 5,
    "estimated_tokens": 4000,
    "verification": {
      "type": "test",
      "criteria": "Integration tests passing"
    }
  },
  {
    "id": "sg-6",
    "name": "Documentation",
    "description": "Document implementation and usage",
    "order": 6,
    "estimated_tokens": 2000,
    "verification": {
      "type": "artifact",
      "criteria": "Documentation complete and accurate"
    }
  }
]
EOF
            ;;
        medium)
            cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Analysis & Design",
    "description": "Analyze requirements and design solution",
    "order": 1,
    "estimated_tokens": 4000,
    "verification": {
      "type": "review",
      "criteria": "Solution approach documented"
    }
  },
  {
    "id": "sg-2",
    "name": "Implementation",
    "description": "Implement the solution",
    "order": 2,
    "estimated_tokens": 6000,
    "verification": {
      "type": "test",
      "criteria": "All tests passing"
    }
  },
  {
    "id": "sg-3",
    "name": "Testing & Documentation",
    "description": "Test thoroughly and document",
    "order": 3,
    "estimated_tokens": 3000,
    "verification": {
      "type": "artifact",
      "criteria": "Tests and docs complete"
    }
  }
]
EOF
            ;;
        *)
            cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Implementation",
    "description": "Implement the solution directly",
    "order": 1,
    "estimated_tokens": 5000,
    "verification": {
      "type": "test",
      "criteria": "Implementation complete and working"
    }
  },
  {
    "id": "sg-2",
    "name": "Validation",
    "description": "Validate and document",
    "order": 2,
    "estimated_tokens": 2000,
    "verification": {
      "type": "review",
      "criteria": "Work validated"
    }
  }
]
EOF
            ;;
    esac
}

##############################################################################
# decompose_analysis: Decompose analysis/scan tasks
##############################################################################
decompose_analysis() {
    local task_spec="$1"
    local complexity="$2"

    cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Scope Definition",
    "description": "Define analysis scope and targets",
    "order": 1,
    "estimated_tokens": 2000,
    "verification": {
      "type": "artifact",
      "criteria": "Scope document with target list"
    }
  },
  {
    "id": "sg-2",
    "name": "Data Collection",
    "description": "Gather data for analysis",
    "order": 2,
    "estimated_tokens": 4000,
    "verification": {
      "type": "artifact",
      "criteria": "Raw data collected"
    }
  },
  {
    "id": "sg-3",
    "name": "Analysis Execution",
    "description": "Perform the analysis",
    "order": 3,
    "estimated_tokens": 5000,
    "verification": {
      "type": "artifact",
      "criteria": "Analysis results generated"
    }
  },
  {
    "id": "sg-4",
    "name": "Findings Report",
    "description": "Document findings and recommendations",
    "order": 4,
    "estimated_tokens": 3000,
    "verification": {
      "type": "review",
      "criteria": "Report with actionable items"
    }
  }
]
EOF
}

##############################################################################
# decompose_fix: Decompose bug/security fix tasks
##############################################################################
decompose_fix() {
    local task_spec="$1"
    local complexity="$2"

    cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Reproduce Issue",
    "description": "Reproduce and verify the issue",
    "order": 1,
    "estimated_tokens": 2000,
    "verification": {
      "type": "test",
      "criteria": "Issue reproduced consistently"
    }
  },
  {
    "id": "sg-2",
    "name": "Root Cause Analysis",
    "description": "Identify root cause",
    "order": 2,
    "estimated_tokens": 3000,
    "verification": {
      "type": "artifact",
      "criteria": "Root cause documented"
    }
  },
  {
    "id": "sg-3",
    "name": "Fix Implementation",
    "description": "Implement the fix",
    "order": 3,
    "estimated_tokens": 4000,
    "verification": {
      "type": "test",
      "criteria": "Issue no longer reproduces"
    }
  },
  {
    "id": "sg-4",
    "name": "Regression Testing",
    "description": "Add regression tests",
    "order": 4,
    "estimated_tokens": 2000,
    "verification": {
      "type": "test",
      "criteria": "Regression tests passing"
    }
  }
]
EOF
}

##############################################################################
# decompose_documentation: Decompose documentation tasks
##############################################################################
decompose_documentation() {
    local task_spec="$1"
    local complexity="$2"

    cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Research",
    "description": "Research subject matter",
    "order": 1,
    "estimated_tokens": 3000,
    "verification": {
      "type": "artifact",
      "criteria": "Research notes compiled"
    }
  },
  {
    "id": "sg-2",
    "name": "Outline Creation",
    "description": "Create documentation outline",
    "order": 2,
    "estimated_tokens": 2000,
    "verification": {
      "type": "review",
      "criteria": "Outline approved"
    }
  },
  {
    "id": "sg-3",
    "name": "Content Writing",
    "description": "Write documentation content",
    "order": 3,
    "estimated_tokens": 5000,
    "verification": {
      "type": "artifact",
      "criteria": "All sections written"
    }
  },
  {
    "id": "sg-4",
    "name": "Review & Polish",
    "description": "Review and finalize",
    "order": 4,
    "estimated_tokens": 2000,
    "verification": {
      "type": "review",
      "criteria": "Documentation reviewed and polished"
    }
  }
]
EOF
}

##############################################################################
# decompose_generic: Generic decomposition for unknown task types
##############################################################################
decompose_generic() {
    local task_spec="$1"
    local complexity="$2"

    cat <<'EOF'
[
  {
    "id": "sg-1",
    "name": "Planning",
    "description": "Plan the approach",
    "order": 1,
    "estimated_tokens": 2000,
    "verification": {
      "type": "review",
      "criteria": "Plan documented"
    }
  },
  {
    "id": "sg-2",
    "name": "Execution",
    "description": "Execute the plan",
    "order": 2,
    "estimated_tokens": 5000,
    "verification": {
      "type": "artifact",
      "criteria": "Work completed"
    }
  },
  {
    "id": "sg-3",
    "name": "Validation",
    "description": "Validate results",
    "order": 3,
    "estimated_tokens": 2000,
    "verification": {
      "type": "review",
      "criteria": "Results validated"
    }
  }
]
EOF
}

##############################################################################
# generate_checkpoints: Generate verification checkpoints for sub-goals
##############################################################################
generate_checkpoints() {
    local sub_goals="$1"
    local task_type="$2"

    # Generate checkpoint for each sub-goal
    echo "$sub_goals" | jq '[.[] | {
        checkpoint_id: ("cp-" + .id),
        sub_goal_id: .id,
        name: ("Verify: " + .name),
        verification_type: .verification.type,
        criteria: .verification.criteria,
        status: "pending",
        verified_at: null,
        verified_by: null,
        evidence: null
    }]'
}

##############################################################################
# analyze_dependencies: Analyze dependencies between sub-goals
##############################################################################
analyze_dependencies() {
    local sub_goals="$1"

    # Generate linear dependencies (each step depends on previous)
    echo "$sub_goals" | jq '[
        to_entries | .[] |
        if .key > 0 then {
            from: .value.id,
            to: (.[.key-1].value.id // null),
            type: "sequential"
        } else empty end
    ] | if length == 0 then [] else . end'
}

##############################################################################
# estimate_total_time: Estimate total time for all sub-goals
##############################################################################
estimate_total_time() {
    local sub_goals="$1"

    # Sum estimated tokens and convert to time estimate
    local total_tokens=$(echo "$sub_goals" | jq '[.[].estimated_tokens] | add')

    # Rough estimate: 1000 tokens ~ 1 minute
    local minutes=$((total_tokens / 1000))
    echo "$minutes"
}

##############################################################################
# create_checkpoint: Create a verification checkpoint
##############################################################################
create_checkpoint() {
    local decomp_id="$1"
    local sub_goal_id="$2"
    local task_id="$3"

    local checkpoint_id="cp-${decomp_id}-${sub_goal_id}"
    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$checkpoint_file" <<EOF
{
  "checkpoint_id": "$checkpoint_id",
  "decomposition_id": "$decomp_id",
  "sub_goal_id": "$sub_goal_id",
  "task_id": "$task_id",
  "created_at": "$timestamp",
  "status": "pending",
  "verification": {
    "verified": false,
    "verified_at": null,
    "verified_by": null,
    "method": null,
    "evidence": [],
    "notes": null
  },
  "rollback": {
    "available": false,
    "snapshot_id": null
  }
}
EOF

    echo "$checkpoint_id"
}

##############################################################################
# verify_checkpoint: Verify a checkpoint
##############################################################################
verify_checkpoint() {
    local checkpoint_id="$1"
    local verifier="$2"
    local method="$3"
    local evidence="$4"
    local notes="${5:-}"

    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"

    if [ ! -f "$checkpoint_file" ]; then
        echo "ERROR: Checkpoint not found: $checkpoint_id" >&2
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update checkpoint
    local updated=$(jq \
        --arg verified_at "$timestamp" \
        --arg verified_by "$verifier" \
        --arg method "$method" \
        --arg evidence "$evidence" \
        --arg notes "$notes" \
        '.status = "verified" |
         .verification.verified = true |
         .verification.verified_at = $verified_at |
         .verification.verified_by = $verified_by |
         .verification.method = $method |
         .verification.evidence = [$evidence] |
         .verification.notes = $notes' \
        "$checkpoint_file")

    echo "$updated" > "$checkpoint_file"

    echo "Checkpoint $checkpoint_id verified"
}

##############################################################################
# fail_checkpoint: Mark a checkpoint as failed
##############################################################################
fail_checkpoint() {
    local checkpoint_id="$1"
    local reason="$2"
    local verifier="${3:-system}"

    local checkpoint_file="$CHECKPOINTS_DIR/${checkpoint_id}.json"

    if [ ! -f "$checkpoint_file" ]; then
        echo "ERROR: Checkpoint not found: $checkpoint_id" >&2
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update checkpoint
    local updated=$(jq \
        --arg failed_at "$timestamp" \
        --arg failed_by "$verifier" \
        --arg reason "$reason" \
        '.status = "failed" |
         .verification.verified = false |
         .verification.verified_at = $failed_at |
         .verification.verified_by = $failed_by |
         .verification.notes = $reason' \
        "$checkpoint_file")

    echo "$updated" > "$checkpoint_file"

    echo "Checkpoint $checkpoint_id failed: $reason"
}

##############################################################################
# get_decomposition_status: Get status of a goal decomposition
##############################################################################
get_decomposition_status() {
    local decomp_id="$1"

    # Find all checkpoints for this decomposition
    local checkpoints=$(find "$CHECKPOINTS_DIR" -name "cp-${decomp_id}-*.json" 2>/dev/null)

    if [ -z "$checkpoints" ]; then
        echo '{"status":"not_found","decomposition_id":"'$decomp_id'"}'
        return 1
    fi

    local total=0
    local verified=0
    local failed=0
    local pending=0

    for cp_file in $checkpoints; do
        total=$((total + 1))
        local status=$(jq -r '.status' "$cp_file")
        case "$status" in
            verified) verified=$((verified + 1)) ;;
            failed) failed=$((failed + 1)) ;;
            *) pending=$((pending + 1)) ;;
        esac
    done

    local overall_status="in_progress"
    if [ "$failed" -gt 0 ]; then
        overall_status="blocked"
    elif [ "$verified" -eq "$total" ]; then
        overall_status="completed"
    fi

    cat <<EOF
{
  "decomposition_id": "$decomp_id",
  "status": "$overall_status",
  "checkpoints": {
    "total": $total,
    "verified": $verified,
    "failed": $failed,
    "pending": $pending
  },
  "progress_percent": $(echo "scale=2; $verified * 100 / $total" | bc 2>/dev/null || echo "0"),
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

##############################################################################
# integrate_with_task_spec: Add decomposition to task spec
##############################################################################
integrate_with_task_spec() {
    local task_spec="$1"

    # Decompose the goal
    local decomposition=$(decompose_goal "$task_spec")

    # Merge decomposition into task spec
    echo "$task_spec" | jq \
        --argjson decomp "$decomposition" \
        '. + {goal_decomposition: $decomp}'
}

# Export functions
export -f decompose_goal
export -f estimate_complexity
export -f create_checkpoint
export -f verify_checkpoint
export -f fail_checkpoint
export -f get_decomposition_status
export -f integrate_with_task_spec

# Log that library is loaded
if [ "${COMMIT_RELAY_LOG_LEVEL:-1}" -le 0 ] 2>/dev/null; then
    echo "[GOAL-DECOMP] Goal decomposition library loaded" >&2
fi
