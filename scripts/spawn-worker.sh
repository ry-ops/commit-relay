#!/bin/bash
# scripts/spawn-worker.sh
# Spawn individual worker agents for commit-relay
# Part of Phase 1: Script-Triggered Automation

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_RELAY_HOME="${COMMIT_RELAY_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load libraries
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/coordination.sh"
source "$SCRIPT_DIR/lib/access-check.sh"
source "$SCRIPT_DIR/lib/goal-planner.sh"
source "$SCRIPT_DIR/lib/identity-check.sh" 2>/dev/null || true  # Optional identity system

# Color definitions for output formatting
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"  # No Color

# Backward compatibility functions
print_info() { log_info "$1"; }
print_success() { log_info "✅ $1"; }
print_error() { log_error "$1"; }
print_warning() { log_warn "$1"; }

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Spawn a worker agent with specified configuration.

OPTIONS:
    -t, --type TYPE           Worker type (scan-worker, fix-worker, analysis-worker, etc.)
    -i, --task-id ID          Related task ID (required)
    -m, --master MASTER       Master agent spawning this worker (required)
    -r, --repo REPO           Repository (format: owner/repo)
# [DEPRECATED - CAG makes this obsolete]     -b, --budget TOKENS       Token budget (default: auto-determined by type)
    -d, --deadline TIMESTAMP  ISO-8601 deadline (optional)
    -p, --priority PRIORITY   Priority: critical|high|medium|low (default: medium)
    -s, --scope JSON          JSON scope object (optional)
    -c, --context JSON        JSON context object (optional)
    --review-enabled BOOL     Enable quality review loops (default: from policy)
    --review-cycles NUM       Number of review cycles (default: from policy)
    -h, --help                Show this help message

EXAMPLES:
    # Spawn scan worker for security scan
    $0 --type scan-worker --task-id task-010 --master security-master \\
       --repo ry-ops/n8n-mcp-server

    # Spawn fix worker with custom budget
    $0 --type fix-worker --task-id task-011 --master development-master \\
# [DEPRECATED - CAG makes this obsolete]        --repo ry-ops/n8n-mcp-server --budget 6000 --priority high

    # Spawn analysis worker
    $0 --type analysis-worker --task-id task-012 --master coordinator-master \\
       --scope '{"question": "How does auth work?"}'

WORKER TYPES:
    scan-worker          Security scanning (15min)
    fix-worker           Apply fixes (20min)
    analysis-worker      Research/investigation (15min)
    implementation-worker Feature development (45min)
    test-worker          Add tests (20min)
    review-worker        Code review (15min)
    pr-worker            Create PRs (10min)
    documentation-worker Write docs (20min)

EOF
    exit 1
}

# Parse command line arguments
WORKER_TYPE=""
TASK_ID=""
MASTER_AGENT=""
REPOSITORY=""
TOKEN_BUDGET=""
DEADLINE=""
PRIORITY="medium"
SCOPE_JSON=""
CONTEXT_JSON=""
EXECUTION_MANAGER=""
REVIEW_ENABLED=""
REVIEW_CYCLES=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            WORKER_TYPE="$2"
            shift 2
            ;;
        -i|--task-id)
            TASK_ID="$2"
            shift 2
            ;;
        -m|--master)
            MASTER_AGENT="$2"
            shift 2
            ;;
        -e|--execution-manager)
            EXECUTION_MANAGER="$2"
            shift 2
            ;;
        -r|--repo)
            REPOSITORY="$2"
            shift 2
            ;;
        -b|--budget)
            # DEPRECATED - CAG makes this obsolete
            TOKEN_BUDGET="$2"
            shift 2
            ;;
        -d|--deadline)
            DEADLINE="$2"
            shift 2
            ;;
        -p|--priority)
            PRIORITY="$2"
            shift 2
            ;;
        -s|--scope)
            SCOPE_JSON="$2"
            shift 2
            ;;
        -c|--context)
            CONTEXT_JSON="$2"
            shift 2
            ;;
        --review-enabled)
            REVIEW_ENABLED="$2"
            shift 2
            ;;
        --review-cycles)
            REVIEW_CYCLES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$WORKER_TYPE" ] || [ -z "$TASK_ID" ] || [ -z "$MASTER_AGENT" ]; then
    print_error "Missing required arguments"
    usage
