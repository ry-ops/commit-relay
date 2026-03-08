#!/bin/bash
# scripts/remove-token-limits.sh
# Remove token limit constraints from master prompts and worker specs
# CAG caching makes token budgets obsolete for the commit-relay system

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Color definitions
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"  # No Color

# Configuration
DRY_RUN=false
BACKUP_DIR="$COMMIT_RELAY_HOME/coordination/backups/token-limits-removal-$(date +%Y%m%d-%H%M%S)"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Remove token limit constraints from commit-relay system.
CAG caching makes explicit token budgets obsolete.

OPTIONS:
    --dry-run           Show what would be changed without making changes
    -h, --help          Show this help message

TASKS:
    1. Update master agent prompts to remove token budget references
    2. Update worker spawning scripts to remove token allocation
    3. Update master state files to remove token tracking
    4. Update documentation to reflect token-efficiency via CAG

EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Display banner
echo -e "${BLUE}"
cat <<'EOF'
╔═══════════════════════════════════════════════════════════╗
║         Remove Token Limits - CAG Optimization            ║
║                                                           ║
║  Token budgets are obsolete with CAG caching              ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY RUN MODE] No changes will be made${NC}\n"
fi

# Create backup directory
if [[ "$DRY_RUN" == "false" ]]; then
    mkdir -p "$BACKUP_DIR"
    echo -e "${GREEN}Created backup directory: $BACKUP_DIR${NC}\n"
fi

# Task 1: Update master agent prompts
update_master_prompts() {
    echo -e "${BLUE}═══ Task 1: Updating Master Agent Prompts ═══${NC}"

    local master_prompts=(
        ".claude/agents/development-master.md"
        ".claude/agents/coordinator-master.md"
        ".claude/agents/security-master.md"
        ".claude/agents/inventory-master.md"
        ".claude/agents/cicd-master.md"
    )

    for prompt_file in "${master_prompts[@]}"; do
        local full_path="$COMMIT_RELAY_HOME/$prompt_file"

        if [[ ! -f "$full_path" ]]; then
            echo -e "${YELLOW}Skipping (not found): $prompt_file${NC}"
            continue
        fi

        echo "Processing: $prompt_file"

        if [[ "$DRY_RUN" == "false" ]]; then
            # Backup original
            cp "$full_path" "$BACKUP_DIR/$(basename "$prompt_file").backup"

            # Remove token budget column from worker types table
            # Change: | Worker Type | Token Budget | Purpose | Skills |
            # To:     | Worker Type | Purpose | Skills |
            sed -i.tmp 's/| Token Budget //' "$full_path" || true
            sed -i.tmp 's/| [0-9]*k //' "$full_path" || true

            # Remove token budget section if exists
            sed -i.tmp '/^## Token Budget/,/^##/{ /^## Token Budget/d; /^##/!d; }' "$full_path" || true

            # Clean up temp files
            rm -f "$full_path.tmp"

            echo -e "${GREEN}✓ Updated: $prompt_file${NC}"
        else
            echo -e "${YELLOW}[DRY RUN] Would update: $prompt_file${NC}"
        fi
    done

    echo ""
}

# Task 2: Update spawn-worker script
update_spawn_worker_script() {
    echo -e "${BLUE}═══ Task 2: Updating Worker Spawn Scripts ═══${NC}"

    local spawn_script="$COMMIT_RELAY_HOME/scripts/spawn-worker.sh"

    if [[ ! -f "$spawn_script" ]]; then
        echo -e "${YELLOW}Spawn worker script not found${NC}"
        return 0
    fi

    echo "Processing: scripts/spawn-worker.sh"

    if [[ "$DRY_RUN" == "false" ]]; then
        # Backup original
        cp "$spawn_script" "$BACKUP_DIR/spawn-worker.sh.backup"

        # Comment out token budget references in usage
        sed -i.tmp 's/\(.*--budget.*\)/# [DEPRECATED - CAG makes this obsolete] \1/' "$spawn_script" || true

        # Update WORKER TYPES section to remove token mentions
        sed -i.tmp 's/\([a-z-]*worker.*\)([0-9]*k tokens, \([0-9]*min\))/\1(\2)/' "$spawn_script" || true

        # Clean up temp files
        rm -f "$spawn_script.tmp"

        echo -e "${GREEN}✓ Updated: scripts/spawn-worker.sh${NC}"
    else
        echo -e "${YELLOW}[DRY RUN] Would update: scripts/spawn-worker.sh${NC}"
    fi

    echo ""
}

