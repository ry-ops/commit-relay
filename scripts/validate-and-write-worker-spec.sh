#!/bin/bash
# Validate and Write Worker Spec
# Usage: validate-and-write-worker-spec.sh <worker_spec_json> <output_file>
#
# This script validates a worker spec JSON before writing it to disk.
# If the JSON is malformed, it will attempt to repair it automatically.
# This prevents malformed worker specs from entering the system.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$PROJECT_ROOT/scripts/lib/json-validator.sh"

# Source the JSON validator
if [ ! -f "$VALIDATOR" ]; then
    echo "ERROR: JSON validator not found at $VALIDATOR" >&2
    exit 1
fi

source "$VALIDATOR"

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <worker_spec_json> <output_file>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 '{\"worker_id\": \"dev-worker-123\", ...}' /path/to/worker-spec.json" >&2
    exit 1
fi

WORKER_SPEC_JSON="$1"
OUTPUT_FILE="$2"

# Validate and repair the JSON
if ! repaired=$(validate_and_repair_json "$WORKER_SPEC_JSON" 1); then
    echo "ERROR: Worker spec JSON is malformed and cannot be repaired" >&2
    echo "JSON: $WORKER_SPEC_JSON" >&2
    exit 1
fi

# Validate worker spec schema
if ! validate_worker_spec "$repaired"; then
    echo "ERROR: Worker spec does not match required schema" >&2
    echo "Required fields: worker_id, worker_type, task_id, context, resources, status" >&2
    echo "JSON: $repaired" >&2
    exit 1
fi

# Write the validated spec to disk
echo "$repaired" > "$OUTPUT_FILE"

echo "Worker spec validated and written to: $OUTPUT_FILE"
exit 0