fi

# Validate worker type
VALID_TYPES=("scan-worker" "fix-worker" "analysis-worker" "implementation-worker" "test-worker" "review-worker" "pr-worker" "documentation-worker")
if [[ ! " ${VALID_TYPES[@]} " =~ " ${WORKER_TYPE} " ]]; then
    print_error "Invalid worker type: $WORKER_TYPE"
    print_info "Valid types: ${VALID_TYPES[*]}"
    exit 1
fi

# Set default token budget and timeout based on worker type
case $WORKER_TYPE in
    scan-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=8000
        TIMEOUT_MINUTES=15
        ;;
    fix-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=5000
        TIMEOUT_MINUTES=20
        ;;
    analysis-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=5000
        TIMEOUT_MINUTES=15
        ;;
    implementation-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=10000
        TIMEOUT_MINUTES=45
        ;;
    test-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=6000
        TIMEOUT_MINUTES=20
        ;;
    review-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=5000
        TIMEOUT_MINUTES=15
        ;;
    pr-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=4000
        TIMEOUT_MINUTES=10
        ;;
    documentation-worker)
        [ -z "$TOKEN_BUDGET" ] && TOKEN_BUDGET=6000
        TIMEOUT_MINUTES=20
        ;;
esac

# Navigate to project root
cd "$COMMIT_RELAY_HOME"

# Permission check: Can this master spawn workers?
PRINCIPAL="${MASTER_AGENT}"
print_info "Checking permissions for $PRINCIPAL to spawn worker..."
check_permission "$PRINCIPAL" "worker-specs" "write" || {
    print_error "Permission denied: $PRINCIPAL cannot spawn workers"
    exit 1
}

# WEEK 3: Goal-Based Worker Planning
# Plan worker strategy before spawning
print_info "Planning worker strategy using goal-based reasoning..."

# Build minimal task spec for planning
TASK_SPEC_FOR_PLANNING=$(cat <<EOF
{
  "id": "$TASK_ID",
  "priority": "$PRIORITY",
  "description": "Worker task for $TASK_ID",
  "scope": $SCOPE_JSON,
  "context": $CONTEXT_JSON
}
EOF
)

# Generate strategy plan
STRATEGY_PLAN=$(plan_worker_strategy "$TASK_SPEC_FOR_PLANNING" "$WORKER_TYPE" 2>/dev/null || echo '{}')

# Validate strategy plan
if validate_strategy_plan "$STRATEGY_PLAN" 2>/dev/null; then
    SELECTED_STRATEGY=$(echo "$STRATEGY_PLAN" | jq -r '.selected_strategy // "direct"')
    GOAL_TYPE=$(echo "$STRATEGY_PLAN" | jq -r '.goal_type // "general"')
    COMPLEXITY=$(echo "$STRATEGY_PLAN" | jq -r '.complexity // "medium"')
    print_success "Strategy selected: $SELECTED_STRATEGY (goal: $GOAL_TYPE, complexity: $COMPLEXITY)"
else
    # Fallback to direct strategy if planning fails
    SELECTED_STRATEGY="direct"
    GOAL_TYPE="general"
    COMPLEXITY="medium"
    STRATEGY_PLAN='{"selected_strategy":"direct","goal_type":"general","complexity":"medium","error":"Planning failed, using defaults"}'
    print_warning "Goal-based planning failed, using direct strategy as fallback"
fi

# Pull latest state
print_info "Pulling latest coordination state..."
git pull origin main --quiet

# Generate worker ID
WORKER_COUNT=$(jq '.active_workers | length' coordination/worker-pool.json)
WORKER_NUM=$(printf "%03d" $((WORKER_COUNT + 1)))
WORKER_ID="worker-${WORKER_TYPE%-worker}-${WORKER_NUM}"

print_info "Generating worker: $WORKER_ID"

