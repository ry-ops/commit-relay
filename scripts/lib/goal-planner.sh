#!/bin/bash
# scripts/lib/goal-planner.sh
# Goal-Based Worker Planning Library
#
# Part of Five Agent Types Architecture (Week 3)
# Implements goal-based reasoning for workers before execution
#
# Features:
# - Strategy simulation (TDD, research-first, direct, iterative)
# - Goal specification parsing from task specs
# - Plan selection based on task characteristics
# - Success criteria validation
#
# Usage:
#   source scripts/lib/goal-planner.sh
#   plan_worker_strategy "$task_spec_json" "$worker_type"
#   get_strategy_for_goal "$goal_type" "$task_complexity"

set -euo pipefail

# Strategy definitions
# Each strategy has different characteristics suited to different goals
declare -A STRATEGY_PROFILES=(
    # TDD Strategy: Test-first development
    ["tdd.description"]="Write tests first, then implement to pass tests"
    ["tdd.best_for"]="implementation,feature-development,bug-fixes"
    ["tdd.complexity_preference"]="medium,high"
    ["tdd.time_multiplier"]="1.3"
    ["tdd.quality_score"]="0.95"
    ["tdd.risk_level"]="low"

    # Research-First Strategy: Deep analysis before action
    ["research.description"]="Thorough investigation and planning before implementation"
    ["research.best_for"]="analysis,architecture,complex-systems"
    ["research.complexity_preference"]="high,very-high"
    ["research.time_multiplier"]="1.5"
    ["research.quality_score"]="0.90"
    ["research.risk_level"]="very-low"

    # Direct Strategy: Immediate implementation
    ["direct.description"]="Direct implementation with minimal planning"
    ["direct.best_for"]="simple-tasks,documentation,configuration"
    ["direct.complexity_preference"]="low,medium"
    ["direct.time_multiplier"]="0.8"
    ["direct.quality_score"]="0.75"
    ["direct.risk_level"]="medium"

    # Iterative Strategy: Build incrementally with feedback
    ["iterative.description"]="Build in small increments with continuous validation"
    ["iterative.best_for"]="refactoring,optimization,exploratory-work"
    ["iterative.complexity_preference"]="medium,high,very-high"
    ["iterative.time_multiplier"]="1.2"
    ["iterative.quality_score"]="0.85"
    ["iterative.risk_level"]="low"
)

# Goal type classifications
# Maps task types to goal categories
declare -A GOAL_TYPES=(
    ["implementation-worker"]="feature-development"
    ["test-worker"]="quality-assurance"
    ["documentation-worker"]="knowledge-capture"
    ["scan-worker"]="analysis"
    ["fix-worker"]="bug-fixes"
    ["analysis-worker"]="deep-analysis"
    ["refactor-worker"]="code-improvement"
    ["validation-worker"]="verification"
)

# Complexity scoring factors
declare -A COMPLEXITY_FACTORS=(
    ["lines_of_code.threshold_low"]=100
    ["lines_of_code.threshold_medium"]=500
    ["lines_of_code.threshold_high"]=2000
    ["file_count.threshold_low"]=3
    ["file_count.threshold_medium"]=10
    ["file_count.threshold_high"]=30
    ["dependencies.threshold_low"]=5
    ["dependencies.threshold_medium"]=15
    ["dependencies.threshold_high"]=40
)

# plan_worker_strategy - Main function to plan worker strategy
#
# Arguments:
#   $1 - Task specification JSON
#   $2 - Worker type
#
# Returns:
#   JSON object with selected strategy and plan
#
# Example:
#   strategy_plan=$(plan_worker_strategy "$task_spec" "implementation-worker")
plan_worker_strategy() {
    local task_spec="$1"
    local worker_type="$2"

    # Parse task characteristics
    local task_id=$(echo "$task_spec" | jq -r '.id // .task_id // "unknown"')
    local task_priority=$(echo "$task_spec" | jq -r '.priority // .context.priority // "medium"')
    local task_description=$(echo "$task_spec" | jq -r '.description // .title // ""')

    # Determine goal type
    local goal_type="${GOAL_TYPES[$worker_type]:-general}"

    # Analyze task complexity
    local complexity=$(analyze_task_complexity "$task_spec" "$worker_type")

    # Select optimal strategy
    local selected_strategy=$(select_optimal_strategy "$goal_type" "$complexity" "$task_priority")

    # Generate execution plan
    local execution_plan=$(generate_execution_plan "$selected_strategy" "$task_spec" "$worker_type")

    # Define success criteria
    local success_criteria=$(define_success_criteria "$goal_type" "$selected_strategy" "$task_spec")

    # Construct strategy plan JSON
    local strategy_plan=$(cat <<EOF
{
  "task_id": "$task_id",
  "worker_type": "$worker_type",
  "goal_type": "$goal_type",
  "complexity": "$complexity",
  "selected_strategy": "$selected_strategy",
  "strategy_description": "${STRATEGY_PROFILES[$selected_strategy.description]:-Unknown strategy}",
  "time_multiplier": ${STRATEGY_PROFILES[$selected_strategy.time_multiplier]:-1.0},
  "expected_quality": ${STRATEGY_PROFILES[$selected_strategy.quality_score]:-0.8},
  "risk_level": "${STRATEGY_PROFILES[$selected_strategy.risk_level]:-medium}",
  "execution_plan": $execution_plan,
  "success_criteria": $success_criteria,
  "planned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "planning_metadata": {
    "planner_version": "1.0.0",
    "strategy_profiles_count": 4,
    "decision_factors": ["goal_type", "complexity", "priority"]
  }
}
EOF
)

    # Validate JSON before returning
    if echo "$strategy_plan" | jq empty 2>/dev/null; then
        echo "$strategy_plan"
        return 0
    else
        # Return minimal valid plan on error
        echo '{"error":"Failed to generate strategy plan","task_id":"'$task_id'","selected_strategy":"direct"}'
        return 1
    fi
}

