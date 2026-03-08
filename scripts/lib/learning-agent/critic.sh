#!/bin/bash
# scripts/lib/learning-agent/critic.sh
# Learning Agent: Critic Component
# Week 5: Q1 Implementation - Learning Agent (Critic & Learner)
#
# Purpose: Evaluate worker and master performance, generate training data
# Part of the ASI (Artificial Superintelligence) learning cycle
#
# Functions:
# - evaluate_worker_performance(): Analyze worker execution quality and efficiency
# - generate_training_examples(): Extract learnings from executions
# - score_execution(): Quantitative performance evaluation
# - create_feedback_report(): Structured feedback for continuous improvement
#
# Learning Flow:
#   Worker Completion → Critic Evaluation → Training Examples → Learner Updates

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Load dependencies
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Configuration
TRAINING_EXAMPLES_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-examples"
FEEDBACK_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/feedback-reports"
LEARNING_METRICS_DIR="$COMMIT_RELAY_HOME/coordination/metrics/learning"

# Ensure directories exist
mkdir -p "$TRAINING_EXAMPLES_DIR" "$FEEDBACK_DIR" "$LEARNING_METRICS_DIR"

#------------------------------------------------------------------------------
# evaluate_worker_performance()
# Analyze worker execution across multiple dimensions
#
# Args:
#   $1 - worker_id: ID of worker to evaluate
#   $2 - worker_spec_path: Path to worker spec file
#
# Returns:
#   Evaluation results (JSON) written to stdout
#------------------------------------------------------------------------------
evaluate_worker_performance() {
    local worker_id="$1"
    local worker_spec_path="$2"

    log_info "[Critic] Evaluating worker performance: $worker_id"

    # Validate inputs
    if [ ! -f "$worker_spec_path" ]; then
        log_error "[Critic] Worker spec not found: $worker_spec_path"
        return 1
    fi

    if ! jq empty "$worker_spec_path" 2>/dev/null; then
        log_error "[Critic] Invalid JSON in worker spec: $worker_spec_path"
        return 1
    fi

    # Extract worker data
    local worker_data=$(cat "$worker_spec_path")
    local task_id=$(echo "$worker_data" | jq -r '.task_id // "unknown"')
    local status=$(echo "$worker_data" | jq -r '.status')
    local worker_type=$(echo "$worker_data" | jq -r '.worker_type // "unknown"')
    local strategy=$(echo "$worker_data" | jq -r '.strategy // "unknown"')

    # Get timing information
    local created_at=$(echo "$worker_data" | jq -r '.created_at // ""')
    local started_at=$(echo "$worker_data" | jq -r '.started_at // ""')
    local completed_at=$(echo "$worker_data" | jq -r '.completed_at // ""')

    # Calculate duration
    local duration_seconds=0
    if [ -n "$started_at" ] && [ -n "$completed_at" ]; then
        local start_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$started_at" "+%s" 2>/dev/null || echo "0")
        local end_ts=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$completed_at" "+%s" 2>/dev/null || echo "0")
        duration_seconds=$((end_ts - start_ts))
    fi

    # Get token usage
    local token_budget=$(echo "$worker_data" | jq -r '.resources.token_budget // 0')
    local tokens_used=$(echo "$worker_data" | jq -r '.metrics.tokens_used // 0')
    local token_efficiency=0
    if [ "$token_budget" -gt 0 ]; then
        token_efficiency=$(echo "scale=4; $tokens_used / $token_budget" | bc)
    fi

    # Evaluate quality metrics
    local quality_score=$(evaluate_quality_metrics "$worker_id" "$worker_spec_path")

    # Evaluate efficiency metrics
    local efficiency_score=$(evaluate_efficiency_metrics "$duration_seconds" "$token_efficiency")

    # Evaluate success criteria achievement
    local success_score=$(evaluate_success_criteria "$worker_id" "$worker_spec_path")

    # Classify outcome
    local outcome_classification=$(classify_outcome "$status" "$quality_score" "$success_score")

    # Calculate overall performance score (0-100)
    local overall_score=$(calculate_overall_score "$quality_score" "$efficiency_score" "$success_score")

    # Build evaluation result
    local evaluation=$(jq -n \
        --arg worker_id "$worker_id" \
        --arg task_id "$task_id" \
        --arg worker_type "$worker_type" \
        --arg strategy "$strategy" \
        --arg status "$status" \
        --argjson duration "$duration_seconds" \
        --argjson token_budget "$token_budget" \
        --argjson tokens_used "$tokens_used" \
        --arg token_efficiency "$token_efficiency" \
        --argjson quality_score "$quality_score" \
        --argjson efficiency_score "$efficiency_score" \
        --argjson success_score "$success_score" \
        --argjson overall_score "$overall_score" \
        --arg outcome "$outcome_classification" \
        --arg evaluated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            worker_id: $worker_id,
            task_id: $task_id,
            worker_type: $worker_type,
            strategy: $strategy,
            status: $status,
            metrics: {
                duration_seconds: $duration,
                token_budget: $token_budget,
                tokens_used: $tokens_used,
                token_efficiency: $token_efficiency
            },
            scores: {
                quality: $quality_score,
                efficiency: $efficiency_score,
                success: $success_score,
                overall: $overall_score
            },
            outcome_classification: $outcome,
            evaluated_at: $evaluated_at
        }')

    # Log evaluation
    log_info "[Critic] Evaluation complete: $worker_id (score: $overall_score/100, outcome: $outcome_classification)"

    # Record metric
    record_evaluation_metric "$overall_score" "$outcome_classification"

    echo "$evaluation"
}

