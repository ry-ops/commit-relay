#!/bin/bash
# scripts/cag/validate-caches.sh
# Validate CAG cache versions and detect stale caches

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

cd "$COMMIT_RELAY_HOME"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  CAG Cache Validation & Version Check${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Expected cache version
EXPECTED_VERSION="1.0.0"
CACHE_SCHEMA_CHANGED_DATE="2025-11-07"

# Master cache locations (using simple array approach)
MASTERS=("coordinator" "security" "development" "inventory" "cicd")
declare -a CACHE_PATHS=(
    "coordination/masters/coordinator/cag-cache/static-knowledge.json"
    "coordination/masters/security/cag-cache/static-knowledge.json"
    "coordination/masters/development/cag-cache/static-knowledge.json"
    "coordination/masters/inventory/cag-cache/static-knowledge.json"
    "coordination/masters/cicd/cag-cache/static-knowledge.json"
)

# EM cache location
EM_CACHE="coordination/execution-managers/cag-cache/static-knowledge.json"

# Validation results
VALID_CACHES=0
STALE_CACHES=0
MISSING_CACHES=0
INVALID_CACHES=0

validate_cache() {
    local name="$1"
    local cache_file="$2"

    echo -e "${CYAN}Checking ${name} cache:${NC} ${cache_file}"

    # Check if file exists
    if [ ! -f "$cache_file" ]; then
        echo -e "  ${RED}✗ Missing${NC}: Cache file does not exist"
        ((MISSING_CACHES++))
        return 1
    fi

    # Validate JSON structure
    if ! jq empty "$cache_file" 2>/dev/null; then
        echo -e "  ${RED}✗ Invalid JSON${NC}: Cache file is malformed"
        ((INVALID_CACHES++))
        return 1
    fi

    # Check version
    local cache_version=$(jq -r '.cache_version // "unknown"' "$cache_file")
    if [ "$cache_version" != "$EXPECTED_VERSION" ]; then
        echo -e "  ${YELLOW}⚠ Version Mismatch${NC}: Cache version ${cache_version}, expected ${EXPECTED_VERSION}"
        ((STALE_CACHES++))
        return 1
    fi

    # Check last_updated timestamp
    local last_updated=$(jq -r '.last_updated // "unknown"' "$cache_file")
    if [ "$last_updated" == "unknown" ]; then
        echo -e "  ${YELLOW}⚠ No Timestamp${NC}: Cache missing last_updated field"
        ((STALE_CACHES++))
        return 1
    fi

    # Check if cache is recent (within last 30 days for warning)
    local cache_date=$(echo "$last_updated" | cut -d'T' -f1)
    local days_old=$(( ( $(date +%s) - $(date -j -f "%Y-%m-%d" "$cache_date" +%s 2>/dev/null || echo 0) ) / 86400 ))

    if [ $days_old -gt 30 ]; then
        echo -e "  ${YELLOW}⚠ Potentially Stale${NC}: Cache is ${days_old} days old (updated: ${last_updated})"
        echo -e "    ${CYAN}→ Consider regenerating if worker specs/protocols have changed${NC}"
    fi

    # Check estimated tokens
    local estimated_tokens=$(jq -r '.estimated_tokens // 0' "$cache_file")
    echo -e "  ${GREEN}✓ Valid${NC}: Version ${cache_version}, ${estimated_tokens} tokens, updated ${last_updated}"

    ((VALID_CACHES++))
    return 0
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Master Caches${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

for i in "${!MASTERS[@]}"; do
    validate_cache "${MASTERS[$i]}" "${CACHE_PATHS[$i]}"
    echo
done

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Execution Manager Cache${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

validate_cache "execution-manager" "$EM_CACHE"
echo

# Summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Validation Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

total_caches=$(( ${#MASTERS[@]} + 1 ))
echo -e "${CYAN}Total Caches:${NC}    $total_caches"
echo -e "${GREEN}Valid:${NC}           $VALID_CACHES"
echo -e "${YELLOW}Stale:${NC}           $STALE_CACHES"
echo -e "${RED}Missing:${NC}         $MISSING_CACHES"
echo -e "${RED}Invalid JSON:${NC}    $INVALID_CACHES"
echo

# Recommendations
if [ $VALID_CACHES -eq $total_caches ]; then
    echo -e "${GREEN}✓ All caches are valid and up-to-date${NC}"
    echo
    exit 0
elif [ $STALE_CACHES -gt 0 ]; then
    echo -e "${YELLOW}⚠ Some caches are stale or mismatched${NC}"
    echo
    echo -e "${CYAN}Recommendations:${NC}"
    echo -e "  1. Review worker specifications in coordination/worker-specs/"
    echo -e "  2. Check if coordination protocols have changed"
    echo -e "  3. Regenerate caches if needed:"
    echo -e "     ${YELLOW}./scripts/cag/regenerate-caches.sh${NC}"
    echo
    exit 1
elif [ $MISSING_CACHES -gt 0 ] || [ $INVALID_CACHES -gt 0 ]; then
    echo -e "${RED}✗ Some caches are missing or invalid${NC}"
    echo
    echo -e "${CYAN}Required Actions:${NC}"
    echo -e "  1. Generate missing caches:"
    echo -e "     ${YELLOW}./scripts/cag/regenerate-caches.sh${NC}"
    echo -e "  2. Fix invalid JSON in cache files"
    echo -e "  3. Re-run validation after fixes"
    echo
    exit 2
fi