# analyze_task_complexity - Determine task complexity level
#
# Arguments:
#   $1 - Task specification JSON
#   $2 - Worker type
#
# Returns:
#   Complexity level: low, medium, high, very-high
analyze_task_complexity() {
    local task_spec="$1"
    local worker_type="$2"

    local complexity_score=0

    # Factor 1: Task description length (proxy for scope)
    local description=$(echo "$task_spec" | jq -r '.description // .title // ""')
    local desc_length=${#description}

    if [ "$desc_length" -gt 200 ]; then
        complexity_score=$((complexity_score + 3))
    elif [ "$desc_length" -gt 100 ]; then
        complexity_score=$((complexity_score + 2))
    elif [ "$desc_length" -gt 50 ]; then
        complexity_score=$((complexity_score + 1))
    fi

    # Factor 2: Scope information (files, repositories)
    local file_count=$(echo "$task_spec" | jq -r '.scope.files // [] | length')
    if [ "$file_count" -gt "${COMPLEXITY_FACTORS[file_count.threshold_high]}" ]; then
        complexity_score=$((complexity_score + 3))
    elif [ "$file_count" -gt "${COMPLEXITY_FACTORS[file_count.threshold_medium]}" ]; then
        complexity_score=$((complexity_score + 2))
    elif [ "$file_count" -gt "${COMPLEXITY_FACTORS[file_count.threshold_low]}" ]; then
        complexity_score=$((complexity_score + 1))
    fi

    # Factor 3: Priority (higher priority often means more complexity)
    local priority=$(echo "$task_spec" | jq -r '.priority // .context.priority // "medium"')
    case "$priority" in
        critical) complexity_score=$((complexity_score + 2)) ;;
        high) complexity_score=$((complexity_score + 1)) ;;
    esac

    # Factor 4: Worker type inherent complexity
    case "$worker_type" in
        implementation-worker|refactor-worker) complexity_score=$((complexity_score + 2)) ;;
        scan-worker|analysis-worker) complexity_score=$((complexity_score + 1)) ;;
    esac

    # Convert score to complexity level
    if [ "$complexity_score" -ge 8 ]; then
        echo "very-high"
    elif [ "$complexity_score" -ge 5 ]; then
        echo "high"
    elif [ "$complexity_score" -ge 3 ]; then
        echo "medium"
    else
        echo "low"
    fi
}

# select_optimal_strategy - Choose best strategy for goal and complexity
#
# Arguments:
#   $1 - Goal type
#   $2 - Complexity level
#   $3 - Priority
#
# Returns:
#   Strategy name: tdd, research, direct, or iterative
select_optimal_strategy() {
    local goal_type="$1"
    local complexity="$2"
    local priority="$3"

    # Strategy selection logic based on goal and complexity
    case "$goal_type" in
        feature-development|bug-fixes)
            # TDD is great for implementation and fixes
            if [[ "$complexity" =~ ^(medium|high)$ ]]; then
                echo "tdd"
                return 0
            else
                echo "direct"
                return 0
            fi
            ;;

        analysis|deep-analysis)
            # Research-first for analysis work
            if [[ "$complexity" =~ ^(high|very-high)$ ]]; then
                echo "research"
                return 0
            else
                echo "direct"
                return 0
            fi
            ;;

        code-improvement|refactoring)
            # Iterative for refactoring
            echo "iterative"
            return 0
            ;;

        knowledge-capture|verification|quality-assurance)
            # Direct approach for documentation and simple verification
            echo "direct"
            return 0
            ;;

        *)
            # Default: choose based on complexity
            case "$complexity" in
                very-high) echo "research" ;;
                high) echo "iterative" ;;
                medium) echo "tdd" ;;
                *) echo "direct" ;;
            esac
            return 0
            ;;
    esac
}

