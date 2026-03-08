#!/bin/bash
# Update all worker prompt templates with spec self-initialization instructions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/../agents/prompts/workers"
HEADER_FILE="$SCRIPT_DIR/worker-init-header.txt"

echo "Updating worker prompt templates..."

# List of worker types to update (excluding implementation-worker which we already did)
WORKERS=(
    "fix-worker"
    "scan-worker"
    "analysis-worker"
    "test-worker"
    "review-worker"
    "pr-worker"
    "documentation-worker"
    "catalog-worker"
)

for worker in "${WORKERS[@]}"; do
    PROMPT_FILE="$PROMPTS_DIR/${worker}.md"

    if [ ! -f "$PROMPT_FILE" ]; then
        echo "  ⚠️  Skipping $worker (file not found)"
        continue
    fi

    # Check if already updated
    if grep -q "CRITICAL: Read Your Worker Specification FIRST" "$PROMPT_FILE" 2>/dev/null; then
        echo "  ✅ $worker already updated"
        continue
    fi

    # Create temp file
    TEMP_FILE=$(mktemp)

    # Find first --- separator and insert header after it
    awk -v header_file="$HEADER_FILE" '
        BEGIN { dash_count = 0; inserted = 0 }
        /^---$/ {
            dash_count++
            print $0
            if (dash_count == 1 && !inserted) {
                print ""
                while ((getline line < header_file) > 0) {
                    print line
                }
                close(header_file)
                inserted = 1
            }
            next
        }
        { print $0 }
    ' "$PROMPT_FILE" > "$TEMP_FILE"

    # Replace original
    mv "$TEMP_FILE" "$PROMPT_FILE"

    echo "  ✅ Updated $worker"
done

echo ""
echo "Worker prompt templates updated successfully!"
echo "All workers will now read their spec files on startup."