# Generate timestamps
CREATED_AT=$(date +"%Y-%m-%dT%H:%M:%S%z")
if [ -z "$DEADLINE" ]; then
    DEADLINE="null"
else
    DEADLINE="\"$DEADLINE\""
fi

# Build scope JSON
if [ -z "$SCOPE_JSON" ]; then
    if [ -n "$REPOSITORY" ]; then
        SCOPE_JSON=$(cat <<EOF
{
  "repository": "$REPOSITORY",
  "branch": "main",
  "description": "Worker task for $TASK_ID"
}
EOF
)
    else
        SCOPE_JSON="{}"
    fi
fi

# Build context JSON
if [ -z "$CONTEXT_JSON" ]; then
    CONTEXT_JSON=$(cat <<EOF
{
  "parent_task": "$TASK_ID",
  "priority": "$PRIORITY",
  "deadline": $DEADLINE
}
EOF
)
fi

# Issue identity token for worker
IDENTITY_TOKEN=""
SPIFFE_ID=""
if command -v issue_worker_token &> /dev/null; then
    print_info "Issuing identity token for worker..."
    IDENTITY_RESULT=$(issue_worker_token "$WORKER_ID" "$MASTER_AGENT" "$TASK_ID" 2>/dev/null || echo "{}")
    if [ "$IDENTITY_RESULT" != "{}" ]; then
        IDENTITY_TOKEN=$(echo "$IDENTITY_RESULT" | jq -r '.token // ""')
        SPIFFE_ID=$(echo "$IDENTITY_RESULT" | jq -r '.spiffe_id // ""')
        if [ -n "$IDENTITY_TOKEN" ]; then
            print_success "Identity token issued: $SPIFFE_ID"
        fi
    fi
fi

# Create worker specification
WORKER_SPEC_FILE="coordination/worker-specs/active/${WORKER_ID}.json"

print_info "Creating worker specification: $WORKER_SPEC_FILE"

# Set execution_manager field
if [ -n "$EXECUTION_MANAGER" ]; then
  EM_FIELD="\"$EXECUTION_MANAGER\""
else
  EM_FIELD="null"
fi

# Load review configuration from policy if not specified
REVIEW_POLICY_FILE="$COMMIT_RELAY_HOME/coordination/config/review-policy.json"
if [ -f "$REVIEW_POLICY_FILE" ]; then
    # Get defaults from policy
    POLICY_ENABLED=$(jq -r '.enabled // true' "$REVIEW_POLICY_FILE")
    POLICY_DEFAULT_CYCLES=$(jq -r '.global_settings.default_cycles // 1' "$REVIEW_POLICY_FILE")

    # Check for task-type-specific overrides
    TASK_OVERRIDE_ENABLED=$(jq -r --arg type "$WORKER_TYPE" '.task_overrides[$type].enabled // null' "$REVIEW_POLICY_FILE")
    TASK_OVERRIDE_CYCLES=$(jq -r --arg type "$WORKER_TYPE" '.task_overrides[$type].min_cycles // null' "$REVIEW_POLICY_FILE")

    # Apply hierarchy: CLI args > task override > policy default
    if [ -z "$REVIEW_ENABLED" ]; then
        if [ "$TASK_OVERRIDE_ENABLED" != "null" ]; then
            REVIEW_ENABLED="$TASK_OVERRIDE_ENABLED"
        else
            REVIEW_ENABLED="$POLICY_ENABLED"
        fi
    fi

    if [ -z "$REVIEW_CYCLES" ]; then
        if [ "$TASK_OVERRIDE_CYCLES" != "null" ]; then
            REVIEW_CYCLES="$TASK_OVERRIDE_CYCLES"
        else
            REVIEW_CYCLES="$POLICY_DEFAULT_CYCLES"
        fi
    fi
else
    # Default values if no policy file
    [ -z "$REVIEW_ENABLED" ] && REVIEW_ENABLED="true"
    [ -z "$REVIEW_CYCLES" ] && REVIEW_CYCLES="1"
fi

print_info "Review configuration: enabled=$REVIEW_ENABLED, cycles=$REVIEW_CYCLES"

