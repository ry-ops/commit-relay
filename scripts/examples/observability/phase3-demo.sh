#!/usr/bin/env bash
#
# Phase 3 Observability and Data Features Demo
#
# Demonstrates:
#   - Trace sampling for high-volume operations
#   - Data lineage tracking
#   - Data quality monitoring
#
# Usage:
#   ./scripts/examples/observability/phase3-demo.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source libraries
source "$PROJECT_ROOT/scripts/lib/observability/trace-sampler.sh"
source "$PROJECT_ROOT/scripts/lib/data-lineage.sh"
source "$PROJECT_ROOT/scripts/lib/data-quality.sh"

echo "========================================"
echo "Phase 3 Observability Features Demo"
echo "========================================"
echo ""

# ==========================================
# Demo 1: Trace Sampling
# ==========================================
echo "--- Demo 1: Trace Sampling ---"
echo ""

# Configure sampling rate
echo "1. Configuring 10% sampling rate..."
set_sampling_rate "10%"
echo "   Current config:"
get_sampling_config | jq .
echo ""

# Generate some traces to demonstrate sampling
echo "2. Generating 10 traces to demonstrate sampling..."
sampled=0
dropped=0

for i in {1..10}; do
    trace_id="demo-trace-$(date +%s%N)-$i"

    if should_sample_trace "$trace_id" '{"priority": "normal"}'; then
        sampled=$((sampled + 1))
    else
        dropped=$((dropped + 1))
    fi
done

echo "   Results: $sampled sampled, $dropped dropped"
echo ""

# Demonstrate always sampling errors
echo "3. Demonstrating priority-based sampling (high priority always sampled)..."
trace_id="high-priority-trace-$(date +%s%N)"

if should_sample_trace "$trace_id" '{"priority": "critical"}'; then
    echo "   Critical priority trace: SAMPLED (as expected)"
else
    echo "   Critical priority trace: DROPPED (unexpected)"
fi
echo ""

# Show sampling statistics
echo "4. Sampling statistics:"
get_sampling_stats | jq .
echo ""

# ==========================================
# Demo 2: Data Lineage Tracking
# ==========================================
echo "--- Demo 2: Data Lineage Tracking ---"
echo ""

# Register data sources
echo "1. Registering data sources..."
register_data_source "task-queue" "coordination/task-queue.json" "file" '{"format": "jsonl"}'
register_data_source "worker-pool" "coordination/worker-pool.json" "file" '{"format": "json"}'
register_data_source "external-api" "https://api.example.com/tasks" "api" '{"auth": "bearer"}'
echo "   Registered 3 data sources"
echo ""

# Start lineage tracking
echo "2. Starting lineage tracking for worker spawning operation..."
lineage_id=$(start_lineage_tracking "spawn_worker" "demo-trace-001")
echo "   Lineage ID: $lineage_id"
echo ""

# Track inputs
echo "3. Tracking data inputs..."
track_data_input "task-queue" "task-123" '{"record_type": "task"}'
track_data_input "worker-pool" "" '{"query": "available_workers"}'
echo "   Tracked 2 input sources"
echo ""

# Track transformations
echo "4. Tracking transformations..."
track_transformation "filter_by_priority" "Filtered tasks by high priority" '{"filter": "priority >= high"}'
track_transformation "select_worker" "Selected best available worker" '{"algorithm": "round_robin"}'
echo "   Tracked 2 transformations"
echo ""

# Track output
echo "5. Tracking data output..."
track_data_output "worker-spec-001" "coordination/worker-specs/worker-impl-demo.json" '{"worker_type": "implementation"}'
echo "   Tracked output: worker-spec-001"
echo ""

# End lineage tracking
echo "6. Ending lineage tracking..."
end_lineage_tracking "success" "Worker successfully spawned from task"
echo "   Lineage tracking completed"
echo ""

# Query lineage
echo "7. Querying lineage statistics:"
get_lineage_stats | jq .
echo ""

# Generate lineage graph
echo "8. Generating lineage graph..."
graph_file=$(export_lineage_to_dot "all")
echo "   Graph exported to: $graph_file"
echo ""

# ==========================================
# Demo 3: Data Quality Monitoring
# ==========================================
echo "--- Demo 3: Data Quality Monitoring ---"
echo ""

# Register schema
echo "1. Registering task schema..."
TASK_SCHEMA='{
    "type": "object",
    "required": ["task_id", "status", "priority"],
    "properties": {
        "task_id": {"type": "string"},
        "status": {"type": "string", "enum": ["pending", "active", "completed", "failed"]},
        "priority": {"type": "number"},
        "description": {"type": "string"}
    }
}'
register_schema "task-data" "$TASK_SCHEMA" "Task queue entry schema"
echo "   Schema registered for 'task-data'"
echo ""

# Validate valid data
echo "2. Validating valid task data..."
VALID_TASK='{
    "task_id": "task-123",
    "status": "pending",
    "priority": 5,
    "description": "Implement new feature"
}'
result=$(validate_data "task-data" "$VALID_TASK")
echo "   Result: $(echo "$result" | jq -r 'if .valid then "VALID" else "INVALID" end')"
echo ""

