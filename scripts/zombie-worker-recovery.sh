#!/bin/bash
# scripts/zombie-worker-recovery.sh
# Recover zombie workers by cleaning them up and reclaiming token budgets
# Part of Week 1: AGENT_ARCHITECTURE_FIX

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh" 2>/dev/null || {
    echo "[WARN] Logging library not available, using basic logging"
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1"; }
    log_error() { echo "[ERROR] $1"; }
    log_success() { echo "[SUCCESS] $1"; }
}

# Color output
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

cd "$COMMIT_RELAY_HOME"

log_info "Starting zombie worker recovery process..."

# Check for zombie workers
ACTIVE_SPECS_DIR="coordination/worker-specs/active"
ZOMBIE_DIR="coordination/worker-specs/zombie"
QUARANTINE_DIR="coordination/worker-specs/quarantine"

# Create directories if they don't exist
mkdir -p "$ZOMBIE_DIR"
mkdir -p "$QUARANTINE_DIR"

# Count zombies
ZOMBIE_COUNT=$(find "$ACTIVE_SPECS_DIR" -name "*.json" -exec jq -r 'select(.status == "zombie") | .worker_id' {} \; 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Zombie Worker Recovery${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}Found: ${ZOMBIE_COUNT} zombie workers${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$ZOMBIE_COUNT" -eq 0 ]; then
    log_info "No zombie workers found. System is clean!"
    exit 0
fi

# Collect token reclamation data
TOTAL_TOKENS_RECLAIMED=0

# Process each zombie worker
for spec_file in "$ACTIVE_SPECS_DIR"/*.json; do
    if [ ! -f "$spec_file" ]; then
        continue
    fi

    # Check if worker is zombie
    STATUS=$(jq -r '.status' "$spec_file" 2>/dev/null || echo "")

    if [ "$STATUS" = "zombie" ]; then
        WORKER_ID=$(jq -r '.worker_id' "$spec_file")
        WORKER_TYPE=$(jq -r '.worker_type' "$spec_file")
        TASK_ID=$(jq -r '.task_id' "$spec_file")
        TOKEN_BUDGET=$(jq -r '.resources.token_budget' "$spec_file")
        CREATED_AT=$(jq -r '.created_at' "$spec_file")
        MISSED_COUNT=$(jq -r '.heartbeat.missed_count // 0' "$spec_file")

        log_info "Processing zombie: $WORKER_ID"
        log_info "  Type: $WORKER_TYPE"
        log_info "  Task: $TASK_ID"
        log_info "  Budget: ${TOKEN_BUDGET} tokens"
        log_info "  Missed heartbeats: $MISSED_COUNT"
        log_info "  Created: $CREATED_AT"

        # Add cleanup metadata to worker spec
        NOW=$(date +"%Y-%m-%dT%H:%M:%S%z")
        jq --arg cleaned_at "$NOW" \
           --arg reason "zombie_recovery_script" \
           '.cleanup = {
               "cleaned_at": $cleaned_at,
               "reason": $reason,
               "original_status": "zombie",
               "tokens_reclaimed": .resources.token_budget
            }' \
           "$spec_file" > "${spec_file}.tmp" && \
           mv "${spec_file}.tmp" "$spec_file"

        # Move to zombie directory
        ZOMBIE_FILE="$ZOMBIE_DIR/$(basename "$spec_file")"
        mv "$spec_file" "$ZOMBIE_FILE"

        log_success "  Moved to: $ZOMBIE_FILE"

        # Reclaim tokens
        TOTAL_TOKENS_RECLAIMED=$((TOTAL_TOKENS_RECLAIMED + TOKEN_BUDGET))
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Recovery Complete${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Zombies cleaned:${NC}      $ZOMBIE_COUNT"
echo -e "${BLUE}Tokens reclaimed:${NC}    $TOTAL_TOKENS_RECLAIMED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Update token budget
if [ "$TOTAL_TOKENS_RECLAIMED" -gt 0 ]; then
    log_info "Reclaiming $TOTAL_TOKENS_RECLAIMED tokens to budget..."

    # Update token-budget.json
    if [ -f "coordination/token-budget.json" ]; then
        TMP_FILE=$(mktemp)
        jq --argjson reclaimed "$TOTAL_TOKENS_RECLAIMED" \
           --arg timestamp "$NOW" \
           '.total_used -= $reclaimed |
            .updated_at = $timestamp |
            .reclamation_log += [{
                "timestamp": $timestamp,
                "tokens_reclaimed": $reclaimed,
                "reason": "zombie_worker_cleanup",
                "worker_count": '$ZOMBIE_COUNT'
            }]' \
           coordination/token-budget.json > "$TMP_FILE"

        mv "$TMP_FILE" coordination/token-budget.json
        log_success "Token budget updated"
    else
        log_warn "Token budget file not found, skipping budget update"
    fi
fi

# Git commit the changes
log_info "Committing zombie cleanup to git..."

git add "$ZOMBIE_DIR"/ 2>/dev/null || true
git add coordination/token-budget.json 2>/dev/null || true

git commit -m "fix(workers): clean up $ZOMBIE_COUNT zombie workers, reclaim $TOTAL_TOKENS_RECLAIMED tokens

Week 1: AGENT_ARCHITECTURE_FIX
- Moved zombie workers to coordination/worker-specs/zombie/
- Reclaimed $TOTAL_TOKENS_RECLAIMED tokens to budget
- Updated token-budget.json with reclamation log

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>" --quiet 2>/dev/null || true

git push origin main --quiet 2>/dev/null || {
    log_warn "Failed to push changes, continuing..."
}

log_success "Zombie worker recovery complete!"
echo ""
log_info "Next steps:"
echo "  1. Verify token budget: cat coordination/token-budget.json | jq"
echo "  2. Check active workers: ls -la coordination/worker-specs/active/"
echo "  3. Review zombie archive: ls -la coordination/worker-specs/zombie/"
echo ""

exit 0
