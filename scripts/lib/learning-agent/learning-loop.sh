#!/usr/bin/env bash
#
# Learning Loop Integration Script
# Part of Q1 Week 5: Learning Agent (Complete Learning Cycle)
#
# Provides the complete learning loop that:
# 1. Monitors completed workers
# 2. Triggers critic evaluation
# 3. Generates training examples
# 4. Feeds into MoE learning daemon
#
# This script integrates critic.sh with the broader learning system
# to enable continuous improvement of the agent system.
#
# Usage:
#   source scripts/lib/learning-agent/learning-loop.sh
#   process_completed_worker "$worker_spec_path"
#   run_learning_cycle
#   export_training_batch

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Source dependencies
source "$SCRIPT_DIR/critic.sh"
source "$COMMIT_RELAY_HOME/scripts/lib/logging.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
}

# Directories
readonly COMPLETED_WORKERS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/completed"
readonly PROCESSED_WORKERS_DIR="$COMMIT_RELAY_HOME/coordination/worker-specs/processed"
readonly TRAINING_EXAMPLES_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-examples"
readonly MOE_LEARNING_DIR="$COMMIT_RELAY_HOME/coordination/masters/coordinator/knowledge-base"
readonly LEARNING_STATE_FILE="$COMMIT_RELAY_HOME/coordination/metrics/learning/learning-state.json"
readonly TRAINING_BATCH_DIR="$COMMIT_RELAY_HOME/coordination/knowledge-base/training-batches"

# Ensure directories exist
mkdir -p "$COMPLETED_WORKERS_DIR" "$PROCESSED_WORKERS_DIR" "$TRAINING_EXAMPLES_DIR" "$TRAINING_BATCH_DIR"
mkdir -p "$(dirname "$LEARNING_STATE_FILE")"

#------------------------------------------------------------------------------
# Learning State Management
#------------------------------------------------------------------------------

# Initialize learning state
init_learning_state() {
    if [ ! -f "$LEARNING_STATE_FILE" ]; then
        jq -n '{
            last_run: null,
            total_workers_processed: 0,
            total_training_examples: 0,
            positive_examples: 0,
            negative_examples: 0,
            current_batch_id: null,
            batches_exported: 0,
            avg_quality_score: 0,
            learning_metrics: {
                improvements_detected: 0,
                regressions_detected: 0,
                patterns_learned: 0
            },
            created_at: (now | todate),
            updated_at: (now | todate)
        }' > "$LEARNING_STATE_FILE"
    fi
}

# Update learning state
update_learning_state() {
    local updates="$1"

    local temp_file=$(mktemp)
    jq --argjson updates "$updates" \
       '. + $updates + {updated_at: (now | todate)}' \
       "$LEARNING_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$LEARNING_STATE_FILE"
}

# Get learning state
get_learning_state() {
    cat "$LEARNING_STATE_FILE"
}

#------------------------------------------------------------------------------
# Worker Processing
#------------------------------------------------------------------------------

# Process a single completed worker
process_completed_worker() {
    local worker_spec_path="$1"

    if [ ! -f "$worker_spec_path" ]; then
        log_error "[Learning] Worker spec not found: $worker_spec_path"
        return 1
    fi

    local worker_id=$(jq -r '.worker_id' "$worker_spec_path")
    log_info "[Learning] Processing completed worker: $worker_id"

    # Step 1: Evaluate with critic
    local evaluation=$(evaluate_worker_performance "$worker_id" "$worker_spec_path")

    if [ -z "$evaluation" ]; then
        log_error "[Learning] Failed to evaluate worker: $worker_id"
        return 1
    fi

    # Step 2: Generate training examples
    local training_file=$(generate_training_examples "$evaluation" "$worker_spec_path")

    # Step 3: Create feedback report
    local feedback_file=$(create_feedback_report "$evaluation" "$worker_spec_path")

    # Step 4: Extract patterns for MoE learning
    extract_learning_patterns "$evaluation" "$worker_spec_path"

    # Step 5: Update learning state
    local overall_score=$(echo "$evaluation" | jq -r '.scores.overall')
    local example_type="negative"
    [ "$overall_score" -ge 70 ] && example_type="positive"

    update_learning_state "{
        \"total_workers_processed\": $(jq -r '.total_workers_processed + 1' "$LEARNING_STATE_FILE"),
        \"total_training_examples\": $(jq -r '.total_training_examples + 1' "$LEARNING_STATE_FILE"),
        \"${example_type}_examples\": $(jq -r ".${example_type}_examples + 1" "$LEARNING_STATE_FILE"),
        \"last_run\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }"

    # Step 6: Move to processed
    local processed_file="$PROCESSED_WORKERS_DIR/$(basename "$worker_spec_path")"
    mv "$worker_spec_path" "$processed_file"

    log_info "[Learning] Processed worker $worker_id (score: $overall_score, type: $example_type)"
    echo "$evaluation"
}