#------------------------------------------------------------------------------
# evaluate_quality_metrics()
# Assess code quality, test coverage, documentation quality
#
# Args:
#   $1 - worker_id
#   $2 - worker_spec_path
#
# Returns:
#   Quality score (0-100)
#------------------------------------------------------------------------------
evaluate_quality_metrics() {
    local worker_id="$1"
    local worker_spec_path="$2"

    local worker_data=$(cat "$worker_spec_path")
    local quality_score=50  # Default baseline

    # Check for test execution
    local tests_run=$(echo "$worker_data" | jq -r '.metrics.tests_run // 0')
    local tests_passed=$(echo "$worker_data" | jq -r '.metrics.tests_passed // 0')

    if [ "$tests_run" -gt 0 ]; then
        local test_pass_rate=$(echo "scale=2; ($tests_passed / $tests_run) * 100" | bc)
        quality_score=$(echo "scale=0; $quality_score + ($test_pass_rate * 0.3)" | bc)
    fi

    # Check for code quality indicators
    local linting_passed=$(echo "$worker_data" | jq -r '.metrics.linting_passed // false')
    if [ "$linting_passed" = "true" ]; then
        quality_score=$(echo "$quality_score + 10" | bc)
    fi

    # Check for documentation
    local documentation_created=$(echo "$worker_data" | jq -r '.metrics.documentation_created // false')
    if [ "$documentation_created" = "true" ]; then
        quality_score=$(echo "$quality_score + 10" | bc)
    fi

    # Check for error-free execution
    local errors=$(echo "$worker_data" | jq -r '.metrics.errors // 0')
    if [ "$errors" -eq 0 ]; then
        quality_score=$(echo "$quality_score + 10" | bc)
    else
        # Penalize errors
        local penalty=$(echo "scale=0; $errors * 5" | bc)
        quality_score=$(echo "$quality_score - $penalty" | bc)
    fi

    # Ensure score is in valid range [0-100]
    if (( $(echo "$quality_score < 0" | bc -l) )); then
        quality_score=0
    elif (( $(echo "$quality_score > 100" | bc -l) )); then
        quality_score=100
    fi

    echo "${quality_score%.*}"  # Return as integer
}