# Phase 5.3: Get tool clustering assignment (58% tool reduction)
TOOL_FILTER_CLI="$COMMIT_RELAY_HOME/lib/tools/tool-filter-cli.js"
TOOL_ASSIGNMENT="{}"
if [ -f "$TOOL_FILTER_CLI" ]; then
    print_info "Applying tool clustering for $WORKER_TYPE..."
    # Get tool assignment from filter
    TOOL_RESULT=$(node "$TOOL_FILTER_CLI" get-tools "$WORKER_TYPE" 2>/dev/null || echo "{}")
    if [ "$TOOL_RESULT" != "{}" ] && [ "$TOOL_RESULT" != "null" ]; then
        TOOL_ASSIGNMENT="$TOOL_RESULT"
        ESSENTIAL_COUNT=$(echo "$TOOL_ASSIGNMENT" | jq -r '.essential_tools | length' 2>/dev/null || echo "0")
        OPTIONAL_COUNT=$(echo "$TOOL_ASSIGNMENT" | jq -r '.optional_tools | length' 2>/dev/null || echo "0")
        TOTAL_TOOLS=$((ESSENTIAL_COUNT + OPTIONAL_COUNT))
        print_info "Tool assignment: $TOTAL_TOOLS tools ($ESSENTIAL_COUNT essential, $OPTIONAL_COUNT optional)"
    fi
fi

cat > "$WORKER_SPEC_FILE" <<EOF
{
  "worker_id": "$WORKER_ID",
  "worker_type": "$WORKER_TYPE",
  "created_by": "$MASTER_AGENT",
  "execution_manager": $EM_FIELD,
  "created_at": "$CREATED_AT",
  "task_id": "$TASK_ID",
  "status": "pending",
  "identity": {
    "spiffe_id": "${SPIFFE_ID:-}",
    "token": "${IDENTITY_TOKEN:-}",
    "trust_level": 50
  },
  "scope": $SCOPE_JSON,
  "context": $CONTEXT_JSON,
  "goal_based_planning": {
    "enabled": true,
    "strategy": "$SELECTED_STRATEGY",
    "goal_type": "$GOAL_TYPE",
    "complexity": "$COMPLEXITY",
    "strategy_plan_location": "coordination/knowledge-base/strategy-plans/${WORKER_ID}-plan.json"
  },
  "resources": {
    "token_budget": $TOKEN_BUDGET,
    "timeout_minutes": $TIMEOUT_MINUTES,
    "max_retries": 1
  },
  "tool_assignment": $TOOL_ASSIGNMENT,
  "deliverables": [],
  "prompt_template": "agents/prompts/workers/${WORKER_TYPE}-v2.md",
  "execution": {
    "started_at": null,
    "completed_at": null,
    "tokens_used": 0,
    "duration_minutes": 0,
    "session_id": null
  },
  "results": {
    "status": null,
    "output_location": null,
    "summary": null,
    "artifacts": []
  },
  "review": {
    "enabled": $REVIEW_ENABLED,
    "min_cycles": $REVIEW_CYCLES,
    "auto_approve_threshold": 0.95,
    "history": []
  }
}
EOF

# Validate JSON
if ! jq empty "$WORKER_SPEC_FILE" 2>/dev/null; then
    print_error "Generated invalid JSON in worker specification"
    exit 1
fi

print_success "Worker specification created"

# Save strategy plan to knowledge base
if [ "$STRATEGY_PLAN" != "{}" ]; then
    print_info "Saving strategy plan to knowledge base..."
    if save_strategy_plan "$STRATEGY_PLAN" "$WORKER_ID" "$TASK_ID" 2>/dev/null; then
        print_success "Strategy plan saved"
    else
        print_warning "Failed to save strategy plan (worker will still function)"
    fi
fi

# Update worker-pool.json
print_info "Updating worker pool..."