# Validate invalid data
echo "3. Validating invalid task data (missing required field)..."
INVALID_TASK='{
    "task_id": "task-456",
    "description": "Missing status and priority"
}'
result=$(validate_data "task-data" "$INVALID_TASK" 2>&1 || true)
echo "   Result: $(echo "$result" | jq -r 'if .valid then "VALID" else "INVALID: " + (.errors | join(", ")) end')"
echo ""

# Validate data with enum violation
echo "4. Validating task with invalid enum value..."
BAD_ENUM_TASK='{
    "task_id": "task-789",
    "status": "unknown",
    "priority": 3
}'
result=$(validate_data "task-data" "$BAD_ENUM_TASK" 2>&1 || true)
echo "   Result: $(echo "$result" | jq -r 'if .valid then "VALID" else "INVALID: " + (.errors | join(", ")) end')"
echo ""

# Check for required fields
echo "5. Checking required fields..."
result=$(check_required_fields '{"name": "test", "value": 42}' "name,value,missing_field")
echo "   Result: $(echo "$result" | jq -c '.')"
echo ""

# Detect anomalies
echo "6. Anomaly detection for numeric field..."
echo "   Training with normal values (10-20 range)..."
for val in 15 12 18 14 16 13 17 15 14 16 12 18 15 13 17 14 16 15 18 12 14 16 15 13 17 15 14 16 18 12; do
    detect_anomaly "test-source" "response_time" "$val" > /dev/null
done

echo "   Testing value 15 (normal):"
result=$(detect_anomaly "test-source" "response_time" 15)
echo "   $(echo "$result" | jq -r 'if .is_anomaly then "ANOMALY" else "NORMAL" end')"

echo "   Testing value 50 (potential anomaly):"
result=$(detect_anomaly "test-source" "response_time" 50)
echo "   $(echo "$result" | jq -r 'if .is_anomaly then "ANOMALY: " + .reason else "NORMAL" end')"
echo ""

# Get quality scores
echo "7. Quality scores:"
get_all_quality_scores | jq .
echo ""

# Get quality summary
echo "8. Quality summary:"
get_quality_summary | jq .
echo ""

# Get recent alerts
echo "9. Recent quality alerts:"
alerts=$(get_quality_alerts 5)
if [[ "$alerts" == "[]" ]]; then
    echo "   No alerts generated"
else
    echo "$alerts" | jq .
fi
echo ""

# ==========================================
# Integration Example
# ==========================================
echo "--- Integration Example: Full Pipeline ---"
echo ""

echo "Demonstrating integrated use of all three features..."
echo ""

# Set up sampling
export TRACE_SAMPLING_RATE="1.0"  # 100% for demo
export ENABLE_LINEAGE_TRACKING="true"
export ENABLE_QUALITY_MONITORING="true"

# Start a sampled trace with lineage
echo "1. Creating sampled trace..."
demo_trace=$(create_sampled_trace "task_processing" '{"task_id": "task-integration-demo"}')
echo "   Trace: $demo_trace"

# Start lineage tracking linked to trace
echo "2. Starting lineage tracking..."
lineage=$(start_lineage_tracking "process_task" "$demo_trace")
echo "   Lineage: $lineage"

# Validate incoming data
echo "3. Validating task data..."
DEMO_TASK='{
    "task_id": "task-integration-demo",
    "status": "pending",
    "priority": 8,
    "description": "Integration test task"
}'
validation=$(validate_data "task-data" "$DEMO_TASK")
echo "   Validation: $(echo "$validation" | jq -r 'if .valid then "PASSED" else "FAILED" end')"

# Track input
echo "4. Recording input in lineage..."
track_data_input "task-data" "task-integration-demo" '{"validated": true}'

# Track transformation
echo "5. Recording transformation..."
track_transformation "priority_boost" "Increased priority for urgent task" '{"old": 8, "new": 10}'

# Track output
echo "6. Recording output..."
track_data_output "processed-task" "coordination/tasks/processed/task-integration-demo.json" '{"format": "json"}'

# End lineage
echo "7. Completing lineage tracking..."
end_lineage_tracking "success" "Task processing completed successfully"

echo ""
echo "Integration demo complete!"
echo ""

# Final summary
echo "========================================"
echo "Demo Summary"
echo "========================================"
echo ""
echo "Files created:"
echo "  - Sampling stats: coordination/observability/sampler/sampling-stats.json"
echo "  - Lineage events: coordination/observability/lineage/lineage-events.jsonl"
echo "  - Lineage graph: coordination/observability/lineage/graphs/lineage-all.dot"
echo "  - Quality metrics: coordination/observability/quality/quality-metrics.jsonl"
echo "  - Quality scores: coordination/observability/quality/quality-scores.json"
echo ""
echo "To visualize the lineage graph:"
echo "  dot -Tpng coordination/observability/lineage/graphs/lineage-all.dot -o lineage.png"
echo ""
echo "Demo completed successfully!"