#------------------------------------------------------------------------------
# evaluate_efficiency_metrics()
# Assess time efficiency and token usage efficiency
#
# Args:
#   $1 - duration_seconds
#   $2 - token_efficiency (0.0-1.0+)
#
# Returns:
#   Efficiency score (0-100)
#------------------------------------------------------------------------------
evaluate_efficiency_metrics() {
    local duration="$1"
    local token_efficiency="$2"

    local efficiency_score=50  # Baseline

    # Time efficiency: reward fast execution (< 300s = 5min)
    if [ "$duration" -lt 300 ]; then
        efficiency_score=$(echo "$efficiency_score + 20" | bc)
    elif [ "$duration" -lt 600 ]; then
        efficiency_score=$(echo "$efficiency_score + 10" | bc)
    elif [ "$duration" -gt 1800 ]; then
        # Penalize very slow (>30min)
        efficiency_score=$(echo "$efficiency_score - 20" | bc)
    fi

    # Token efficiency: reward efficient use of tokens
    # token_efficiency < 0.8 means used <80% of budget (good)
    if (( $(echo "$token_efficiency < 0.8" | bc -l) )); then
        efficiency_score=$(echo "$efficiency_score + 20" | bc)
    elif (( $(echo "$token_efficiency > 0.95" | bc -l) )); then
        # Near budget exhaustion
        efficiency_score=$(echo "$efficiency_score - 10" | bc)
    fi

    # Clamp to [0-100]
    if (( $(echo "$efficiency_score < 0" | bc -l) )); then
        efficiency_score=0
    elif (( $(echo "$efficiency_score > 100" | bc -l) )); then
        efficiency_score=100
    fi

    echo "${efficiency_score%.*}"
}

#------------------------------------------------------------------------------
# evaluate_success_criteria()
# Check if worker achieved its success criteria
#
# Args:
#   $1 - worker_id
#   $2 - worker_spec_path
#
# Returns:
#   Success score (0-100)
#------------------------------------------------------------------------------
evaluate_success_criteria() {
    local worker_id="$1"
    local worker_spec_path="$2"

    local worker_data=$(cat "$worker_spec_path")
    local status=$(echo "$worker_data" | jq -r '.status')

    # Base score on status
    case "$status" in
        completed)
            echo "100"
            ;;
        partial)
            echo "50"
            ;;
        failed)
            echo "0"
            ;;
        *)
            echo "25"  # Unknown status
            ;;
    esac
}

#------------------------------------------------------------------------------
# classify_outcome()
# Categorize the worker outcome
#
# Args:
#   $1 - status
#   $2 - quality_score
#   $3 - success_score
#
# Returns:
#   Outcome classification string
#------------------------------------------------------------------------------
classify_outcome() {
    local status="$1"
    local quality_score="$2"
    local success_score="$3"

    if [ "$status" = "completed" ] && [ "$quality_score" -ge 70 ] && [ "$success_score" -ge 80 ]; then
        echo "success_high_quality"
    elif [ "$status" = "completed" ] && [ "$success_score" -ge 80 ]; then
        echo "success_standard"
    elif [ "$status" = "partial" ]; then
        echo "partial_completion"
    elif [ "$status" = "failed" ]; then
        echo "failure"
    else
        echo "unknown"
    fi
}

#------------------------------------------------------------------------------
# calculate_overall_score()
# Weighted combination of quality, efficiency, success scores
#
# Args:
#   $1 - quality_score
#   $2 - efficiency_score
#   $3 - success_score
#
# Returns:
#   Overall score (0-100)
#------------------------------------------------------------------------------
calculate_overall_score() {
    local quality="$1"
    local efficiency="$2"
    local success="$3"

    # Weights: success 50%, quality 30%, efficiency 20%
    local overall=$(echo "scale=2; ($success * 0.5) + ($quality * 0.3) + ($efficiency * 0.2)" | bc)

    echo "${overall%.*}"
}

