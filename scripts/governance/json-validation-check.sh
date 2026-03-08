#!/bin/bash
# Governance Compliance Check: JSON Validation
# Validates all critical JSON files in the coordination system
# Returns: 0 if all valid, 1 if validation errors found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$PROJECT_ROOT/scripts/lib/json-validator.sh"

# Source the JSON validator
if [ ! -f "$VALIDATOR" ]; then
    echo "ERROR: JSON validator not found at $VALIDATOR"
    exit 1
fi

source "$VALIDATOR"

# Output file for compliance report
OUTPUT_FILE="${1:-/tmp/json-validation-compliance.json}"

echo "Running JSON validation compliance check..."

# Initialize compliance report
validation_errors=0
total_files=0
files_checked=()
files_with_errors=()

# Check worker specs
echo "Checking worker specs..."
worker_specs=$(ls "$PROJECT_ROOT/coordination/worker-specs/active"/*.json 2>/dev/null || true)
if [ -n "$worker_specs" ]; then
    for spec_file in $worker_specs; do
        total_files=$((total_files + 1))
        spec_name=$(basename "$spec_file")

        # Validate worker spec
        content=$(cat "$spec_file")
        if repaired=$(validate_and_repair_json "$content" 0); then
            if validate_worker_spec "$repaired"; then
                files_checked+=("$spec_name")
            else
                validation_errors=$((validation_errors + 1))
                files_with_errors+=("$spec_name:schema_invalid")
            fi
        else
            validation_errors=$((validation_errors + 1))
            files_with_errors+=("$spec_name:malformed_json")
        fi
    done
fi

# Check task queue
echo "Checking task queue..."
task_queue="$PROJECT_ROOT/coordination/task-queue.json"
if [ -f "$task_queue" ]; then
    total_files=$((total_files + 1))
    content=$(cat "$task_queue")
    if validate_json "$content"; then
        files_checked+=("task-queue.json")
    else
        validation_errors=$((validation_errors + 1))
        files_with_errors+=("task-queue.json:malformed_json")
    fi
fi

# Check critical coordination files
echo "Checking coordination files..."
coord_files=(
    "coordination/pm-state.json"
    "coordination/memory/working/pool-state.json"
    "coordination/orchestrator/state/current.json"
)

for coord_file in "${coord_files[@]}"; do
    full_path="$PROJECT_ROOT/$coord_file"
    if [ -f "$full_path" ]; then
        total_files=$((total_files + 1))
        content=$(cat "$full_path")
        if validate_json "$content"; then
            files_checked+=("$coord_file")
        else
            validation_errors=$((validation_errors + 1))
            files_with_errors+=("$coord_file:malformed_json")
        fi
    fi
done

# Check JSONL files
echo "Checking JSONL files..."
jsonl_files=(
    "coordination/dashboard-events.jsonl"
    "coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl"
)

for jsonl_file in "${jsonl_files[@]}"; do
    full_path="$PROJECT_ROOT/$jsonl_file"
    if [ -f "$full_path" ]; then
        total_files=$((total_files + 1))
        if validate_jsonl_file "$full_path" 0 2>/dev/null; then
            files_checked+=("$jsonl_file")
        else
            validation_errors=$((validation_errors + 1))
            files_with_errors+=("$jsonl_file:invalid_jsonl")
        fi
    fi
done

# Calculate compliance score
compliance_score=0
if [ "$total_files" -gt 0 ]; then
    valid_files=$((total_files - validation_errors))
    compliance_score=$((valid_files * 100 / total_files))
fi

# Determine status
status="pass"
severity="info"
if [ "$validation_errors" -gt 0 ]; then
    status="fail"
    if [ "$validation_errors" -ge 5 ]; then
        severity="critical"
    elif [ "$validation_errors" -ge 3 ]; then
        severity="high"
    else
        severity="medium"
    fi
fi

# Generate compliance report
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
report=$(cat <<EOF
{
  "check_id": "json-validation",
  "check_name": "JSON Validation Compliance",
  "timestamp": "$timestamp",
  "status": "$status",
  "severity": "$severity",
  "summary": {
    "total_files": $total_files,
    "valid_files": $((total_files - validation_errors)),
    "invalid_files": $validation_errors,
    "compliance_score": $compliance_score
  },
  "details": {
    "files_checked": $(if [ ${#files_checked[@]} -gt 0 ]; then printf '%s\n' "${files_checked[@]}" | jq -R . | jq -s .; else echo '[]'; fi),
    "files_with_errors": $(if [ ${#files_with_errors[@]} -gt 0 ]; then printf '%s\n' "${files_with_errors[@]}" | jq -R . | jq -s .; else echo '[]'; fi)
  },
  "recommendations": [
    "Run pre-commit hook to prevent malformed JSON: git config core.hooksPath .githooks",
    "Use JSON validator for repairs: ./scripts/lib/json-validator.sh repair-file <file>",
    "Review worker spec generation in development master"
  ]
}
EOF
)

# Write report
echo "$report" | jq . > "$OUTPUT_FILE"

# Print summary
echo ""
echo "=== JSON Validation Compliance Check ==="
echo "Status: $status"
echo "Compliance Score: $compliance_score%"
echo "Files Checked: $total_files"
echo "Valid Files: $((total_files - validation_errors))"
echo "Invalid Files: $validation_errors"
echo ""
echo "Report written to: $OUTPUT_FILE"

# Return exit code
if [ "$validation_errors" -gt 0 ]; then
    exit 1
else
    exit 0
fi