# Task 3: Update master state files
update_master_states() {
    echo -e "${BLUE}═══ Task 3: Updating Master State Files ═══${NC}"

    local state_files=(
        "coordination/masters/development/context/master-state.json"
        "coordination/masters/coordinator/context/master-state.json"
        "coordination/masters/security/context/master-state.json"
    )

    for state_file in "${state_files[@]}"; do
        local full_path="$COMMIT_RELAY_HOME/$state_file"

        if [[ ! -f "$full_path" ]]; then
            echo -e "${YELLOW}Skipping (not found): $state_file${NC}"
            continue
        fi

        echo "Processing: $state_file"

        if [[ "$DRY_RUN" == "false" ]]; then
            # Backup original
            cp "$full_path" "$BACKUP_DIR/$(basename "$state_file").backup"

            # Remove tokens_used field using jq
            if command -v jq &> /dev/null; then
                jq 'del(.tokens_used) | del(.token_budget)' "$full_path" > "$full_path.tmp" && mv "$full_path.tmp" "$full_path"
                echo -e "${GREEN}✓ Updated: $state_file${NC}"
            else
                echo -e "${YELLOW}⚠ jq not found, skipping JSON update${NC}"
            fi
        else
            echo -e "${YELLOW}[DRY RUN] Would update: $state_file${NC}"
        fi
    done

    echo ""
}

# Task 4: Create documentation update
create_documentation_note() {
    echo -e "${BLUE}═══ Task 4: Creating Documentation Note ═══${NC}"

    local doc_file="$COMMIT_RELAY_HOME/docs/token-optimization-via-cag.md"

    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "$doc_file" <<'DOC_EOF'
# Token Optimization via CAG Caching

## Overview

The commit-relay system has eliminated explicit token budget management due to the implementation of Context-Aware Generation (CAG) caching with prompt caching.

## What Changed

### Before CAG
- Each master had explicit token budgets (e.g., 30k daily limit)
- Workers had per-type token allocations (5k-15k per worker)
- Token tracking in master state files
- Complex token accounting and budget enforcement

### After CAG
- Prompt caching provides 90% token cost reduction for repeated context
- Static knowledge cached indefinitely
- Token budgets are no longer necessary
- System can scale without artificial token constraints

## CAG Caching Layers

### 1. Static Knowledge Cache
- Codebase architecture
- Implementation patterns
- Security vulnerabilities database
- Cached indefinitely, updated periodically

### 2. Session Knowledge Cache
- Task context
- Recent decisions
- Active coordination state
- Cached for 5 minutes (Claude's cache window)

### 3. Dynamic Context
- Real-time events
- Current worker states
- Fresh data that changes frequently

## Benefits

1. **Cost Efficiency**: 90% reduction in token costs for repeated context
2. **Scalability**: No artificial limits on worker spawning
3. **Performance**: Faster response times with cached context
4. **Simplicity**: No token accounting overhead

## Migration Notes

- Token budget fields removed from master prompts
- Token allocation removed from worker spawn scripts
- Token tracking removed from state files
- Historical token data preserved in archives

## See Also

- [CAG Cache Management](./cag-cache-management.md)
- [Hybrid RAG-CAG Architecture](./hybrid-rag-cag-architecture.md)
- [System Maintenance](../scripts/system-maintenance.sh)

---
*Generated: $(date +%Y-%m-%d)*
*Status: Token limits removed, CAG optimization complete*
DOC_EOF

        echo -e "${GREEN}✓ Created: docs/token-optimization-via-cag.md${NC}"
    else
        echo -e "${YELLOW}[DRY RUN] Would create: docs/token-optimization-via-cag.md${NC}"
    fi

    echo ""
}

# Main execution
main() {
    local start_time=$(date +%s)

    update_master_prompts
    update_spawn_worker_script
    update_master_states
    create_documentation_note

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Token limit removal completed in ${duration}s${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"

    if [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        echo -e "${BLUE}Backups saved to: $BACKUP_DIR${NC}"
        ls -lh "$BACKUP_DIR" 2>/dev/null || true
    fi
}

# Run main function
main

exit 0