#------------------------------------------------------------------------------
# generate_training_examples()
# Extract learnings from worker execution
#
# Args:
#   $1 - evaluation_json: Output from evaluate_worker_performance()
#   $2 - worker_spec_path: Path to worker spec
#
# Returns:
#   Training example file path
#------------------------------------------------------------------------------
generate_training_examples() {
    local evaluation_json="$1"
    local worker_spec_path="$2"

    local worker_id=$(echo "$evaluation_json" | jq -r '.worker_id')
    local task_id=$(echo "$evaluation_json" | jq -r '.task_id')
    local outcome=$(echo "$evaluation_json" | jq -r '.outcome_classification')
    local overall_score=$(echo "$evaluation_json" | jq -r '.scores.overall')

    log_info "[Critic] Generating training examples from worker: $worker_id"

    # Extract context
    local worker_data=$(cat "$worker_spec_path")
    local context=$(echo "$worker_data" | jq '{
        task_type: .task_type,
        worker_type: .worker_type,
        strategy: .strategy,
        complexity: .complexity,
        priority: .priority,
        context: .context
    }')

    # Extract action (what the worker did)
    local action=$(echo "$worker_data" | jq '{
        strategy_used: .strategy,
        worker_type: .worker_type,
        approach: .approach,
        tools_used: .tools_used
    }')

    # Extract outcome
    local outcome_data=$(echo "$evaluation_json" | jq '{
        status: .status,
        classification: .outcome_classification,
        scores: .scores,
        metrics: .metrics
    }')

    # Determine if this is a positive or negative example
    local example_type="negative"
    if [ "$overall_score" -ge 70 ]; then
        example_type="positive"
    fi

    # Create training example
    local training_example=$(jq -n \
        --arg example_id "example-$(date +%s)-$(uuidgen | cut -d- -f1)" \
        --arg worker_id "$worker_id" \
        --arg task_id "$task_id" \
        --arg example_type "$example_type" \
        --argjson overall_score "$overall_score" \
        --argjson context "$context" \
        --argjson action "$action" \
        --argjson outcome "$outcome_data" \
        --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            example_id: $example_id,
            worker_id: $worker_id,
            task_id: $task_id,
            example_type: $example_type,
            overall_score: $overall_score,
            context: $context,
            action: $action,
            outcome: $outcome,
            created_at: $created_at
        }')

    # Write to training examples (append to JSONL)
    local training_file="$TRAINING_EXAMPLES_DIR/training-examples.jsonl"
    echo "$training_example" >> "$training_file"

    log_info "[Critic] Training example created: $example_type (score: $overall_score)"

    # Also categorize by outcome type for easier retrieval
    local category_file="$TRAINING_EXAMPLES_DIR/${example_type}-examples.jsonl"
    echo "$training_example" >> "$category_file"

    echo "$training_file"
}

#------------------------------------------------------------------------------
# score_execution()
# Simplified scoring interface (delegates to evaluate_worker_performance)
#
# Args:
#   $1 - worker_spec_path
#
# Returns:
#   Numeric score (0-100)
#------------------------------------------------------------------------------
score_execution() {
    local worker_spec_path="$1"
    local worker_id=$(jq -r '.worker_id' "$worker_spec_path")

    local evaluation=$(evaluate_worker_performance "$worker_id" "$worker_spec_path")
    echo "$evaluation" | jq -r '.scores.overall'
}