# generate_execution_plan - Create step-by-step execution plan
#
# Arguments:
#   $1 - Selected strategy
#   $2 - Task specification JSON
#   $3 - Worker type
#
# Returns:
#   JSON array of execution steps
generate_execution_plan() {
    local strategy="$1"
    local task_spec="$2"
    local worker_type="$3"

    case "$strategy" in
        tdd)
            cat <<'EOF'
{
  "approach": "test-driven-development",
  "phases": [
    {
      "phase": 1,
      "name": "Test Design",
      "activities": ["Define test cases", "Identify edge cases", "Set up test fixtures"],
      "estimated_time_percent": 25
    },
    {
      "phase": 2,
      "name": "Test Implementation",
      "activities": ["Write failing tests", "Validate test coverage", "Run test suite"],
      "estimated_time_percent": 20
    },
    {
      "phase": 3,
      "name": "Implementation",
      "activities": ["Implement minimal code to pass tests", "Refactor for quality", "Verify all tests pass"],
      "estimated_time_percent": 40
    },
    {
      "phase": 4,
      "name": "Validation",
      "activities": ["Final test run", "Code review", "Documentation"],
      "estimated_time_percent": 15
    }
  ]
}
EOF
            ;;

        research)
            cat <<'EOF'
{
  "approach": "research-first",
  "phases": [
    {
      "phase": 1,
      "name": "Discovery",
      "activities": ["Analyze existing code", "Identify dependencies", "Map system architecture"],
      "estimated_time_percent": 35
    },
    {
      "phase": 2,
      "name": "Planning",
      "activities": ["Design solution approach", "Identify risks", "Define success criteria"],
      "estimated_time_percent": 25
    },
    {
      "phase": 3,
      "name": "Execution",
      "activities": ["Implement planned solution", "Handle edge cases", "Validate assumptions"],
      "estimated_time_percent": 30
    },
    {
      "phase": 4,
      "name": "Documentation",
      "activities": ["Document findings", "Update architecture docs", "Record decisions"],
      "estimated_time_percent": 10
    }
  ]
}
EOF
            ;;

        iterative)
            cat <<'EOF'
{
  "approach": "iterative-incremental",
  "phases": [
    {
      "phase": 1,
      "name": "Increment 1",
      "activities": ["Implement core feature", "Basic validation", "Quick test"],
      "estimated_time_percent": 25
    },
    {
      "phase": 2,
      "name": "Increment 2",
      "activities": ["Add next layer of functionality", "Integration testing", "Refine approach"],
      "estimated_time_percent": 25
    },
    {
      "phase": 3,
      "name": "Increment 3",
      "activities": ["Complete remaining features", "Edge case handling", "Full testing"],
      "estimated_time_percent": 30
    },
    {
      "phase": 4,
      "name": "Polish",
      "activities": ["Refactor", "Optimize", "Document"],
      "estimated_time_percent": 20
    }
  ]
}
EOF
            ;;

        direct)
            cat <<'EOF'
{
  "approach": "direct-implementation",
  "phases": [
    {
      "phase": 1,
      "name": "Setup",
      "activities": ["Understand requirements", "Identify files to modify", "Set up workspace"],
      "estimated_time_percent": 15
    },
    {
      "phase": 2,
      "name": "Implementation",
      "activities": ["Write code", "Basic testing", "Fix obvious issues"],
      "estimated_time_percent": 60
    },
    {
      "phase": 3,
      "name": "Finalization",
      "activities": ["Code review", "Documentation", "Submit work"],
      "estimated_time_percent": 25
    }
  ]
}
EOF
            ;;

        *)
            echo '{"approach":"unknown","phases":[]}'
            ;;
    esac
}