# Process all pending completed workers
process_all_completed_workers() {
    log_info "[Learning] Processing all completed workers..."

    local count=0
    for worker_file in "$COMPLETED_WORKERS_DIR"/*.json; do
        [ -f "$worker_file" ] || continue

        process_completed_worker "$worker_file" || true
        count=$((count + 1))
    done

    log_info "[Learning] Processed $count workers"
    echo "$count"
}

#------------------------------------------------------------------------------
# Pattern Extraction for MoE
#------------------------------------------------------------------------------

# Extract learning patterns from evaluation
extract_learning_patterns() {
    local evaluation="$1"
    local worker_spec_path="$2"

    local worker_data=$(cat "$worker_spec_path")
    local worker_type=$(echo "$worker_data" | jq -r '.worker_type // "unknown"')
    local strategy=$(echo "$worker_data" | jq -r '.strategy // "unknown"')
    local task_type=$(echo "$worker_data" | jq -r '.task_type // "unknown"')
    local outcome=$(echo "$evaluation" | jq -r '.outcome_classification')
    local overall_score=$(echo "$evaluation" | jq -r '.scores.overall')

    # Create pattern entry for MoE learning
    local pattern=$(jq -n \
        --arg worker_type "$worker_type" \
        --arg strategy "$strategy" \
        --arg task_type "$task_type" \
        --arg outcome "$outcome" \
        --argjson score "$overall_score" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            pattern_type: "execution_outcome",
            worker_type: $worker_type,
            strategy: $strategy,
            task_type: $task_type,
            outcome: $outcome,
            score: $score,
            timestamp: $timestamp,
            success: ($score >= 70)
        }')

    # Append to MoE patterns file
    local patterns_file="$MOE_LEARNING_DIR/execution-patterns.jsonl"
    mkdir -p "$(dirname "$patterns_file")"
    echo "$pattern" >> "$patterns_file"

    # If high score, also record as successful strategy
    if [ "$overall_score" -ge 80 ]; then
        local success_pattern=$(jq -n \
            --arg worker_type "$worker_type" \
            --arg strategy "$strategy" \
            --arg task_type "$task_type" \
            --argjson score "$overall_score" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{
                strategy: $strategy,
                worker_type: $worker_type,
                task_type: $task_type,
                score: $score,
                timestamp: $timestamp
            }')

        echo "$success_pattern" >> "$MOE_LEARNING_DIR/successful-strategies.jsonl"
    fi
}

#------------------------------------------------------------------------------
# Training Batch Management
#------------------------------------------------------------------------------

# Create a training batch from accumulated examples
create_training_batch() {
    local batch_size="${1:-100}"

    local batch_id="batch-$(date +%Y%m%d%H%M%S)-$(uuidgen | cut -d- -f1)"
    local batch_file="$TRAINING_BATCH_DIR/${batch_id}.jsonl"

    log_info "[Learning] Creating training batch: $batch_id"

    # Collect examples from training file
    local training_file="$TRAINING_EXAMPLES_DIR/training-examples.jsonl"

    if [ ! -f "$training_file" ]; then
        log_warn "[Learning] No training examples available"
        return 1
    fi

    # Take top N examples
    head -n "$batch_size" "$training_file" > "$batch_file"

    # Count examples
    local example_count=$(wc -l < "$batch_file" | tr -d ' ')
    local positive_count=$(grep -c '"example_type":"positive"' "$batch_file" || echo "0")
    local negative_count=$(grep -c '"example_type":"negative"' "$batch_file" || echo "0")

    # Create batch metadata
    local metadata=$(jq -n \
        --arg batch_id "$batch_id" \
        --argjson example_count "$example_count" \
        --argjson positive_count "$positive_count" \
        --argjson negative_count "$negative_count" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            batch_id: $batch_id,
            example_count: $example_count,
            positive_count: $positive_count,
            negative_count: $negative_count,
            balance_ratio: (if $example_count > 0 then ($positive_count / $example_count) else 0 end),
            status: "ready",
            created_at: $created_at
        }')

    echo "$metadata" > "$TRAINING_BATCH_DIR/${batch_id}-metadata.json"

    # Remove used examples from source file
    tail -n +$((batch_size + 1)) "$training_file" > "${training_file}.tmp"
    mv "${training_file}.tmp" "$training_file"

    # Update learning state
    update_learning_state "{
        \"current_batch_id\": \"$batch_id\",
        \"batches_exported\": $(jq -r '.batches_exported + 1' "$LEARNING_STATE_FILE")
    }"

    log_info "[Learning] Created batch $batch_id with $example_count examples ($positive_count positive, $negative_count negative)"
    echo "$batch_id"
}

# Export training batch for MoE daemon
export_training_batch() {
    local batch_id="${1:-$(jq -r '.current_batch_id // empty' "$LEARNING_STATE_FILE")}"

    if [ -z "$batch_id" ]; then
        batch_id=$(create_training_batch)
    fi

    local batch_file="$TRAINING_BATCH_DIR/${batch_id}.jsonl"
    local export_file="$MOE_LEARNING_DIR/training-batch-${batch_id}.jsonl"

    if [ ! -f "$batch_file" ]; then
        log_error "[Learning] Batch not found: $batch_id"
        return 1
    fi

    cp "$batch_file" "$export_file"
    log_info "[Learning] Exported batch $batch_id to MoE learning directory"

    echo "$export_file"
}

#------------------------------------------------------------------------------
# Learning Cycle
#------------------------------------------------------------------------------

# Run complete learning cycle
run_learning_cycle() {
    log_info "[Learning] Starting learning cycle..."

    init_learning_state

    # Step 1: Process all completed workers
    local workers_processed=$(process_all_completed_workers)

    if [ "$workers_processed" -gt 0 ]; then
        # Step 2: Calculate learning metrics
        calculate_learning_metrics

        # Step 3: Create training batch if enough examples
        local example_count=$(wc -l < "$TRAINING_EXAMPLES_DIR/training-examples.jsonl" 2>/dev/null | tr -d ' ' || echo "0")

        if [ "$example_count" -ge 50 ]; then
            create_training_batch 50
            export_training_batch
        fi

        # Step 4: Update MoE patterns
        update_moe_patterns
    fi

    # Get summary
    local state=$(get_learning_state)

    log_info "[Learning] Cycle complete - Workers: $workers_processed, Total examples: $(echo "$state" | jq -r '.total_training_examples')"
    echo "$state"
}

#------------------------------------------------------------------------------
# Learning Metrics
#------------------------------------------------------------------------------

# Calculate and update learning metrics
calculate_learning_metrics() {
    local evaluations_file="$COMMIT_RELAY_HOME/coordination/metrics/learning/evaluations.jsonl"

    if [ ! -f "$evaluations_file" ]; then
        return 0
    fi

    # Calculate metrics from recent evaluations
    local metrics=$(tail -100 "$evaluations_file" | jq -s '
        {
            sample_count: length,
            avg_score: (if length > 0 then (map(.score) | add / length) else 0 end),
            success_rate: (if length > 0 then ([.[] | select(.outcome | test("success"))] | length) / length else 0 end),
            high_quality_rate: (if length > 0 then ([.[] | select(.score >= 80)] | length) / length else 0 end)
        }')

    local avg_score=$(echo "$metrics" | jq -r '.avg_score')

    update_learning_state "{
        \"avg_quality_score\": $avg_score
    }"

    echo "$metrics"
}

# Update MoE patterns from learning
update_moe_patterns() {
    local patterns_file="$MOE_LEARNING_DIR/execution-patterns.jsonl"

    if [ ! -f "$patterns_file" ]; then
        return 0
    fi

    # Aggregate patterns by strategy and worker type
    local aggregated=$(tail -500 "$patterns_file" | jq -s '
        group_by(.strategy + "_" + .worker_type) |
        map({
            key: (.[0].strategy + "_" + .[0].worker_type),
            strategy: .[0].strategy,
            worker_type: .[0].worker_type,
            sample_count: length,
            avg_score: (map(.score) | add / length),
            success_rate: ([.[] | select(.success)] | length) / length
        }) |
        sort_by(-.success_rate)')

    # Write aggregated patterns
    echo "$aggregated" > "$MOE_LEARNING_DIR/aggregated-patterns.json"
}

#------------------------------------------------------------------------------
# Quality Analysis
#------------------------------------------------------------------------------

# Analyze quality trends
analyze_quality_trends() {
    local window_days="${1:-7}"

    local evaluations_file="$COMMIT_RELAY_HOME/coordination/metrics/learning/evaluations.jsonl"

    if [ ! -f "$evaluations_file" ]; then
        echo '{"error": "No evaluations available"}'
        return 1
    fi

    # Calculate daily averages
    cat "$evaluations_file" | jq -s --argjson days "$window_days" '
        sort_by(.timestamp) |
        group_by(.timestamp | split("T")[0]) |
        .[-$days:] |
        map({
            date: .[0].timestamp | split("T")[0],
            sample_count: length,
            avg_score: (map(.score) | add / length),
            success_rate: ([.[] | select(.outcome | test("success"))] | length) / length
        })'
}

# Detect improvement or regression
detect_quality_changes() {
    local trends=$(analyze_quality_trends 14)
    local count=$(echo "$trends" | jq 'length')

    if [ "$count" -lt 2 ]; then
        echo '{"status": "insufficient_data"}'
        return 0
    fi

    # Compare recent to historical
    local recent_avg=$(echo "$trends" | jq '[-3:] | map(.avg_score) | add / length')
    local historical_avg=$(echo "$trends" | jq '[:-3] | map(.avg_score) | add / length')

    local change=$(echo "scale=4; ($recent_avg - $historical_avg) / $historical_avg * 100" | bc 2>/dev/null || echo "0")

    local status="stable"
    if [ "$(echo "$change > 5" | bc -l)" -eq 1 ]; then
        status="improving"
    elif [ "$(echo "$change < -5" | bc -l)" -eq 1 ]; then
        status="regressing"
    fi

    jq -n \
        --arg status "$status" \
        --argjson recent_avg "$recent_avg" \
        --argjson historical_avg "$historical_avg" \
        --arg change_percent "$change" \
        '{
            status: $status,
            recent_avg: $recent_avg,
            historical_avg: $historical_avg,
            change_percent: ($change_percent | tonumber)
        }'
}

#------------------------------------------------------------------------------
# Export Functions
#------------------------------------------------------------------------------

export -f init_learning_state
export -f update_learning_state
export -f get_learning_state
export -f process_completed_worker
export -f process_all_completed_workers
export -f extract_learning_patterns
export -f create_training_batch
export -f export_training_batch
export -f run_learning_cycle
export -f calculate_learning_metrics
export -f update_moe_patterns
export -f analyze_quality_trends
export -f detect_quality_changes

#------------------------------------------------------------------------------
# CLI Interface
#------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-help}" in
        process)
            if [ -n "${2:-}" ]; then
                process_completed_worker "$2"
            else
                process_all_completed_workers
            fi
            ;;
        cycle)
            run_learning_cycle
            ;;
        batch)
            create_training_batch "${2:-100}"
            ;;
        export)
            export_training_batch "${2:-}"
            ;;
        state)
            get_learning_state
            ;;
        trends)
            analyze_quality_trends "${2:-7}"
            ;;
        changes)
            detect_quality_changes
            ;;
        help|*)
            echo "Learning Loop Integration"
            echo ""
            echo "Usage: learning-loop.sh <command> [args]"
            echo ""
            echo "Commands:"
            echo "  process [path]     Process completed worker(s)"
            echo "  cycle              Run complete learning cycle"
            echo "  batch [size]       Create training batch"
            echo "  export [batch_id]  Export batch for MoE learning"
            echo "  state              Show learning state"
            echo "  trends [days]      Analyze quality trends"
            echo "  changes            Detect quality changes"
            ;;
    esac
fi