#------------------------------------------------------------------------------
# create_feedback_report()
# Generate structured feedback for the worker execution
#
# Args:
#   $1 - evaluation_json: Output from evaluate_worker_performance()
#   $2 - worker_spec_path: Path to worker spec
#
# Returns:
#   Feedback report file path
#------------------------------------------------------------------------------
create_feedback_report() {
    local evaluation_json="$1"
    local worker_spec_path="$2"

    local worker_id=$(echo "$evaluation_json" | jq -r '.worker_id')
    local overall_score=$(echo "$evaluation_json" | jq -r '.scores.overall')
    local quality_score=$(echo "$evaluation_json" | jq -r '.scores.quality')
    local efficiency_score=$(echo "$evaluation_json" | jq -r '.scores.efficiency')
    local success_score=$(echo "$evaluation_json" | jq -r '.scores.success')
    local outcome=$(echo "$evaluation_json" | jq -r '.outcome_classification')

    log_info "[Critic] Creating feedback report for worker: $worker_id"

    # Generate what worked well
    local strengths=()
    if [ "$quality_score" -ge 70 ]; then
        strengths+=("High quality output with good test coverage")
    fi
    if [ "$efficiency_score" -ge 70 ]; then
        strengths+=("Efficient execution with good time and token usage")
    fi
    if [ "$success_score" -ge 80 ]; then
        strengths+=("Successfully achieved task objectives")
    fi

    # Generate what could improve
    local improvements=()
    if [ "$quality_score" -lt 70 ]; then
        improvements+=("Improve code quality and test coverage")
    fi
    if [ "$efficiency_score" -lt 70 ]; then
        improvements+=("Optimize execution time and token usage")
    fi
    if [ "$success_score" -lt 80 ]; then
        improvements+=("Better alignment with task success criteria")
    fi

    # Generate recommendations
    local recommendations=()
    case "$outcome" in
        success_high_quality)
            recommendations+=("Excellent performance - use as reference example")
            recommendations+=("Share patterns from this execution with other workers")
            ;;
        success_standard)
            recommendations+=("Good completion - consider quality improvements")
            recommendations+=("Document successful approaches for reuse")
            ;;
        partial_completion)
            recommendations+=("Analyze blocking issues for partial completion")
            recommendations+=("Consider breaking task into smaller subtasks")
            ;;
        failure)
            recommendations+=("Root cause analysis needed for failure")
            recommendations+=("Review strategy selection and resource allocation")
            ;;
    esac

    # Build feedback report
    local strengths_json=$(printf '%s\n' "${strengths[@]}" | jq -R . | jq -s .)
    local improvements_json=$(printf '%s\n' "${improvements[@]}" | jq -R . | jq -s .)
    local recommendations_json=$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .)

    local feedback=$(jq -n \
        --arg worker_id "$worker_id" \
        --argjson overall_score "$overall_score" \
        --arg outcome "$outcome" \
        --argjson strengths "$strengths_json" \
        --argjson improvements "$improvements_json" \
        --argjson recommendations "$recommendations_json" \
        --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            worker_id: $worker_id,
            overall_score: $overall_score,
            outcome_classification: $outcome,
            feedback: {
                strengths: $strengths,
                improvements: $improvements,
                recommendations: $recommendations
            },
            created_at: $created_at
        }')

    # Write feedback report
    local feedback_file="$FEEDBACK_DIR/feedback-$worker_id.json"
    echo "$feedback" > "$feedback_file"

    log_info "[Critic] Feedback report created: $feedback_file"

    echo "$feedback_file"
}

#------------------------------------------------------------------------------
# record_evaluation_metric()
# Record evaluation metrics for learning performance tracking
#
# Args:
#   $1 - overall_score
#   $2 - outcome_classification
#------------------------------------------------------------------------------
record_evaluation_metric() {
    local score="$1"
    local outcome="$2"

    local metric=$(jq -n \
        --argjson score "$score" \
        --arg outcome "$outcome" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            timestamp: $timestamp,
            metric: "worker_evaluation",
            score: $score,
            outcome: $outcome
        }')

    echo "$metric" >> "$LEARNING_METRICS_DIR/evaluations.jsonl"
}

#------------------------------------------------------------------------------
# Main execution (if called directly)
#------------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Example usage
    if [ $# -lt 1 ]; then
        echo "Usage: critic.sh <worker_spec_path>"
        echo ""
        echo "Example:"
        echo "  critic.sh coordination/worker-specs/completed/worker-123.json"
        exit 1
    fi

    worker_spec_path="$1"
    worker_id=$(jq -r '.worker_id' "$worker_spec_path")

    # Evaluate
    evaluation=$(evaluate_worker_performance "$worker_id" "$worker_spec_path")

    # Generate training examples
    generate_training_examples "$evaluation" "$worker_spec_path"

    # Create feedback report
    create_feedback_report "$evaluation" "$worker_spec_path"

    echo "$evaluation" | jq .
fi