# Add to active workers
TMP_FILE=$(mktemp)
jq --arg worker_id "$WORKER_ID" \
   --arg worker_type "$WORKER_TYPE" \
   --arg spawned_by "$MASTER_AGENT" \
   --arg spawned_at "$CREATED_AT" \
   --arg task_id "$TASK_ID" \
   --argjson token_budget "$TOKEN_BUDGET" \
   '.active_workers += [{
     "worker_id": $worker_id,
     "worker_type": $worker_type,
     "spawned_by": $spawned_by,
     "spawned_at": $spawned_at,
     "status": "pending",
     "task_id": $task_id,
     "token_budget": $token_budget,
     "tokens_used": 0,
     "timeout_at": null,
     "last_heartbeat": null,
     "session_id": null
   }] | .updated_at = $spawned_at | .stats.total_spawned_today += 1' \
   coordination/worker-pool.json > "$TMP_FILE"

mv "$TMP_FILE" coordination/worker-pool.json

print_success "Worker pool updated"

# Update token budget
print_info "Allocating token budget..."

TMP_FILE=$(mktemp)
jq --arg master "$MASTER_AGENT" \
   --arg worker "$WORKER_ID" \
   --argjson tokens "$TOKEN_BUDGET" \
   --arg ts "$CREATED_AT" \
   '.allocated = ((.allocated // 0) + $tokens) |
    .in_use = ((.in_use // 0) + $tokens) |
    .available = ((.available // 0) - $tokens) |
    .allocations[$worker] = {master: $master, tokens: $tokens, allocated_at: $ts} |
    .updated_at = $ts' \
   coordination/token-budget.json > "$TMP_FILE"

mv "$TMP_FILE" coordination/token-budget.json

print_success "Token budget allocated: $TOKEN_BUDGET tokens"

# Create worker log directory
WORKER_LOG_DIR="agents/logs/workers/$(date +%Y-%m-%d)/${WORKER_ID}"
mkdir -p "$WORKER_LOG_DIR"

print_success "Worker log directory created: $WORKER_LOG_DIR"

# Display summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Worker Spawned Successfully${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Worker ID:${NC}       $WORKER_ID"
echo -e "${BLUE}Type:${NC}            $WORKER_TYPE"
echo -e "${BLUE}Master:${NC}          $MASTER_AGENT"
echo -e "${BLUE}Task:${NC}            $TASK_ID"
echo -e "${BLUE}Token Budget:${NC}    $TOKEN_BUDGET"
echo -e "${BLUE}Timeout:${NC}         ${TIMEOUT_MINUTES} minutes"
echo -e "${BLUE}Priority:${NC}        $PRIORITY"
if [ -n "$REPOSITORY" ]; then
    echo -e "${BLUE}Repository:${NC}      $REPOSITORY"
fi
echo ""
echo -e "${YELLOW}Goal-Based Planning (Week 3):${NC}"
echo -e "${BLUE}Strategy:${NC}        $SELECTED_STRATEGY"
echo -e "${BLUE}Goal Type:${NC}       $GOAL_TYPE"
echo -e "${BLUE}Complexity:${NC}      $COMPLEXITY"
echo ""
echo -e "${YELLOW}Quality Review Loops:${NC}"
echo -e "${BLUE}Enabled:${NC}         $REVIEW_ENABLED"
echo -e "${BLUE}Min Cycles:${NC}      $REVIEW_CYCLES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Export review environment variables for worker process
export REVIEW_ENABLED="$REVIEW_ENABLED"
export REVIEW_CYCLES="$REVIEW_CYCLES"
export REVIEW_POLICY_PATH="$REVIEW_POLICY_FILE"

# Display next steps
print_info "Next Steps:"
echo "1. Start Claude Code session with worker prompt (Phase 5.1: AGENTS.md format):"
echo "   claude-code --prompt-file agents/prompts/workers/${WORKER_TYPE}-v2.md"
echo ""
echo "2. Worker will read its specification from:"
echo "   $WORKER_SPEC_FILE"
echo ""
echo "3. Worker logs will be written to:"
echo "   $WORKER_LOG_DIR"
echo ""

print_warning "Remember to commit these changes to the coordination repository!"
echo "   cd ~/commit-relay"
echo "   git add ."
echo "   git commit -m \"feat(\$MASTER_AGENT): spawned $WORKER_ID for $TASK_ID\""
echo "   git push origin main"

exit 0