# define_success_criteria - Define measurable success criteria
#
# Arguments:
#   $1 - Goal type
#   $2 - Strategy
#   $3 - Task specification JSON
#
# Returns:
#   JSON object with success criteria
define_success_criteria() {
    local goal_type="$1"
    local strategy="$2"
    local task_spec="$3"

    # Base criteria for all workers
    local base_criteria='["Task completed within token budget", "No critical errors during execution", "Results validated and documented"]'

    # Goal-specific criteria
    case "$goal_type" in
        feature-development)
            echo '{
                "primary": "Feature implemented and working as specified",
                "quality_gates": ["All tests passing", "Code coverage > 80%", "No new security vulnerabilities"],
                "deliverables": ["Working code", "Unit tests", "Integration tests", "Documentation"],
                "validation": "Automated test suite must pass"
            }'
            ;;

        quality-assurance)
            echo '{
                "primary": "Test coverage comprehensive and passing",
                "quality_gates": ["All test cases defined", "Edge cases covered", "Test suite runs successfully"],
                "deliverables": ["Test files", "Test documentation", "Coverage report"],
                "validation": "Test coverage meets threshold"
            }'
            ;;

        knowledge-capture)
            echo '{
                "primary": "Documentation complete and accurate",
                "quality_gates": ["All sections present", "Examples included", "Clear and readable"],
                "deliverables": ["Documentation files", "Diagrams if needed", "Examples"],
                "validation": "Documentation review passes"
            }'
            ;;

        analysis|deep-analysis)
            echo '{
                "primary": "Analysis complete with actionable insights",
                "quality_gates": ["All areas investigated", "Findings documented", "Recommendations provided"],
                "deliverables": ["Analysis report", "Findings summary", "Action items"],
                "validation": "Report addresses all requirements"
            }'
            ;;

        bug-fixes)
            echo '{
                "primary": "Bug fixed and verified",
                "quality_gates": ["Root cause identified", "Fix implemented", "Regression tests added"],
                "deliverables": ["Fixed code", "Regression tests", "Fix documentation"],
                "validation": "Bug no longer reproduces"
            }'
            ;;

        code-improvement)
            echo '{
                "primary": "Code quality improved measurably",
                "quality_gates": ["No functionality broken", "Metrics improved", "Tests passing"],
                "deliverables": ["Refactored code", "Before/after metrics", "Tests"],
                "validation": "Quality metrics show improvement"
            }'
            ;;

        *)
            echo '{
                "primary": "Task objectives achieved",
                "quality_gates": '$base_criteria',
                "deliverables": ["Task output", "Summary"],
                "validation": "Manual review required"
            }'
            ;;
    esac
}

# get_strategy_for_goal - Quick strategy lookup
#
# Arguments:
#   $1 - Goal type
#   $2 - Task complexity (optional, defaults to medium)
#
# Returns:
#   Strategy name
get_strategy_for_goal() {
    local goal_type="$1"
    local complexity="${2:-medium}"

    select_optimal_strategy "$goal_type" "$complexity" "medium"
}

# save_strategy_plan - Save strategy plan to knowledge base
#
# Arguments:
#   $1 - Strategy plan JSON
#   $2 - Worker ID
#   $3 - Task ID
#
# Returns:
#   0 on success, 1 on failure
save_strategy_plan() {
    local strategy_plan="$1"
    local worker_id="$2"
    local task_id="$3"

    local kb_dir="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/knowledge-base/strategy-plans"
    mkdir -p "$kb_dir"

    local plan_file="$kb_dir/${worker_id}-plan.json"

    if echo "$strategy_plan" | jq empty 2>/dev/null; then
        echo "$strategy_plan" > "$plan_file"

        # Also append to strategy decisions log for learning
        local log_file="$kb_dir/strategy-decisions.jsonl"
        echo "$strategy_plan" >> "$log_file"

        return 0
    else
        return 1
    fi
}

# load_strategy_plan - Load strategy plan for worker
#
# Arguments:
#   $1 - Worker ID
#
# Returns:
#   Strategy plan JSON or empty object
load_strategy_plan() {
    local worker_id="$1"

    local kb_dir="${COMMIT_RELAY_HOME:-/Users/ryandahlberg/commit-relay}/coordination/knowledge-base/strategy-plans"
    local plan_file="$kb_dir/${worker_id}-plan.json"

    if [ -f "$plan_file" ]; then
        cat "$plan_file"
    else
        echo '{}'
    fi
}

# validate_strategy_plan - Ensure strategy plan is valid
#
# Arguments:
#   $1 - Strategy plan JSON
#
# Returns:
#   0 if valid, 1 if invalid
validate_strategy_plan() {
    local plan="$1"

    # Check JSON validity
    if ! echo "$plan" | jq empty 2>/dev/null; then
        return 1
    fi

    # Check required fields
    local required_fields=("selected_strategy" "goal_type" "execution_plan" "success_criteria")

    for field in "${required_fields[@]}"; do
        if ! echo "$plan" | jq -e ".$field" >/dev/null 2>&1; then
            return 1
        fi
    done

    return 0
}

# Export functions for use by other scripts
export -f plan_worker_strategy
export -f analyze_task_complexity
export -f select_optimal_strategy
export -f generate_execution_plan
export -f define_success_criteria
export -f get_strategy_for_goal
export -f save_strategy_plan
export -f load_strategy_plan
export -f validate_strategy_plan
