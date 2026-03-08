#!/bin/bash
#
# archive-failed-workers.sh
# Archives failed workers to a dated directory for audit and cleanup
#
# Usage: ./scripts/archive-failed-workers.sh
#

set -e

# Directories
COORD_ROOT="/Users/ryandahlberg/commit-relay/coordination"
FAILED_DIR="${COORD_ROOT}/worker-specs/failed"
ARCHIVE_BASE="${COORD_ROOT}/worker-specs/archived"
ARCHIVE_DIR="${ARCHIVE_BASE}/failed-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Archive Failed Workers${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if failed directory exists
if [ ! -d "$FAILED_DIR" ]; then
    echo -e "${RED}Error: Failed workers directory not found: $FAILED_DIR${NC}"
    exit 1
fi

# Count failed workers
FAILED_COUNT=$(find "$FAILED_DIR" -maxdepth 1 -name "*.json" | wc -l | tr -d ' ')

if [ "$FAILED_COUNT" -eq 0 ]; then
    echo -e "${GREEN}No failed workers to archive.${NC}"
    exit 0
fi

echo -e "${YELLOW}Found $FAILED_COUNT failed worker(s) to archive${NC}"
echo ""

# Show summary of failed workers
echo -e "${BLUE}Failed Workers Summary:${NC}"
echo "----------------------------------------"
for worker_file in "$FAILED_DIR"/*.json; do
    if [ -f "$worker_file" ]; then
        worker_id=$(basename "$worker_file" .json)
        worker_type=$(jq -r '.worker_type // "unknown"' "$worker_file" 2>/dev/null || echo "unknown")
        failed_at=$(jq -r '.completed_at // .updated_at // "unknown"' "$worker_file" 2>/dev/null || echo "unknown")
        echo "  - $worker_id ($worker_type) - failed at: $failed_at"
    fi
done
echo ""

# Create archive directory
echo -e "${BLUE}Creating archive directory: $ARCHIVE_DIR${NC}"
mkdir -p "$ARCHIVE_DIR"

# Move failed workers to archive
echo -e "${BLUE}Archiving failed workers...${NC}"
ARCHIVED_COUNT=0
for worker_file in "$FAILED_DIR"/*.json; do
    if [ -f "$worker_file" ]; then
        worker_name=$(basename "$worker_file")
        mv "$worker_file" "$ARCHIVE_DIR/"
        ((ARCHIVED_COUNT++))
        echo "  ✓ Archived: $worker_name"
    fi
done

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Archive Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Archived ${GREEN}$ARCHIVED_COUNT${NC} failed worker(s)"
echo -e "Location: ${BLUE}$ARCHIVE_DIR${NC}"
echo ""

# Show updated counts
REMAINING_FAILED=$(find "$FAILED_DIR" -maxdepth 1 -name "*.json" | wc -l | tr -d ' ')
echo -e "Remaining failed workers: ${YELLOW}$REMAINING_FAILED${NC}"
echo ""

# Generate archive manifest
MANIFEST_FILE="${ARCHIVE_DIR}/MANIFEST.json"
echo -e "${BLUE}Generating archive manifest: $MANIFEST_FILE${NC}"
jq -n \
  --arg date "$(date +%Y-%m-%dT%H:%M:%S%z)" \
  --arg count "$ARCHIVED_COUNT" \
  --arg location "$ARCHIVE_DIR" \
  '{
    "archived_at": $date,
    "worker_count": ($count | tonumber),
    "archive_location": $location,
    "reason": "cleanup_failed_workers",
    "archived_by": "archive-failed-workers.sh"
  }' > "$MANIFEST_FILE"

echo -e "${GREEN}✓ Manifest generated${NC}"
echo ""
echo -e "${BLUE}You can restore workers from archive if needed:${NC}"
echo -e "  mv $ARCHIVE_DIR/*.json $FAILED_DIR/"
echo ""
